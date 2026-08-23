#include "x360bridge/receiver.hpp"

#if __has_include(<libusb.h>)
#include <libusb.h>
#elif __has_include(<libusb-1.0/libusb.h>)
#include <libusb-1.0/libusb.h>
#else
#error "libusb headers not found; install libusb and configure through pkg-config"
#endif

#include <algorithm>
#include <chrono>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <utility>

namespace x360bridge {
namespace {

constexpr std::uint8_t kInterfaceClass = 0xff;
constexpr std::uint8_t kInterfaceSubclass = 0x5d;
constexpr std::uint8_t kControllerProtocol = 0x81;
constexpr int kReadTimeoutMs = 250;
constexpr int kWriteTimeoutMs = 1000;

struct InterfaceMatch {
    int interface_number = -1;
    int alternate_setting = 0;
    std::uint8_t endpoint_in = 0;
    std::uint8_t endpoint_out = 0;
};

std::vector<InterfaceMatch> find_controller_interfaces(libusb_device* device) {
    std::vector<InterfaceMatch> matches;
    libusb_config_descriptor* config = nullptr;
    int rc = libusb_get_active_config_descriptor(device, &config);
    if (rc != LIBUSB_SUCCESS) {
        rc = libusb_get_config_descriptor(device, 0, &config);
    }
    if (rc != LIBUSB_SUCCESS || config == nullptr) {
        return matches;
    }

    for (std::uint8_t i = 0; i < config->bNumInterfaces; ++i) {
        const libusb_interface& iface = config->interface[i];
        for (int a = 0; a < iface.num_altsetting; ++a) {
            const libusb_interface_descriptor& alt = iface.altsetting[a];
            if (alt.bInterfaceClass != kInterfaceClass ||
                alt.bInterfaceSubClass != kInterfaceSubclass ||
                alt.bInterfaceProtocol != kControllerProtocol) {
                continue;
            }

            InterfaceMatch match;
            match.interface_number = alt.bInterfaceNumber;
            match.alternate_setting = alt.bAlternateSetting;
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
            if (match.endpoint_in != 0 && match.endpoint_out != 0) {
                matches.push_back(match);
            }
        }
    }
    libusb_free_config_descriptor(config);

    std::sort(matches.begin(), matches.end(),
              [](const InterfaceMatch& lhs, const InterfaceMatch& rhs) {
                  return lhs.interface_number < rhs.interface_number;
              });
    // A receiver should expose each interface once; avoid duplicate altsetting
    // entries if a clone reports redundant descriptors.
    matches.erase(std::unique(matches.begin(), matches.end(),
                              [](const InterfaceMatch& lhs,
                                 const InterfaceMatch& rhs) {
                                  return lhs.interface_number ==
                                         rhs.interface_number;
                              }),
                  matches.end());
    // The Xbox 360 receiver protocol defines four controller slots. A broken
    // clone descriptor must not make us create an unbounded number of threads.
    if (matches.size() > 4) matches.resize(4);
    return matches;
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

struct Candidate {
    libusb_device* device = nullptr;
    libusb_device_descriptor descriptor{};
    ReceiverInfo info{};
    std::vector<InterfaceMatch> interfaces;
};

std::vector<Candidate> collect_candidates(libusb_context* context,
                                          bool include_unknown,
                                          const std::optional<UsbId>& exact,
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

        const bool known = is_known_receiver_id(descriptor.idVendor,
                                                 descriptor.idProduct);
        const bool exact_match = exact.has_value() &&
            descriptor.idVendor == exact->vendor &&
            descriptor.idProduct == exact->product;
        if (exact.has_value()) {
            if (!exact_match) continue;
        } else if (!known && !include_unknown) {
            continue;
        }

        auto interfaces = find_controller_interfaces(devices[i]);
        if (interfaces.empty()) {
            continue;
        }

        Candidate candidate;
        candidate.device = devices[i];
        libusb_ref_device(candidate.device);
        candidate.descriptor = descriptor;
        candidate.interfaces = std::move(interfaces);
        candidate.info.id = {descriptor.idVendor, descriptor.idProduct};
        candidate.info.bus = libusb_get_bus_number(devices[i]);
        candidate.info.address = libusb_get_device_address(devices[i]);
        candidate.info.controller_interfaces = candidate.interfaces.size();
        candidate.info.known_id = known;

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

struct Receiver::Slot {
    int interface_number = -1;
    int alternate_setting = 0;
    std::uint8_t endpoint_in = 0;
    std::uint8_t endpoint_out = 0;
    std::mutex write_mutex;
    std::thread thread;
};

bool is_known_receiver_id(std::uint16_t vendor, std::uint16_t product) {
    if (vendor != 0x045e) return false;
    return product == 0x0291 || product == 0x02a9 || product == 0x0719;
}

std::string usb_id_string(std::uint16_t vendor, std::uint16_t product) {
    std::ostringstream out;
    out << std::hex << std::setfill('0') << std::setw(4) << vendor << ':'
        << std::setw(4) << product;
    return out.str();
}

Receiver::Receiver() {
    const int rc = libusb_init(&context_);
    if (rc != LIBUSB_SUCCESS) context_ = nullptr;
}

Receiver::~Receiver() {
    stop();
    close_device();
    if (context_) libusb_exit(context_);
}

std::vector<ReceiverInfo> Receiver::discover(bool include_unknown_matches,
                                             std::string* error) {
    libusb_context* context = nullptr;
    const int rc = libusb_init(&context);
    if (rc != LIBUSB_SUCCESS) {
        if (error) *error = "libusb_init failed: " + libusb_error(rc);
        return {};
    }
    auto candidates = collect_candidates(context, include_unknown_matches,
                                         std::nullopt, error);
    std::vector<ReceiverInfo> info;
    info.reserve(candidates.size());
    for (const auto& candidate : candidates) info.push_back(candidate.info);
    release_candidates(candidates);
    libusb_exit(context);
    return info;
}

bool Receiver::open(const ReceiverOptions& options,
                    SlotCallback slot_callback,
                    LogCallback log_callback,
                    std::string* error) {
    stop();
    close_device();
    if (!context_) {
        if (error) *error = "libusb could not be initialized";
        return false;
    }

    options_ = options;
    slot_callback_ = std::move(slot_callback);
    log_callback_ = std::move(log_callback);

    auto candidates = collect_candidates(context_,
        options.allow_unknown_protocol_match, options.exact_id, error);
    if (candidates.empty()) {
        if (error && error->empty()) {
            *error = "no compatible Xbox 360 wireless receiver found";
        }
        return false;
    }
    if (options.receiver_index >= candidates.size()) {
        if (error) {
            *error = "receiver index " + std::to_string(options.receiver_index) +
                     " is out of range (found " +
                     std::to_string(candidates.size()) + ")";
        }
        release_candidates(candidates);
        return false;
    }

    Candidate& selected = candidates[options.receiver_index];
    const int rc = libusb_open(selected.device, &handle_);
    if (rc != LIBUSB_SUCCESS) {
        if (error) *error = "could not open receiver " +
                            usb_id_string(selected.info.id.vendor,
                                          selected.info.id.product) +
                            ": " + libusb_error(rc);
        release_candidates(candidates);
        return false;
    }
    info_ = selected.info;

    for (const auto& match : selected.interfaces) {
        const int claim_rc = libusb_claim_interface(handle_,
                                                     match.interface_number);
        if (claim_rc != LIBUSB_SUCCESS) {
            if (error) {
                *error = "could not claim receiver interface " +
                         std::to_string(match.interface_number) + ": " +
                         libusb_error(claim_rc) +
                         ". Remove/disable any legacy Xbox 360 kext or other "
                         "process using the receiver.";
            }
            release_candidates(candidates);
            close_device();
            return false;
        }
        if (match.alternate_setting != 0) {
            const int alt_rc = libusb_set_interface_alt_setting(
                handle_, match.interface_number, match.alternate_setting);
            if (alt_rc != LIBUSB_SUCCESS) {
                if (error) *error = "failed to select alternate setting: " +
                                    libusb_error(alt_rc);
                libusb_release_interface(handle_, match.interface_number);
                release_candidates(candidates);
                close_device();
                return false;
            }
        }

        auto slot = std::make_unique<Slot>();
        slot->interface_number = match.interface_number;
        slot->alternate_setting = match.alternate_setting;
        slot->endpoint_in = match.endpoint_in;
        slot->endpoint_out = match.endpoint_out;
        slots_.push_back(std::move(slot));
    }
    release_candidates(candidates);

    if (slots_.empty()) {
        if (error) *error = "receiver has no usable controller interfaces";
        close_device();
        return false;
    }
    return true;
}

bool Receiver::start(std::string* error) {
    if (!handle_ || slots_.empty()) {
        if (error) *error = "receiver is not open";
        return false;
    }
    if (running_.exchange(true)) return true;

    for (std::size_t i = 0; i < slots_.size(); ++i) {
        slots_[i]->thread = std::thread([this, i] { read_loop(i); });
    }

    // The receiver emits state/status asynchronously. Query each interface so
    // controllers already connected before startup are announced immediately.
    for (std::size_t i = 0; i < slots_.size(); ++i) {
        std::string query_error;
        if (!send_presence_query(i, &query_error)) {
            log("slot " + std::to_string(i + 1) +
                " presence query failed: " + query_error);
        }
    }
    return true;
}

void Receiver::stop() {
    // A read thread may already have cleared running_ after a USB disconnect.
    // Always join any joinable thread so destruction cannot hit std::terminate.
    running_.store(false);
    for (auto& slot : slots_) {
        if (slot->thread.joinable()) slot->thread.join();
    }
}

std::size_t Receiver::slot_count() const { return slots_.size(); }

bool Receiver::send_presence_query(std::size_t slot, std::string* error) {
    return write_packet(slot, make_presence_query(), error);
}

bool Receiver::send_0165_weird_start(std::size_t slot, std::string* error) {
    return write_packet(slot, make_0165_weird_start(), error);
}

bool Receiver::set_led(std::size_t slot, std::uint8_t mode,
                       std::string* error) {
    return write_packet(slot, make_led_command(mode), error);
}

bool Receiver::set_rumble(std::size_t slot, std::uint8_t strong,
                          std::uint8_t weak, std::string* error) {
    return write_packet(slot, make_rumble_command(strong, weak), error);
}

bool Receiver::power_off(std::size_t slot, std::string* error) {
    return write_packet(slot, make_poweroff_command(), error);
}

bool Receiver::query_battery_report(std::size_t slot_index,
                                    std::vector<std::uint8_t>* response,
                                    std::string* error) {
    if (!handle_ || slot_index >= slots_.size()) {
        if (error) *error = "invalid or unavailable receiver slot";
        return false;
    }

    Slot& slot = *slots_[slot_index];
    std::array<unsigned char, 32> buffer{};

    // Experimental XUSB/HID class GET_REPORT request:
    // bmRequestType: device-to-host | class | interface = 0xA1
    // bRequest: GET_REPORT = 0x01
    // wValue: Input report (0x01) + Report ID 0x04 => 0x0104
    // wIndex: receiver controller interface number
    // This may legitimately STALL on Xbox 360 receiver implementations.
    const int rc = libusb_control_transfer(
        handle_,
        static_cast<std::uint8_t>(LIBUSB_ENDPOINT_IN |
                                  LIBUSB_REQUEST_TYPE_CLASS |
                                  LIBUSB_RECIPIENT_INTERFACE),
        0x01,
        0x0104,
        static_cast<std::uint16_t>(slot.interface_number),
        buffer.data(),
        static_cast<std::uint16_t>(buffer.size()),
        kWriteTimeoutMs);

    if (rc < 0) {
        if (error) *error = libusb_error(rc);
        return false;
    }

    if (response) {
        response->assign(buffer.begin(), buffer.begin() + rc);
    }
    return true;
}

bool Receiver::write_packet(std::size_t slot_index,
                            const std::array<std::uint8_t, 12>& packet,
                            std::string* error) {
    if (!handle_ || slot_index >= slots_.size()) {
        if (error) *error = "invalid or unavailable receiver slot";
        return false;
    }
    Slot& slot = *slots_[slot_index];
    std::lock_guard<std::mutex> lock(slot.write_mutex);

    int transferred = 0;
    // libusb's C API does not mark the output buffer const.
    auto writable = packet;
    const int rc = libusb_interrupt_transfer(handle_, slot.endpoint_out,
                                              writable.data(),
                                              static_cast<int>(writable.size()),
                                              &transferred, kWriteTimeoutMs);
    if (rc != LIBUSB_SUCCESS || transferred !=
        static_cast<int>(writable.size())) {
        if (error) {
            *error = rc == LIBUSB_SUCCESS
                ? "short USB write (" + std::to_string(transferred) + ")"
                : libusb_error(rc);
        }
        return false;
    }
    return true;
}

void Receiver::read_loop(std::size_t slot_index) {
    Slot& slot = *slots_[slot_index];
    std::array<std::uint8_t, 64> buffer{};

    while (running_.load()) {
        int transferred = 0;
        const int rc = libusb_interrupt_transfer(
            handle_, slot.endpoint_in, buffer.data(),
            static_cast<int>(buffer.size()), &transferred, kReadTimeoutMs);

        if (rc == LIBUSB_ERROR_TIMEOUT || rc == LIBUSB_ERROR_INTERRUPTED) {
            continue;
        }
        if (rc == LIBUSB_ERROR_NO_DEVICE) {
            log("receiver disconnected");
            running_.store(false);
            break;
        }
        if (rc != LIBUSB_SUCCESS) {
            // 360Controller 0.16.5 recovered from pipe overruns by clearing the
            // stalled controller input pipe and immediately queueing another read.
            // Mirror that behavior with libusb.
            if (rc == LIBUSB_ERROR_PIPE || rc == LIBUSB_ERROR_OVERFLOW ||
                rc == LIBUSB_ERROR_IO) {
                const int clear_rc = libusb_clear_halt(handle_, slot.endpoint_in);
                if (slot_index == 0 || options_.dump_raw) {
                    log("slot " + std::to_string(slot_index + 1) +
                        " USB read failed: " + libusb_error(rc) +
                        "; clear_halt=" + libusb_error(clear_rc));
                }
                continue;
            }

            // Suppress noisy transient errors on unused slots unless raw
            // packet logging was explicitly requested.
            if (slot_index == 0 || options_.dump_raw) {
                log("slot " + std::to_string(slot_index + 1) +
                    " USB read failed: " + libusb_error(rc));
            }
            continue;
        }
        if (transferred <= 0) continue;

        const std::size_t length = static_cast<std::size_t>(transferred);

        if (options_.dump_raw) {
            log("slot " + std::to_string(slot_index + 1) + " raw: " +
                hex_dump(buffer.data(), length));
        }

        const bool initial_announcement =
            length >= 29 &&
            buffer[0] == 0x00u && buffer[1] == 0x0fu &&
            buffer[2] == 0x00u && buffer[3] == 0xf0u;

        const bool dedicated_battery =
            length >= 5 &&
            buffer[0] == 0x00u && buffer[1] == 0x00u &&
            buffer[2] == 0x00u && buffer[3] == 0x13u;

        const bool presence =
            length >= 2 && (buffer[0] & 0x08u) != 0u;

        const bool rssi =
            length >= 3 && buffer[0] == 0x00u && buffer[1] == 0xf8u;

        const bool battery_pid =
            (length >= 2 && buffer[1] == 0x09u) ||
            (length >= 4 && buffer[3] == 0x09u);

        const bool contains_13 =
            std::find(buffer.begin(), buffer.begin() + length, 0x13u) !=
            buffer.begin() + length;

        const bool controller_input =
            length >= 18 && buffer[1] == 0x01u;

        // Battery Protocol Hunt: classify every non-input packet on slot 1.
        if (slot_index == 0 && !controller_input) {
            std::string kind = "unclassified";
            if (initial_announcement) kind = "initial-announcement";
            else if (dedicated_battery) kind = "dedicated-battery";
            else if (battery_pid) kind = "battery-pid-0x09";
            else if (rssi) kind = "wireless-link-rssi";
            else if (presence) kind = "presence/status";
            else if (contains_13) kind = "contains-0x13";

            log("slot 1 research [" + kind + "] len=" +
                std::to_string(length) + ", packet=" +
                hex_dump(buffer.data(), length));
        }

        const auto parsed = parse_wireless_packet(buffer.data(), length);
        if (!parsed.has_value()) {
            log("slot " + std::to_string(slot_index + 1) +
                " received a malformed packet");
            continue;
        }

        if (parsed->battery_candidate.has_value()) {
            log("slot " + std::to_string(slot_index + 1) +
                " battery candidate [initial byte17] raw=0x" +
                hex_dump(&buffer[17], 1));
        }

        if (parsed->battery.has_value()) {
            if (parsed->battery->dedicated_update) {
                log("slot " + std::to_string(slot_index + 1) +
                    " battery dynamic [00 00 00 13 byte4] raw=0x" +
                    hex_dump(&buffer[4], 1) +
                    " (" + std::to_string(
                        static_cast<unsigned>(parsed->battery->legacy_percentage())) +
                    "% legacy 0.16.5 scale)");
            } else if (parsed->battery_candidate.has_value()) {
                log("slot " + std::to_string(slot_index + 1) +
                    " battery initial [00 0f ... byte17] raw=0x" +
                    hex_dump(&buffer[17], 1) +
                    " (" + std::to_string(
                        static_cast<unsigned>(parsed->battery->legacy_percentage())) +
                    "% legacy 0.16.5 scale)");
            }
        }

        if (parsed->battery_pid_packet) {
            log("slot " + std::to_string(slot_index + 1) +
                " battery PID candidate [bType 0x09], packet=" +
                hex_dump(buffer.data(), length));
        }

        if (!parsed->connected.has_value() &&
            !parsed->state.has_value() &&
            !parsed->battery_candidate.has_value() &&
            !parsed->battery.has_value() &&
            !parsed->battery_pid_packet) {
            continue;
        }

        if (slot_callback_) {
            SlotEvent event;
            event.slot = slot_index;
            event.connected = parsed->connected;
            event.headset_present = parsed->headset_present;
            event.state = parsed->state;
            event.battery_candidate = parsed->battery_candidate;
            event.battery = parsed->battery;
            event.battery_pid_packet = parsed->battery_pid_packet;
            slot_callback_(event);
        }
    }
}

void Receiver::log(const std::string& message) const {
    if (log_callback_) log_callback_(message);
}

void Receiver::close_device() {
    if (handle_) {
        for (const auto& slot : slots_) {
            libusb_release_interface(handle_, slot->interface_number);
        }
        libusb_close(handle_);
        handle_ = nullptr;
    }
    slots_.clear();
    info_ = {};
}

}  // namespace x360bridge
