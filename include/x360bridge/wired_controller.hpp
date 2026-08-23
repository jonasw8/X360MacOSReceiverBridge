#pragma once

#include "x360bridge/protocol.hpp"
#include "x360bridge/receiver.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

struct libusb_context;
struct libusb_device_handle;

namespace x360bridge {

struct WiredControllerInfo {
    UsbId id;
    std::uint8_t bus = 0;
    std::uint8_t address = 0;
    std::string manufacturer;
    std::string product;
    std::string serial;
    bool known_id = false;
    bool protocol_match = false;
};

struct WiredControllerOptions {
    std::size_t controller_index = 0;
    bool allow_unknown_protocol_match = false;
    bool dump_raw = false;
};

struct WiredControllerEvent {
    bool connected = true;
    std::optional<State> state;
};

using WiredControllerCallback = std::function<void(const WiredControllerEvent&)>;

class WiredController {
public:
    WiredController();
    ~WiredController();

    WiredController(const WiredController&) = delete;
    WiredController& operator=(const WiredController&) = delete;

    static std::vector<WiredControllerInfo> discover(bool include_unknown_matches,
                                                     std::string* error = nullptr);

    bool open(const WiredControllerOptions& options,
              WiredControllerCallback controller_callback,
              LogCallback log_callback,
              std::string* error = nullptr);
    bool start(std::string* error = nullptr);
    void stop();

    bool is_open() const { return handle_ != nullptr; }
    bool is_running() const { return running_.load(); }
    const WiredControllerInfo& info() const { return info_; }

    bool set_rumble(std::uint8_t strong, std::uint8_t weak,
                    std::string* error = nullptr);

private:
    struct EndpointSet;

    bool write_packet(const std::uint8_t* data, std::size_t length,
                      std::string* error = nullptr);
    void read_loop();
    void log(const std::string& message) const;
    void close_device();

    libusb_context* context_ = nullptr;
    libusb_device_handle* handle_ = nullptr;
    WiredControllerInfo info_{};
    WiredControllerOptions options_{};
    WiredControllerCallback controller_callback_;
    LogCallback log_callback_;
    std::unique_ptr<EndpointSet> endpoints_;
    std::thread thread_;
    std::atomic<bool> running_{false};
};

bool is_known_wired_controller_id(std::uint16_t vendor, std::uint16_t product);
std::optional<State> parse_wired_controller_packet(const std::uint8_t* data,
                                                   std::size_t length);

}  // namespace x360bridge
