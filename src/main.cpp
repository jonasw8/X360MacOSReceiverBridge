#include "x360bridge/receiver.hpp"
#include "x360bridge/virtual_gamepad.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using namespace std::chrono_literals;

namespace {

volatile std::sig_atomic_t g_keep_running = 1;

void signal_handler(int) { g_keep_running = 0; }

struct Options {
    bool list = false;
    bool help = false;
    bool allow_unknown = false;
    bool dump_state = false;
    bool dump_raw = false;
    bool no_hid = false;
    bool no_invert_y = false;
    bool gamepad_usage = false;
    std::size_t receiver_index = 0;
    std::int16_t deadzone = 0;
    std::uint16_t virtual_vid = 0x1209;
    std::uint16_t virtual_pid = 0x0360;
    std::optional<x360bridge::UsbId> exact_id;
    std::optional<std::size_t> led_slot;
    std::uint8_t led_mode = 0;
    std::optional<std::size_t> rumble_slot;
    std::optional<std::size_t> power_off_slot;
    std::uint8_t rumble_strong = 0;
    std::uint8_t rumble_weak = 0;
    int rumble_ms = 750;
};

std::uint32_t parse_unsigned(const std::string& text, std::uint32_t maximum,
                             const std::string& label) {
    std::size_t consumed = 0;
    unsigned long value = 0;
    try {
        value = std::stoul(text, &consumed, 0);
    } catch (const std::exception&) {
        throw std::runtime_error("invalid " + label + ": " + text);
    }
    if (consumed != text.size() || value > maximum) {
        throw std::runtime_error("invalid " + label + ": " + text);
    }
    return static_cast<std::uint32_t>(value);
}

std::vector<std::string> split(const std::string& text, char delimiter) {
    std::vector<std::string> parts;
    std::stringstream stream(text);
    std::string part;
    while (std::getline(stream, part, delimiter)) parts.push_back(part);
    return parts;
}

x360bridge::UsbId parse_usb_id(const std::string& text) {
    const auto parts = split(text, ':');
    if (parts.size() != 2) {
        throw std::runtime_error("USB ID must be VID:PID, for example 0x045e:0x0719");
    }
    const auto parse_hex = [](std::string value, const std::string& label) {
        if (value.rfind("0x", 0) == 0 || value.rfind("0X", 0) == 0) {
            value.erase(0, 2);
        }
        if (value.empty() || value.size() > 4) {
            throw std::runtime_error("invalid " + label + ": " + value);
        }
        std::size_t consumed = 0;
        unsigned long parsed = 0;
        try {
            parsed = std::stoul(value, &consumed, 16);
        } catch (const std::exception&) {
            throw std::runtime_error("invalid " + label + ": " + value);
        }
        if (consumed != value.size() || parsed > 0xffffu) {
            throw std::runtime_error("invalid " + label + ": " + value);
        }
        return static_cast<std::uint16_t>(parsed);
    };
    return {parse_hex(parts[0], "VID"), parse_hex(parts[1], "PID")};
}

Options parse_options(int argc, char** argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto need_value = [&](const std::string& name) -> std::string {
            if (i + 1 >= argc) throw std::runtime_error(name + " needs a value");
            return argv[++i];
        };

        if (arg == "--help" || arg == "-h") options.help = true;
        else if (arg == "--list") options.list = true;
        else if (arg == "--allow-unknown") options.allow_unknown = true;
        else if (arg == "--dump-state") options.dump_state = true;
        else if (arg == "--dump-raw") options.dump_raw = true;
        else if (arg == "--no-hid") options.no_hid = true;
        else if (arg == "--no-invert-y") options.no_invert_y = true;
        else if (arg == "--gamepad-usage") options.gamepad_usage = true;
        else if (arg == "--receiver-index") {
            options.receiver_index = parse_unsigned(need_value(arg), 1024, arg);
        } else if (arg == "--usb-id") {
            options.exact_id = parse_usb_id(need_value(arg));
        } else if (arg == "--deadzone") {
            options.deadzone = static_cast<std::int16_t>(
                parse_unsigned(need_value(arg), 32767, arg));
        } else if (arg == "--virtual-vid") {
            options.virtual_vid = parse_usb_id(
                need_value(arg) + ":0000").vendor;
        } else if (arg == "--virtual-pid") {
            options.virtual_pid = parse_usb_id(
                "0000:" + need_value(arg)).product;
        } else if (arg == "--led") {
            const auto parts = split(need_value(arg), ':');
            if (parts.size() != 2) throw std::runtime_error("--led expects SLOT:MODE");
            const auto slot = parse_unsigned(parts[0], 4, "LED slot");
            if (slot == 0) throw std::runtime_error("slot numbers begin at 1");
            options.led_slot = slot - 1;
            options.led_mode = static_cast<std::uint8_t>(
                parse_unsigned(parts[1], 15, "LED mode"));
        } else if (arg == "--power-off") {
            const auto slot = parse_unsigned(need_value(arg), 4, "power-off slot");
            if (slot == 0) throw std::runtime_error("slot numbers begin at 1");
            options.power_off_slot = slot - 1;
        } else if (arg == "--rumble") {
            const auto parts = split(need_value(arg), ':');
            if (parts.size() < 3 || parts.size() > 4)
                throw std::runtime_error("--rumble expects SLOT:STRONG:WEAK[:MS]");
            const auto slot = parse_unsigned(parts[0], 4, "rumble slot");
            if (slot == 0) throw std::runtime_error("slot numbers begin at 1");
            options.rumble_slot = slot - 1;
            options.rumble_strong = static_cast<std::uint8_t>(
                parse_unsigned(parts[1], 255, "strong motor"));
            options.rumble_weak = static_cast<std::uint8_t>(
                parse_unsigned(parts[2], 255, "weak motor"));
            if (parts.size() == 4) {
                options.rumble_ms = static_cast<int>(
                    parse_unsigned(parts[3], 10000, "rumble duration"));
            }
        } else {
            throw std::runtime_error("unknown option: " + arg);
        }
    }
    return options;
}

