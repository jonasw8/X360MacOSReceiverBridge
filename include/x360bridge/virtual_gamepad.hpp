#pragma once

#include "x360bridge/hid_report.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace x360bridge {

enum class VirtualHidPermissionStatus {
    unsupported,
    unknown,
    denied,
    granted,
};

const char* virtual_hid_permission_status_name(VirtualHidPermissionStatus status);
VirtualHidPermissionStatus virtual_hid_permission_status();
bool virtual_hid_accessibility_trusted();
bool virtual_hid_post_event_granted();
bool virtual_hid_restricted_entitlement_visible();
bool request_virtual_hid_permission(std::string* error = nullptr);

struct VirtualGamepadOptions {
    HidOptions hid;
    // Deliberately generic prototype identity. Do not ship these values as a
    // permanent product identity; request an assigned VID/PID before release.
    std::uint16_t vendor_id = 0x1209;
    std::uint16_t product_id = 0x0360;
    std::string manufacturer = "X360ReceiverBridge";
    std::string product = "Xbox 360 Receiver Bridge Gamepad";
};

class VirtualGamepad {
public:
    explicit VirtualGamepad(std::size_t slot,
                            VirtualGamepadOptions options = {});
    ~VirtualGamepad();

    VirtualGamepad(const VirtualGamepad&) = delete;
    VirtualGamepad& operator=(const VirtualGamepad&) = delete;

    bool create(std::string* error = nullptr);
    bool submit(const State& state, std::string* error = nullptr);
    bool is_created() const;
    void destroy();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace x360bridge
