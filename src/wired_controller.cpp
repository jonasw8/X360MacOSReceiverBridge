#include "x360bridge/wired_controller.hpp"

#if __has_include(<libusb.h>)
#include <libusb.h>
#elif __has_include(<libusb-1.0/libusb.h>)
#include <libusb-1.0/libusb.h>
#else
#error "libusb headers not found; install libusb and configure through pkg-config"
#endif

#include <algorithm>
#include <array>
#include <cstring>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <utility>

namespace x360bridge {
namespace {

constexpr std::uint8_t kInterfaceClass = 0xff;
constexpr std::uint8_t kInterfaceSubclass = 0x5d;
constexpr std::uint8_t kWiredControllerProtocol = 0x01;
constexpr int kReadTimeoutMs = 250;
constexpr int kWriteTimeoutMs = 1000;

struct InterfaceMatch {
    int interface_number = -1;
    int alternate_setting = 0;
    std::uint8_t endpoint_in = 0;
    std::uint8_t endpoint_out = 0;
    bool protocol_match = false;
};

struct Candidate {
    libusb_device* device = nullptr;
    libusb_device_descriptor descriptor{};
    WiredControllerInfo info{};
    InterfaceMatch interface{};
};

std::uint16_t read_le16(const std::uint8_t* data) {
    return static_cast<std::uint16_t>(data[0]) |
           static_cast<std::uint16_t>(data[1] << 8u);
}

std::int16_t read_s16(const std::uint8_t* data) {
    return static_cast<std::int16_t>(read_le16(data));
}

std::string libusb_error(int rc) {
    const char* name = libusb_error_name(rc);
    return name == nullptr ? std::to_string(rc) : name;
}

std::string hex_dump(const std::uint8_t* data, std::size_t length) {
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (std::size_t i = 0; i < length; ++i) {
        if (i != 0) out << ' ';
        out << std::setw(2) << static_cast<unsigned>(data[i]);
    }
    return out.str();
}

std::string read_usb_string(libusb_device_handle* handle, std::uint8_t index) {
    if (handle == nullptr || index == 0) return {};
    unsigned char buffer[256]{};
    const int rc = libusb_get_string_descriptor_ascii(handle, index, buffer,
                                                       sizeof(buffer));
    if (rc <= 0) return {};
    return std::string(reinterpret_cast<char*>(buffer),
                       static_cast<std::size_t>(rc));
}

std::optional<InterfaceMatch> find_wired_controller_interface(
    libusb_device* device, bool known_id) {
    libusb_config_descriptor* config = nullptr;
    int rc = libusb_get_active_config_descriptor(device, &config);
    if (rc != LIBUSB_SUCCESS) rc = libusb_get_config_descriptor(device, 0, &config);
    if (rc != LIBUSB_SUCCESS || config == nullptr) return std::nullopt;

    std::optional<InterfaceMatch> best;
    for (std::uint8_t i = 0; i < config->bNumInterfaces; ++i) {
        const libusb_interface& iface = config->interface[i];
        for (int a = 0; a < iface.num_altsetting; ++a) {
            const libusb_interface_descriptor& alt = iface.altsetting[a];
            const bool signature =
                alt.bInterfaceClass == kInterfaceClass &&
                alt.bInterfaceSubClass == kInterfaceSubclass &&
                alt.bInterfaceProtocol == kWiredControllerProtocol;
            if (!signature && !known_id) continue;

            InterfaceMatch match;
            match.interface_number = alt.bInterfaceNumber;
            match.alternate_setting = alt.bAlternateSetting;
            match.protocol_match = signature;
            for (std::uint8_t e = 0; e < alt.bNumEndpoints; ++e) {
                const libusb_endpoint_descriptor& endpoint = alt.endpoint[e];
                if ((endpoint.bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) !=
                    LIBUSB_TRANSFER_TYPE_INTERRUPT) {
                    continue;
                }
                if ((endpoint.bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) ==
                    LIBUSB_ENDPOINT_IN) {
                    match.endpoint_in = endpoint.bEndpointAddress;
                } else {
                    match.endpoint_out = endpoint.bEndpointAddress;
                }
            }
            if (match.endpoint_in != 0) {
                if (!best.has_value() || match.protocol_match) best = match;
                if (match.protocol_match) break;
            }
        }
    }
    libusb_free_config_descriptor(config);
    return best;
}

std::vector<Candidate> collect_candidates(libusb_context* context,
                                          bool include_unknown,
                                          std::string* error) {
    std::vector<Candidate> result;
    libusb_device** devices = nullptr;
    const ssize_t count = libusb_get_device_list(context, &devices);
    if (count < 0) {
        if (error) *error = "libusb_get_device_list failed: " +
                            libusb_error(static_cast<int>(count));
        return result;
    }

    for (ssize_t i = 0; i < count; ++i) {
        libusb_device_descriptor descriptor{};
        if (libusb_get_device_descriptor(devices[i], &descriptor) !=
            LIBUSB_SUCCESS) {
            continue;
        }

        const bool known = is_known_wired_controller_id(descriptor.idVendor,
                                                        descriptor.idProduct);
        if (!known && !include_unknown) continue;

        auto match = find_wired_controller_interface(devices[i], known);
        if (!match.has_value()) continue;
        if (!known && !match->protocol_match) continue;

        Candidate candidate;
        candidate.device = devices[i];
        libusb_ref_device(candidate.device);
        candidate.descriptor = descriptor;
        candidate.interface = match.value();
        candidate.info.id = {descriptor.idVendor, descriptor.idProduct};
        candidate.info.bus = libusb_get_bus_number(devices[i]);
        candidate.info.address = libusb_get_device_address(devices[i]);
        candidate.info.known_id = known;
        candidate.info.protocol_match = match->protocol_match;

        libusb_device_handle* temp = nullptr;
        if (libusb_open(devices[i], &temp) == LIBUSB_SUCCESS) {
            candidate.info.manufacturer =
                read_usb_string(temp, descriptor.iManufacturer);
            candidate.info.product = read_usb_string(temp, descriptor.iProduct);
            candidate.info.serial = read_usb_string(temp, descriptor.iSerialNumber);
            libusb_close(temp);
        }
        result.push_back(std::move(candidate));
    }
    libusb_free_device_list(devices, 1);

    std::sort(result.begin(), result.end(),
              [](const Candidate& lhs, const Candidate& rhs) {
                  if (lhs.info.bus != rhs.info.bus)
                      return lhs.info.bus < rhs.info.bus;
                  return lhs.info.address < rhs.info.address;
              });
    return result;
}

void release_candidates(std::vector<Candidate>& candidates) {
    for (auto& candidate : candidates) {
        if (candidate.device) libusb_unref_device(candidate.device);
        candidate.device = nullptr;
    }
}

}  // namespace

struct WiredController::EndpointSet {
    int interface_number = -1;
    int alternate_setting = 0;
    std::uint8_t endpoint_in = 0;
    std::uint8_t endpoint_out = 0;
    std::mutex write_mutex;
};

bool is_known_wired_controller_id(std::uint16_t vendor, std::uint16_t product) {
    // Official Microsoft Xbox 360 Controller for Windows. Many third-party
    // wired controllers use their own VID/PID, so the app also offers an
    // opt-in FF/5D/01 protocol-signature path for diagnosis.
    return vendor == 0x045e && product == 0x028e;
}

std::optional<State> parse_wired_controller_packet(const std::uint8_t* data,
                                                   std::size_t length) {
    if (data == nullptr || length < 14) return std::nullopt;
    // Xbox 360 wired controller input reports normally start with 00 14.
    // Clones sometimes vary byte 1, so accept any report that is long enough
    // and begins with 00 while preserving the canonical layout.
    if (data[0] != 0x00) return std::nullopt;

    State state;
    const std::uint8_t b0 = data[2];
    const std::uint8_t b1 = data[3];
    state.dpad_up = (b0 & 0x01u) != 0;
    state.dpad_down = (b0 & 0x02u) != 0;
    state.dpad_left = (b0 & 0x04u) != 0;
    state.dpad_right = (b0 & 0x08u) != 0;
    if (b0 & 0x10u) state.buttons |= Start;
    if (b0 & 0x20u) state.buttons |= Back;
    if (b0 & 0x40u) state.buttons |= L3;
    if (b0 & 0x80u) state.buttons |= R3;
    if (b1 & 0x01u) state.buttons |= LB;
    if (b1 & 0x02u) state.buttons |= RB;
    if (b1 & 0x04u) state.buttons |= Guide;
    if (b1 & 0x10u) state.buttons |= A;
    if (b1 & 0x20u) state.buttons |= B;
    if (b1 & 0x40u) state.buttons |= X;
    if (b1 & 0x80u) state.buttons |= Y;
    state.left_trigger = data[4];
    state.right_trigger = data[5];
    state.left_x = read_s16(data + 6);
    state.left_y = read_s16(data + 8);
    state.right_x = read_s16(data + 10);
    state.right_y = read_s16(data + 12);
    return state;
}

WiredController::WiredController() {
    const int rc = libusb_init(&context_);
    if (rc != LIBUSB_SUCCESS) context_ = nullptr;
}

WiredController::~WiredController() {
    stop();
    close_device();
    if (context_) libusb_exit(context_);
}

std::vector<WiredControllerInfo> WiredController::discover(
    bool include_unknown_matches, std::string* error) {
    libusb_context* context = nullptr;
    const int rc = libusb_init(&context);
    if (rc != LIBUSB_SUCCESS) {
        if (error) *error = "libusb_init failed: " + libusb_error(rc);
        return {};
    }
    auto candidates = collect_candidates(context, include_unknown_matches, error);
    std::vector<WiredControllerInfo> info;
    info.reserve(candidates.size());
    for (const auto& candidate : candidates) info.push_back(candidate.info);
    release_candidates(candidates);
    libusb_exit(context);
    return info;
}

bool WiredController::open(const WiredControllerOptions& options,
                           WiredControllerCallback controller_callback,
                           LogCallback log_callback,
                           std::string* error) {
    stop();
    close_device();
    if (!context_) {
        if (error) *error = "libusb could not be initialized";
        return false;
    }

    options_ = options;
    controller_callback_ = std::move(controller_callback);
    log_callback_ = std::move(log_callback);

    auto candidates = collect_candidates(context_,
        options.allow_unknown_protocol_match, error);
    if (candidates.empty()) {
        if (error && error->empty()) {
            *error = "no compatible Xbox 360 wired USB controller found";
        }
        return false;
    }
    if (options.controller_index >= candidates.size()) {
        if (error) {
            *error = "wired controller index " +
                     std::to_string(options.controller_index) +
                     " is out of range (found " +
                     std::to_string(candidates.size()) + ")";
        }
        release_candidates(candidates);
        return false;
    }

    Candidate& selected = candidates[options.controller_index];
    const int rc = libusb_open(selected.device, &handle_);
    if (rc != LIBUSB_SUCCESS) {
        if (error) *error = "could not open wired controller " +
                            usb_id_string(selected.info.id.vendor,
                                          selected.info.id.product) +
                            ": " + libusb_error(rc);
        release_candidates(candidates);
        return false;
    }
    info_ = selected.info;

    const auto& match = selected.interface;
    const int claim_rc = libusb_claim_interface(handle_, match.interface_number);
    if (claim_rc != LIBUSB_SUCCESS) {
        if (error) {
            *error = "could not claim wired controller interface " +
                     std::to_string(match.interface_number) + ": " +
                     libusb_error(claim_rc) +
                     ". Close other controller tools or legacy drivers and try again.";
        }
        release_candidates(candidates);
        close_device();
        return false;
    }
    if (match.alternate_setting != 0) {
        const int alt_rc = libusb_set_interface_alt_setting(
            handle_, match.interface_number, match.alternate_setting);
        if (alt_rc != LIBUSB_SUCCESS) {
            if (error) *error = "failed to select wired controller alternate setting: " +
                                libusb_error(alt_rc);
            libusb_release_interface(handle_, match.interface_number);
            release_candidates(candidates);
            close_device();
            return false;
        }
    }

    endpoints_ = std::make_unique<EndpointSet>();
    endpoints_->interface_number = match.interface_number;
    endpoints_->alternate_setting = match.alternate_setting;
    endpoints_->endpoint_in = match.endpoint_in;
    endpoints_->endpoint_out = match.endpoint_out;

    release_candidates(candidates);
    return true;
}

bool WiredController::start(std::string* error) {
    if (!handle_ || !endpoints_) {
        if (error) *error = "wired controller is not open";
        return false;
    }
    if (running_.exchange(true)) return true;
    thread_ = std::thread([this] { read_loop(); });
    if (controller_callback_) {
        WiredControllerEvent event;
        event.connected = true;
        controller_callback_(event);
    }
    return true;
}

void WiredController::stop() {
    running_.store(false);
    if (thread_.joinable()) thread_.join();
}

bool WiredController::set_rumble(std::uint8_t strong, std::uint8_t weak,
                                 std::string* error) {
    // Standard xpad-compatible rumble packet. Some clone devices ignore this
    // silently; failure is not fatal to input bridging.
    const std::array<std::uint8_t, 8> packet = {
        0x00, 0x08, 0x00, strong, weak, 0x00, 0x00, 0x00
    };
    return write_packet(packet.data(), packet.size(), error);
}

bool WiredController::write_packet(const std::uint8_t* data, std::size_t length,
                                   std::string* error) {
    if (!handle_ || !endpoints_ || endpoints_->endpoint_out == 0) {
        if (error) *error = "wired controller has no usable OUT endpoint";
        return false;
    }
    std::lock_guard<std::mutex> lock(endpoints_->write_mutex);
    int transferred = 0;
    auto buffer = std::vector<std::uint8_t>(data, data + length);
    const int rc = libusb_interrupt_transfer(handle_, endpoints_->endpoint_out,
                                              buffer.data(),
                                              static_cast<int>(buffer.size()),
                                              &transferred, kWriteTimeoutMs);
    if (rc != LIBUSB_SUCCESS || transferred != static_cast<int>(buffer.size())) {
        if (error) {
            *error = rc == LIBUSB_SUCCESS
                ? "short USB write (" + std::to_string(transferred) + ")"
                : libusb_error(rc);
        }
        return false;
    }
    return true;
}

void WiredController::read_loop() {
    std::array<std::uint8_t, 64> buffer{};
    while (running_.load()) {
        int transferred = 0;
        const int rc = libusb_interrupt_transfer(handle_, endpoints_->endpoint_in,
                                                  buffer.data(),
                                                  static_cast<int>(buffer.size()),
                                                  &transferred, kReadTimeoutMs);
        if (rc == LIBUSB_ERROR_TIMEOUT) continue;
        if (rc == LIBUSB_ERROR_INTERRUPTED) continue;
        if (rc == LIBUSB_ERROR_NO_DEVICE) {
            log("wired controller disconnected");
            running_.store(false);
            if (controller_callback_) {
                WiredControllerEvent event;
                event.connected = false;
                controller_callback_(event);
            }
            break;
        }
        if (rc != LIBUSB_SUCCESS) {
            log("wired controller USB read failed: " + libusb_error(rc));
            continue;
        }
        if (transferred <= 0) continue;

        if (options_.dump_raw) {
            log("wired raw: " + hex_dump(buffer.data(),
                static_cast<std::size_t>(transferred)));
        }
        const auto state = parse_wired_controller_packet(
            buffer.data(), static_cast<std::size_t>(transferred));
        if (!state.has_value()) continue;
        if (controller_callback_) {
            WiredControllerEvent event;
            event.connected = true;
            event.state = state;
            controller_callback_(event);
        }
    }
}

void WiredController::log(const std::string& message) const {
    if (log_callback_) log_callback_(message);
}

void WiredController::close_device() {
    if (handle_) {
        if (endpoints_) libusb_release_interface(handle_, endpoints_->interface_number);
        libusb_close(handle_);
        handle_ = nullptr;
    }
    endpoints_.reset();
    info_ = {};
}

}  // namespace x360bridge
