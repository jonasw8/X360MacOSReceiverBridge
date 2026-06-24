#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>

namespace x360bridge {

// Button bit positions in State::buttons. They intentionally match the order
// used by the virtual HID report, not the receiver's wire-format bit layout.
enum Button : std::uint16_t {
    A       = 1u << 0,
    B       = 1u << 1,
    X       = 1u << 2,
    Y       = 1u << 3,
    LB      = 1u << 4,
    RB      = 1u << 5,
    Back    = 1u << 6,
    Start   = 1u << 7,
    L3      = 1u << 8,
    R3      = 1u << 9,
    Guide   = 1u << 10,
};

struct State {
    std::uint16_t buttons = 0;
    bool dpad_up = false;
    bool dpad_down = false;
    bool dpad_left = false;
    bool dpad_right = false;
    std::uint8_t left_trigger = 0;
    std::uint8_t right_trigger = 0;
    std::int16_t left_x = 0;
    std::int16_t left_y = 0;
    std::int16_t right_x = 0;
    std::int16_t right_y = 0;

    bool operator==(const State& other) const;
    bool operator!=(const State& other) const { return !(*this == other); }
};

struct WirelessEvent {
    // Set only when the receiver reports a presence transition.
    std::optional<bool> connected;
    bool headset_present = false;
    // Set when the packet carries a valid controller state.
    std::optional<State> state;
};

// Decode one packet from a protocol-0x81 Xbox 360 receiver interface.
// Returns nullopt only for malformed/truncated packets. Well-formed packets
// that contain neither presence nor input information return an empty event.
std::optional<WirelessEvent> parse_wireless_packet(const std::uint8_t* data,
                                                   std::size_t length);

inline std::optional<WirelessEvent> parse_wireless_packet(
    const std::array<std::uint8_t, 64>& data, std::size_t length) {
    return parse_wireless_packet(data.data(), length);
}

// HID hat-switch values: 0=N, 1=NE, 2=E, 3=SE, 4=S, 5=SW,
// 6=W, 7=NW, 8=neutral/null.
std::uint8_t dpad_to_hat(const State& state);

// Apply a square per-axis deadzone. Zero disables it.
State apply_deadzone(State state, std::int16_t threshold);

// Receiver commands, one per controller interface.
std::array<std::uint8_t, 12> make_presence_query();
std::array<std::uint8_t, 12> make_led_command(std::uint8_t mode);
std::array<std::uint8_t, 12> make_rumble_command(std::uint8_t strong,
                                                std::uint8_t weak);
std::array<std::uint8_t, 12> make_poweroff_command();

std::string state_to_string(const State& state);

}  // namespace x360bridge
