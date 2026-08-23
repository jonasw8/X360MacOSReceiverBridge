#pragma once

#include "x360bridge/protocol.hpp"

#include <array>
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

struct libusb_context;
struct libusb_device;
struct libusb_device_handle;

namespace x360bridge {

struct UsbId {
    std::uint16_t vendor = 0;
    std::uint16_t product = 0;
};

struct ReceiverInfo {
    UsbId id;
    std::uint8_t bus = 0;
    std::uint8_t address = 0;
    std::string manufacturer;
    std::string product;
    std::string serial;
    std::size_t controller_interfaces = 0;
    bool known_id = false;
};

struct ReceiverOptions {
    std::size_t receiver_index = 0;
    bool allow_unknown_protocol_match = false;
    std::optional<UsbId> exact_id;
    bool dump_raw = false;
};

struct SlotEvent {
    std::size_t slot = 0;
    std::optional<bool> connected;
    bool headset_present = false;
    std::optional<State> state;
    std::optional<std::uint8_t> battery_candidate;
    std::optional<BatteryInfo> battery;
    bool battery_pid_packet = false;
};

using SlotCallback = std::function<void(const SlotEvent&)>;
using LogCallback = std::function<void(const std::string&)>;

class Receiver {
public:
    Receiver();
    ~Receiver();

    Receiver(const Receiver&) = delete;
    Receiver& operator=(const Receiver&) = delete;

    static std::vector<ReceiverInfo> discover(bool include_unknown_matches,
                                              std::string* error = nullptr);

    bool open(const ReceiverOptions& options, SlotCallback slot_callback,
              LogCallback log_callback, std::string* error);
    bool start(std::string* error);
    void stop();

    bool is_open() const { return handle_ != nullptr; }
    bool is_running() const { return running_.load(); }
    std::size_t slot_count() const;
    const ReceiverInfo& info() const { return info_; }

    bool send_presence_query(std::size_t slot, std::string* error = nullptr);
    bool send_0165_weird_start(std::size_t slot, std::string* error = nullptr);
    bool set_led(std::size_t slot, std::uint8_t mode,
                 std::string* error = nullptr);
    bool set_rumble(std::size_t slot, std::uint8_t strong, std::uint8_t weak,
                    std::string* error = nullptr);
    bool power_off(std::size_t slot, std::string* error = nullptr);
    bool query_battery_report(std::size_t slot,
                              std::vector<std::uint8_t>* response,
                              std::string* error = nullptr);

private:
    struct Slot;

    bool write_packet(std::size_t slot,
                      const std::array<std::uint8_t, 12>& packet,
                      std::string* error);
    void read_loop(std::size_t slot_index);
    void log(const std::string& message) const;
    void close_device();

    libusb_context* context_ = nullptr;
    libusb_device_handle* handle_ = nullptr;
    ReceiverInfo info_{};
    ReceiverOptions options_{};
    SlotCallback slot_callback_;
    LogCallback log_callback_;
    std::vector<std::unique_ptr<Slot>> slots_;
    std::atomic<bool> running_{false};
};

bool is_known_receiver_id(std::uint16_t vendor, std::uint16_t product);
std::string usb_id_string(std::uint16_t vendor, std::uint16_t product);

}  // namespace x360bridge
