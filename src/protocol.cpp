#include "x360bridge/protocol.hpp"

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <sstream>

namespace x360bridge {
namespace {

std::int16_t read_le_i16(const std::uint8_t* p) {
    const auto raw = static_cast<std::uint16_t>(p[0]) |
                     (static_cast<std::uint16_t>(p[1]) << 8u);
    return static_cast<std::int16_t>(raw);
}

void set_if(std::uint16_t& buttons, bool condition, Button button) {
    if (condition) {
        buttons |= static_cast<std::uint16_t>(button);
    }
}

}  // namespace

bool State::operator==(const State& other) const {
    return buttons == other.buttons &&
           dpad_up == other.dpad_up &&
           dpad_down == other.dpad_down &&
           dpad_left == other.dpad_left &&
           dpad_right == other.dpad_right &&
           left_trigger == other.left_trigger &&
           right_trigger == other.right_trigger &&
           left_x == other.left_x && left_y == other.left_y &&
           right_x == other.right_x && right_y == other.right_y;
}

std::optional<WirelessEvent> parse_wireless_packet(const std::uint8_t* data,
                                                   std::size_t length) {
    if (data == nullptr || length < 2) {
        return std::nullopt;
    }

    WirelessEvent event;

    auto make_battery_status = [](std::uint8_t raw, bool dedicated) {
        BatteryInfo info;
        info.raw_status = raw;
        info.dedicated_update = dedicated;
        return info;
    };

    // Xbox 360 Wireless Receiver status messages used by xboxdrv:
    // 00 00 00 13 <raw battery level> ...
    if (length >= 5 && data[0] == 0x00u && data[1] == 0x00u &&
        data[2] == 0x00u && data[3] == 0x13u) {
        event.battery = make_battery_status(data[4], true);
    }

    // XUSB wireless protocol research: bType 0x09 is documented as a
    // Battery PID Packet. Receiver encapsulation can differ, so this is only
    // a marker; receiver.cpp records the full raw packet for analysis.
    //
    // We conservatively check the common bType positions seen in receiver
    // frames instead of decoding payload bits here.
    if ((length >= 2 && data[1] == 0x09u) ||
        (length >= 4 && data[3] == 0x09u)) {
        event.battery_pid_packet = true;
    }

    // Receiver status packets use bit 3 of byte 0. Byte 1 bit 7 is the
    // controller-present flag and bit 6 is the headset-present flag.
    if ((data[0] & 0x08u) != 0u) {
        event.connected = (data[1] & 0x80u) != 0u;
        event.headset_present = (data[1] & 0x40u) != 0u;
    }

    // 360Controller 0.16.5 behavior: initial info with type 0x13
    // publishes byte 17 as BatteryLevel.
    if (length >= 29 && data[0] == 0x00u && data[1] == 0x0fu &&
        data[2] == 0x00u && data[3] == 0xf0u &&
        data[16] == 0x13u) {
        event.battery_candidate = data[17];
        event.battery = make_battery_status(data[17], false);
    }

    // A wireless controller state is a wired-style Xbox 360 report beginning
    // at byte 4. Byte 1 must equal 0x01. The fields we consume end at byte 17.
    if (data[1] == 0x01u) {
        if (length < 18) {
            return std::nullopt;
        }

        const std::uint8_t* p = data + 4;
        if (p[0] != 0x00u) {
            return event;  // Well-formed receiver packet, unknown payload.
        }

        State state;
        const std::uint8_t digital0 = p[2];
        const std::uint8_t digital1 = p[3];

        state.dpad_up = (digital0 & 0x01u) != 0u;
        state.dpad_down = (digital0 & 0x02u) != 0u;
        state.dpad_left = (digital0 & 0x04u) != 0u;
        state.dpad_right = (digital0 & 0x08u) != 0u;

        set_if(state.buttons, (digital0 & 0x10u) != 0u, Button::Start);
        set_if(state.buttons, (digital0 & 0x20u) != 0u, Button::Back);
        set_if(state.buttons, (digital0 & 0x40u) != 0u, Button::L3);
        set_if(state.buttons, (digital0 & 0x80u) != 0u, Button::R3);

        set_if(state.buttons, (digital1 & 0x01u) != 0u, Button::LB);
        set_if(state.buttons, (digital1 & 0x02u) != 0u, Button::RB);
        set_if(state.buttons, (digital1 & 0x04u) != 0u, Button::Guide);
        set_if(state.buttons, (digital1 & 0x10u) != 0u, Button::A);
        set_if(state.buttons, (digital1 & 0x20u) != 0u, Button::B);
        set_if(state.buttons, (digital1 & 0x40u) != 0u, Button::X);
        set_if(state.buttons, (digital1 & 0x80u) != 0u, Button::Y);

        state.left_trigger = p[4];
        state.right_trigger = p[5];
        state.left_x = read_le_i16(p + 6);
        state.left_y = read_le_i16(p + 8);
        state.right_x = read_le_i16(p + 10);
        state.right_y = read_le_i16(p + 12);

        // Valid input proves a controller is connected even if the initial
        // status transition was missed before the interface was claimed.
        if (!event.connected.has_value()) {
            event.connected = true;
        }
        event.state = state;
    }

    return event;
}

std::uint8_t dpad_to_hat(const State& state) {
    const int x = (state.dpad_right ? 1 : 0) - (state.dpad_left ? 1 : 0);
    const int y = (state.dpad_down ? 1 : 0) - (state.dpad_up ? 1 : 0);

    if (x == 0 && y < 0) return 0;
    if (x > 0 && y < 0) return 1;
    if (x > 0 && y == 0) return 2;
    if (x > 0 && y > 0) return 3;
    if (x == 0 && y > 0) return 4;
    if (x < 0 && y > 0) return 5;
    if (x < 0 && y == 0) return 6;
    if (x < 0 && y < 0) return 7;
    return 8;
}

State apply_deadzone(State state, std::int16_t threshold) {
    if (threshold <= 0) {
        return state;
    }

    const auto filter = [threshold](std::int16_t value) -> std::int16_t {
        const int magnitude = std::abs(static_cast<int>(value));
        return magnitude < static_cast<int>(threshold) ? 0 : value;
    };

    state.left_x = filter(state.left_x);
    state.left_y = filter(state.left_y);
    state.right_x = filter(state.right_x);
    state.right_y = filter(state.right_y);
    return state;
}

std::array<std::uint8_t, 12> make_presence_query() {
    return {0x08, 0x00, 0x0f, 0xc0, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
}

std::array<std::uint8_t, 12> make_0165_weird_start() {
    // Exact 12-byte weirdStart packet used by 360Controller 0.16.5
    // WirelessHIDDevice::handleStart() and after SetLEDs().
    return {0x00, 0x00, 0x00, 0x40, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
}

std::array<std::uint8_t, 12> make_led_command(std::uint8_t mode) {
    mode &= 0x0fu;
    return {0x00, 0x00, 0x08, static_cast<std::uint8_t>(0x40u + mode),
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
}

std::array<std::uint8_t, 12> make_rumble_command(std::uint8_t strong,
                                                std::uint8_t weak) {
    return {0x00, 0x01, 0x0f, 0xc0, 0x00, strong,
            weak, 0x00, 0x00, 0x00, 0x00, 0x00};
}

std::array<std::uint8_t, 12> make_poweroff_command() {
    return {0x00, 0x00, 0x08, 0xc0, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
}

std::string state_to_string(const State& s) {
    std::ostringstream out;
    out << "buttons=0x" << std::hex << std::setw(4) << std::setfill('0')
        << s.buttons << std::dec << std::setfill(' ')
        << " hat=" << static_cast<int>(dpad_to_hat(s))
        << " lt=" << static_cast<int>(s.left_trigger)
        << " rt=" << static_cast<int>(s.right_trigger)
        << " lx=" << s.left_x << " ly=" << s.left_y
        << " rx=" << s.right_x << " ry=" << s.right_y;
    return out.str();
}

}  // namespace x360bridge