void print_help(const char* program) {
    std::cout
        << "Usage: " << program << " [options]\n\n"
        << "Read an Xbox 360 wireless receiver and expose each connected pad as\n"
        << "a generic macOS HID joystick.\n\n"
        << "  --list                    list protocol-compatible receivers\n"
        << "  --receiver-index N        choose receiver from --list (default 0)\n"
        << "  --usb-id VID:PID          accept one explicit receiver USB ID\n"
        << "  --allow-unknown           accept any FF/5D/81 protocol match\n"
        << "  --no-hid                  decode only; do not create virtual HID\n"
        << "  --dump-state              print decoded state changes\n"
        << "  --dump-raw                print every USB packet\n"
        << "  --deadzone N              per-axis square deadzone, 0..32767\n"
        << "  --no-invert-y             preserve receiver Y-axis signs\n"
        << "  --gamepad-usage           HID usage 0x05 instead of Joystick 0x04\n"
        << "  --virtual-vid HEX         virtual HID VID (prototype: 1209)\n"
        << "  --virtual-pid HEX         virtual HID PID (prototype: 0360)\n"
        << "  --led SLOT:MODE           send an Xbox LED mode (slot is 1..4)\n"
        << "  --power-off SLOT          turn off the controller in a slot\n"
        << "  --rumble S:L:R[:MS]       one-shot motor test, values 0..255\n"
        << "  --help                    show this help\n\n"
        << "Known receiver IDs: 045e:0291, 045e:02a9, 045e:0719.\n";
}

class Bridge {
public:
    Bridge(x360bridge::Receiver& receiver, const Options& options)
        : receiver_(receiver), options_(options), pads_(4), connected_(4, false),
          last_states_(4) {}

    void on_event(const x360bridge::SlotEvent& event) {
        if (event.slot >= pads_.size()) return;
        std::lock_guard<std::mutex> lock(mutex_);

        if (event.connected.has_value() &&
            event.connected.value() != connected_[event.slot]) {
            connected_[event.slot] = event.connected.value();
            if (connected_[event.slot]) {
                log("controller connected on slot " +
                    std::to_string(event.slot + 1));
                std::string led_error;
                // LED modes 6..9 are steady quadrants 1..4.
                if (!receiver_.set_led(event.slot,
                                       static_cast<std::uint8_t>(6 + event.slot),
                                       &led_error)) {
                    log("could not set slot LED: " + led_error);
                }
                create_pad(event.slot);
            } else {
                log("controller disconnected from slot " +
                    std::to_string(event.slot + 1));
                pads_[event.slot].reset();
                last_states_[event.slot].reset();
            }
        }

        if (event.state.has_value()) {
            if (!connected_[event.slot]) {
                connected_[event.slot] = true;
                create_pad(event.slot);
            }
            auto state = x360bridge::apply_deadzone(event.state.value(),
                                                    options_.deadzone);
            if (options_.dump_state &&
                (!last_states_[event.slot].has_value() ||
                 last_states_[event.slot].value() != state)) {
                log("slot " + std::to_string(event.slot + 1) + " " +
                    x360bridge::state_to_string(state));
            }
            last_states_[event.slot] = state;
            if (pads_[event.slot]) {
                std::string error;
                if (!pads_[event.slot]->submit(state, &error)) {
                    log("slot " + std::to_string(event.slot + 1) +
                        " HID submission failed: " + error);
                }
            }
        }
    }

    void shutdown() {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto& pad : pads_) pad.reset();
    }

