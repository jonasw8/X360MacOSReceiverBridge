#include "x360bridge/hid_report.hpp"
#include "x360bridge/protocol.hpp"

#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>

using namespace x360bridge;

namespace {

void check(bool condition, const char* expression, int line) {
    if (!condition) {
        throw std::runtime_error("check failed at line " +
                                 std::to_string(line) + ": " + expression);
    }
}

#define CHECK(expression) check(static_cast<bool>(expression), #expression, __LINE__)

void write_le16(std::uint8_t* p, std::int16_t value) {
    const auto raw = static_cast<std::uint16_t>(value);
    p[0] = static_cast<std::uint8_t>(raw & 0xffu);
    p[1] = static_cast<std::uint8_t>((raw >> 8u) & 0xffu);
}

void test_presence() {
    const std::uint8_t connected[] = {0x08, 0xc0};
    auto event = parse_wireless_packet(connected, sizeof(connected));
    CHECK(event.has_value());
    CHECK(event->connected.has_value() && event->connected.value());
    CHECK(event->headset_present);
    CHECK(!event->state.has_value());

    const std::uint8_t disconnected[] = {0x08, 0x00};
    event = parse_wireless_packet(disconnected, sizeof(disconnected));
    CHECK(event.has_value());
    CHECK(event->connected.has_value() && !event->connected.value());
    CHECK(!event->headset_present);
}

void test_input_decode() {
    std::array<std::uint8_t, 29> packet{};
    packet[1] = 0x01;
    std::uint8_t* p = packet.data() + 4;
    p[0] = 0x00;
    p[1] = 0x14;
    p[2] = 0x01 | 0x08 | 0x10 | 0x20 | 0x40 | 0x80;
    p[3] = 0x01 | 0x02 | 0x04 | 0x10 | 0x20 | 0x40 | 0x80;
    p[4] = 17;
    p[5] = 231;
    write_le16(p + 6, -12345);
    write_le16(p + 8, 23456);
    write_le16(p + 10, 32767);
    write_le16(p + 12, -32768);

    const auto event = parse_wireless_packet(packet.data(), packet.size());
    CHECK(event.has_value());
    CHECK(event->connected.has_value() && event->connected.value());
    CHECK(event->state.has_value());
    const State& s = event->state.value();
    CHECK(s.dpad_up && !s.dpad_down && !s.dpad_left && s.dpad_right);
    CHECK((s.buttons & A) != 0 && (s.buttons & B) != 0);
    CHECK((s.buttons & X) != 0 && (s.buttons & Y) != 0);
    CHECK((s.buttons & LB) != 0 && (s.buttons & RB) != 0);
    CHECK((s.buttons & Guide) != 0 && (s.buttons & Start) != 0);
    CHECK((s.buttons & Back) != 0 && (s.buttons & L3) != 0 &&
          (s.buttons & R3) != 0);
    CHECK(s.left_trigger == 17 && s.right_trigger == 231);
    CHECK(s.left_x == -12345 && s.left_y == 23456);
    CHECK(s.right_x == 32767 && s.right_y == -32768);
    CHECK(dpad_to_hat(s) == 1);
}

void test_truncation_and_unknown_payload() {
    const std::uint8_t short_input[] = {0x00, 0x01, 0x00};
    CHECK(!parse_wireless_packet(short_input, sizeof(short_input)).has_value());
    CHECK(!parse_wireless_packet(nullptr, 0).has_value());

    std::array<std::uint8_t, 29> unknown{};
    unknown[1] = 0x01;
    unknown[4] = 0x07;
    const auto event = parse_wireless_packet(unknown.data(), unknown.size());
    CHECK(event.has_value());
    CHECK(!event->state.has_value());
}

void test_hat() {
    State s;
    CHECK(dpad_to_hat(s) == 8);
    s.dpad_up = true;
    CHECK(dpad_to_hat(s) == 0);
    s.dpad_right = true;
    CHECK(dpad_to_hat(s) == 1);
    s.dpad_up = false;
    CHECK(dpad_to_hat(s) == 2);
    s.dpad_down = true;
    CHECK(dpad_to_hat(s) == 3);
    s.dpad_right = false;
    CHECK(dpad_to_hat(s) == 4);
    s.dpad_left = true;
    CHECK(dpad_to_hat(s) == 5);
}

void test_commands() {
    const auto query = make_presence_query();
    CHECK(query[0] == 0x08 && query[2] == 0x0f && query[3] == 0xc0);
    const auto led = make_led_command(7);
    CHECK(led[2] == 0x08 && led[3] == 0x47);
    const auto wrapped_led = make_led_command(0x17);
    CHECK(wrapped_led[3] == 0x47);
    const auto rumble = make_rumble_command(0xaa, 0x55);
    CHECK(rumble[5] == 0xaa && rumble[6] == 0x55);
    const auto poweroff = make_poweroff_command();
    CHECK(poweroff[2] == 0x08 && poweroff[3] == 0xc0);
}

void test_hid_report() {
    State s;
    s.buttons = A | Guide;
    s.dpad_left = true;
    s.left_x = 0x1234;
    s.left_y = 0x0102;
    s.right_x = -2;
    s.right_y = -32768;
    s.left_trigger = 3;
    s.right_trigger = 4;

    HidOptions options;
    options.invert_y = false;
    const auto report = make_hid_input_report(s, options);
    CHECK(report.size() == kHidInputReportSize);
    CHECK(report[0] == 1);
    CHECK(report[1] == 0x01 && report[2] == 0x04);
    CHECK(report[3] == 6);
    CHECK(report[4] == 0x34 && report[5] == 0x12);
    CHECK(report[6] == 0x02 && report[7] == 0x01);
    CHECK(report[8] == 0xfe && report[9] == 0xff);
    CHECK(report[10] == 0x00 && report[11] == 0x80);
    CHECK(report[12] == 3 && report[13] == 4);

    options.invert_y = true;
    const auto inverted = make_hid_input_report(s, options);
    CHECK(inverted[6] == 0xfd && inverted[7] == 0xfe);
    CHECK(inverted[10] == 0xff && inverted[11] == 0x7f);

    const auto descriptor = make_hid_report_descriptor(options);
    CHECK(!descriptor.empty());
    CHECK(descriptor.front() == 0x05 && descriptor.back() == 0xc0);
}

void test_deadzone() {
    State s;
    s.left_x = 99;
    s.left_y = -100;
    s.right_x = 101;
    s.right_y = -32768;
    s = apply_deadzone(s, 101);
    CHECK(s.left_x == 0 && s.left_y == 0);
    CHECK(s.right_x == 101 && s.right_y == -32768);
}

}  // namespace

int main() {
    try {
        test_presence();
        test_input_decode();
        test_truncation_and_unknown_payload();
        test_hat();
        test_commands();
        test_hid_report();
        test_deadzone();
        std::cout << "protocol_tests: all tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "protocol_tests: " << error.what() << '\n';
        return 1;
    }
}
