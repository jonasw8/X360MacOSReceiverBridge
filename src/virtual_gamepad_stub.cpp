#include "x360bridge/virtual_gamepad.hpp"

#include <utility>

namespace x360bridge {

const char* virtual_hid_permission_status_name(VirtualHidPermissionStatus status) {
    switch (status) {
        case VirtualHidPermissionStatus::unsupported: return "unsupported";
        case VirtualHidPermissionStatus::unknown: return "unknown";
        case VirtualHidPermissionStatus::denied: return "denied";
        case VirtualHidPermissionStatus::granted: return "granted";
    }
    return "unknown";
}

VirtualHidPermissionStatus virtual_hid_permission_status() {
    return VirtualHidPermissionStatus::unsupported;
}

bool virtual_hid_accessibility_trusted() {
    return false;
}

bool virtual_hid_post_event_granted() {
    return false;
}

bool virtual_hid_restricted_entitlement_visible() {
    return false;
}

bool request_virtual_hid_permission(std::string* error) {
    if (error) *error = "macOS HID post-event permission is unavailable on this platform";
    return false;
}

struct VirtualGamepad::Impl {
    std::size_t slot = 0;
    VirtualGamepadOptions options;

    Impl(std::size_t slot_number, VirtualGamepadOptions config)
        : slot(slot_number), options(std::move(config)) {}
};

VirtualGamepad::VirtualGamepad(std::size_t slot, VirtualGamepadOptions options)
    : impl_(std::make_unique<Impl>(slot, std::move(options))) {}

VirtualGamepad::~VirtualGamepad() = default;

bool VirtualGamepad::create(std::string* error) {
    if (error) {
        *error = "virtual HID output is implemented only on macOS; use --no-hid "
                 "for receiver/protocol diagnostics on this platform";
    }
    return false;
}

bool VirtualGamepad::submit(const State&, std::string* error) {
    if (error) *error = "virtual HID output is unavailable on this platform";
    return false;
}

bool VirtualGamepad::is_created() const { return false; }

void VirtualGamepad::destroy() {}

}  // namespace x360bridge