private:
    void create_pad(std::size_t slot) {
        if (options_.no_hid || pads_[slot]) return;
        x360bridge::VirtualGamepadOptions virtual_options;
        virtual_options.hid.invert_y = !options_.no_invert_y;
        virtual_options.hid.joystick_usage = !options_.gamepad_usage;
        virtual_options.vendor_id = options_.virtual_vid;
        virtual_options.product_id = options_.virtual_pid;
        auto pad = std::make_unique<x360bridge::VirtualGamepad>(slot,
                                                                virtual_options);
        std::string error;
        if (!pad->create(&error)) {
            log("slot " + std::to_string(slot + 1) +
                " virtual HID unavailable: " + error +
                " Decode/USB operation will continue.");
            return;
        }
        log("created virtual HID gamepad for slot " +
            std::to_string(slot + 1));
        pads_[slot] = std::move(pad);
    }

    static void log(const std::string& message) {
        static std::mutex output_mutex;
        std::lock_guard<std::mutex> lock(output_mutex);
        std::cout << message << std::endl;
    }

    x360bridge::Receiver& receiver_;
    const Options& options_;
    std::mutex mutex_;
    std::vector<std::unique_ptr<x360bridge::VirtualGamepad>> pads_;
    std::vector<bool> connected_;
    std::vector<std::optional<x360bridge::State>> last_states_;
};

void print_receivers() {
    std::string error;
    const auto receivers = x360bridge::Receiver::discover(true, &error);
    if (!error.empty()) std::cerr << error << '\n';
    if (receivers.empty()) {
        std::cout << "No FF/5D/81 Xbox 360 receiver interfaces found.\n";
        return;
    }
    for (std::size_t i = 0; i < receivers.size(); ++i) {
        const auto& r = receivers[i];
        std::cout << '[' << i << "] "
                  << x360bridge::usb_id_string(r.id.vendor, r.id.product)
                  << " bus=" << static_cast<unsigned>(r.bus)
                  << " address=" << static_cast<unsigned>(r.address)
                  << " slots=" << r.controller_interfaces
                  << (r.known_id ? " known" : " protocol-match/unknown-ID");
        if (!r.product.empty()) std::cout << " product=\"" << r.product << '"';
        if (!r.manufacturer.empty())
            std::cout << " manufacturer=\"" << r.manufacturer << '"';
        std::cout << '\n';
    }
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const Options options = parse_options(argc, argv);
        if (options.help) {
            print_help(argv[0]);
            return 0;
        }
        if (options.list) {
            print_receivers();
            return 0;
        }

        std::signal(SIGINT, signal_handler);
        std::signal(SIGTERM, signal_handler);

        x360bridge::Receiver receiver;
        Bridge bridge(receiver, options);
        x360bridge::ReceiverOptions receiver_options;
        receiver_options.receiver_index = options.receiver_index;
        receiver_options.allow_unknown_protocol_match = options.allow_unknown;
        receiver_options.exact_id = options.exact_id;
        receiver_options.dump_raw = options.dump_raw;

        static std::mutex log_mutex;
        const auto logger = [](const std::string& message) {
            std::lock_guard<std::mutex> lock(log_mutex);
            std::cout << message << std::endl;
        };

        std::string error;
        if (!receiver.open(receiver_options,
                           [&bridge](const x360bridge::SlotEvent& event) {
                               bridge.on_event(event);
                           }, logger, &error)) {
            std::cerr << "Error: " << error << "\nRun with --list and, for an "
                         "unusual clone, --usb-id VID:PID or --allow-unknown.\n";
            return 2;
        }

        const auto& info = receiver.info();
        std::cout << "Opened "
                  << x360bridge::usb_id_string(info.id.vendor, info.id.product)
                  << " with " << receiver.slot_count()
                  << " controller interface(s).\n";
        if (!options.no_hid) {
            std::cout << "Virtual HID mode requested with prototype identity "
                      << x360bridge::usb_id_string(options.virtual_vid,
                                                   options.virtual_pid)
                      << ". A managed Apple virtual-HID entitlement is required "
                         "on current macOS.\n";
        }

        if (!receiver.start(&error)) {
            std::cerr << "Error: " << error << '\n';
            return 3;
        }

        if (options.led_slot.has_value()) {
            if (!receiver.set_led(*options.led_slot, options.led_mode, &error)) {
                std::cerr << "LED command failed: " << error << '\n';
            }
        }

        bool one_shot_command = false;
        if (options.rumble_slot.has_value()) {
            std::this_thread::sleep_for(500ms);
            if (!receiver.set_rumble(*options.rumble_slot,
                                     options.rumble_strong,
                                     options.rumble_weak, &error)) {
                std::cerr << "Rumble command failed: " << error << '\n';
            } else {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(options.rumble_ms));
                receiver.set_rumble(*options.rumble_slot, 0, 0, nullptr);
            }
            one_shot_command = true;
        }

        if (options.power_off_slot.has_value()) {
            if (!options.rumble_slot.has_value()) {
                std::this_thread::sleep_for(500ms);
            }
            if (!receiver.power_off(*options.power_off_slot, &error)) {
                std::cerr << "Power-off command failed: " << error << '\n';
            }
            one_shot_command = true;
        }

        if (one_shot_command) g_keep_running = 0;

        while (g_keep_running != 0 && receiver.is_running()) {
            std::this_thread::sleep_for(100ms);
        }
        receiver.stop();
        bridge.shutdown();
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << "Error: " << exception.what() << '\n';
        print_help(argv[0]);
        return 1;
    }
}
