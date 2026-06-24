#pragma once

#include "x360bridge/protocol.hpp"

#include <array>
#include <cstdint>
#include <vector>

namespace x360bridge {

struct HidOptions {
    bool invert_y = true;
    // Joystick (0x04) usually keeps SDL on its generic IOHID path. Game Pad
    // (0x05) is semantically nicer but can be routed differently by clients.
    bool joystick_usage = true;
};

constexpr std::size_t kHidInputReportSize = 14;

std::array<std::uint8_t, kHidInputReportSize> make_hid_input_report(
    const State& state, const HidOptions& options = {});

std::vector<std::uint8_t> make_hid_report_descriptor(
    const HidOptions& options = {});

}  // namespace x360bridge
