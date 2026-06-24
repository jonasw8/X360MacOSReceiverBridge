#include "x360bridge/hid_report.hpp"

namespace x360bridge {
namespace {

void write_le16(std::array<std::uint8_t, kHidInputReportSize>& report,
                std::size_t offset, std::uint16_t value) {
    report[offset] = static_cast<std::uint8_t>(value & 0xffu);
    report[offset + 1] = static_cast<std::uint8_t>((value >> 8u) & 0xffu);
}

std::int16_t invert_axis(std::int16_t value) {
    // Bitwise complement performs a full-range inversion without overflowing
    // at -32768, matching the established xpad mapping.
    return static_cast<std::int16_t>(~static_cast<std::uint16_t>(value));
}

}  // namespace

std::array<std::uint8_t, kHidInputReportSize> make_hid_input_report(
    const State& state, const HidOptions& options) {
    std::array<std::uint8_t, kHidInputReportSize> report{};
    report[0] = 0x01;  // Report ID.
    write_le16(report, 1, state.buttons);
    report[3] = dpad_to_hat(state);  // Upper nibble is descriptor padding.

    const std::int16_t ly = options.invert_y ? invert_axis(state.left_y)
                                             : state.left_y;
    const std::int16_t ry = options.invert_y ? invert_axis(state.right_y)
                                             : state.right_y;
    write_le16(report, 4, static_cast<std::uint16_t>(state.left_x));
    write_le16(report, 6, static_cast<std::uint16_t>(ly));
    write_le16(report, 8, static_cast<std::uint16_t>(state.right_x));
    write_le16(report, 10, static_cast<std::uint16_t>(ry));
    report[12] = state.left_trigger;
    report[13] = state.right_trigger;
    return report;
}

std::vector<std::uint8_t> make_hid_report_descriptor(const HidOptions& options) {
    // 16 buttons, one 8-way hat, four signed 16-bit stick axes, and two
    // unsigned 8-bit triggers. Report byte layout is documented in README.md.
    std::vector<std::uint8_t> d = {
        0x05, 0x01,                         // Usage Page (Generic Desktop)
        0x09, static_cast<std::uint8_t>(options.joystick_usage ? 0x04 : 0x05),
                                                 // Joystick or Game Pad
        0xa1, 0x01,                         // Collection (Application)
        0x85, 0x01,                         //   Report ID 1

        0x05, 0x09,                         //   Usage Page (Button)
        0x19, 0x01,                         //   Usage Minimum 1
        0x29, 0x10,                         //   Usage Maximum 16
        0x15, 0x00,                         //   Logical Minimum 0
        0x25, 0x01,                         //   Logical Maximum 1
        0x75, 0x01,                         //   Report Size 1
        0x95, 0x10,                         //   Report Count 16
        0x81, 0x02,                         //   Input (Data,Var,Abs)

        0x05, 0x01,                         //   Usage Page (Generic Desktop)
        0x09, 0x39,                         //   Usage (Hat Switch)
        0x15, 0x00,                         //   Logical Minimum 0
        0x25, 0x07,                         //   Logical Maximum 7
        0x35, 0x00,                         //   Physical Minimum 0
        0x46, 0x3b, 0x01,                   //   Physical Maximum 315
        0x65, 0x14,                         //   Unit (degrees)
        0x75, 0x04,                         //   Report Size 4
        0x95, 0x01,                         //   Report Count 1
        0x81, 0x42,                         //   Input (Data,Var,Abs,Null)
        0x65, 0x00,                         //   Unit (None)
        0x75, 0x04,                         //   Padding size 4
        0x95, 0x01,                         //   Padding count 1
        0x81, 0x01,                         //   Input (Constant)

        0x05, 0x01,                         //   Usage Page (Generic Desktop)
        0x09, 0x30,                         //   Usage X
        0x09, 0x31,                         //   Usage Y
        0x09, 0x33,                         //   Usage Rx
        0x09, 0x34,                         //   Usage Ry
        0x16, 0x00, 0x80,                   //   Logical Minimum -32768
        0x26, 0xff, 0x7f,                   //   Logical Maximum 32767
        0x75, 0x10,                         //   Report Size 16
        0x95, 0x04,                         //   Report Count 4
        0x81, 0x02,                         //   Input (Data,Var,Abs)

        0x05, 0x02,                         //   Usage Page (Simulation)
        0x09, 0xc5,                         //   Usage Brake (left trigger)
        0x09, 0xc4,                         //   Usage Accelerator (right trigger)
        0x15, 0x00,                         //   Logical Minimum 0
        0x26, 0xff, 0x00,                   //   Logical Maximum 255
        0x75, 0x08,                         //   Report Size 8
        0x95, 0x02,                         //   Report Count 2
        0x81, 0x02,                         //   Input (Data,Var,Abs)

        0xc0                                // End Collection
    };
    return d;
}

}  // namespace x360bridge
