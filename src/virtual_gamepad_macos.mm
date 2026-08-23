#include "x360bridge/virtual_gamepad.hpp"

#import <CoreFoundation/CoreFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDLib.h>
#import <Security/Security.h>
#if __has_include(<IOKit/hidsystem/IOHIDLib.h>)
#import <IOKit/hidsystem/IOHIDLib.h>
#endif
#import <dispatch/dispatch.h>
#import <mach/mach_time.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <sstream>
#include <string>
#include <utility>

namespace x360bridge {
namespace {

// IOHIDUserDevice is documented as public API, but some Command Line Tools
// SDKs omit IOKit/hid/IOHIDUserDevice.h. Bind the documented symbols at run
// time so the project builds with either Command Line Tools or full Xcode.
// Keep the opaque type local; only its pointer ABI is needed for dlsym calls.
struct __IOHIDUserDevice;
using IOHIDUserDeviceRef = __IOHIDUserDevice*;

struct HidUserDeviceApi {
    using CreateWithPropertiesFn = IOHIDUserDeviceRef (*)(
        CFAllocatorRef, CFDictionaryRef, IOOptionBits);
    using SetDispatchQueueFn = void (*)(IOHIDUserDeviceRef,
                                        dispatch_queue_t);
    using SetCancelHandlerFn = void (*)(IOHIDUserDeviceRef,
                                        dispatch_block_t);
    using ActivateFn = void (*)(IOHIDUserDeviceRef);
    using CancelFn = void (*)(IOHIDUserDeviceRef);
    using HandleReportWithTimeStampFn = IOReturn (*)(
        IOHIDUserDeviceRef, std::uint64_t, std::uint8_t*, CFIndex);

    CreateWithPropertiesFn create_with_properties = nullptr;
    SetDispatchQueueFn set_dispatch_queue = nullptr;
    SetCancelHandlerFn set_cancel_handler = nullptr;
    ActivateFn activate = nullptr;
    CancelFn cancel = nullptr;
    HandleReportWithTimeStampFn handle_report_with_timestamp = nullptr;
    std::string error;

    bool available() const {
        return create_with_properties && set_dispatch_queue &&
               set_cancel_handler && activate && cancel &&
               handle_report_with_timestamp;
    }
};

template <typename Function>
bool bind_iokit_symbol(Function* destination, const char* name,
                       std::string* error) {
    static_assert(sizeof(Function) == sizeof(void*),
                  "macOS function pointers must match data-pointer size");
    dlerror();
    void* symbol = dlsym(RTLD_DEFAULT, name);
    const char* loader_error = dlerror();
    if (!symbol || loader_error) {
        if (error) {
            *error = "missing IOKit symbol ";
            *error += name;
            if (loader_error) {
                *error += ": ";
                *error += loader_error;
            }
        }
        return false;
    }
    std::memcpy(destination, &symbol, sizeof(symbol));
    return true;
}

template <typename Function>
Function load_function_symbol(const char* name) {
    static_assert(sizeof(Function) == sizeof(void*),
                  "macOS function pointers must match data-pointer size");
    dlerror();
    void* symbol = dlsym(RTLD_DEFAULT, name);
    const char* loader_error = dlerror();
    if (!symbol || loader_error) return nullptr;
    Function function = nullptr;
    std::memcpy(&function, &symbol, sizeof(symbol));
    return function;
}

HidUserDeviceApi load_hid_user_device_api() {
    HidUserDeviceApi api;
    if (!bind_iokit_symbol(&api.create_with_properties,
                           "IOHIDUserDeviceCreateWithProperties", &api.error) ||
        !bind_iokit_symbol(&api.set_dispatch_queue,
                           "IOHIDUserDeviceSetDispatchQueue", &api.error) ||
        !bind_iokit_symbol(&api.set_cancel_handler,
                           "IOHIDUserDeviceSetCancelHandler", &api.error) ||
        !bind_iokit_symbol(&api.activate, "IOHIDUserDeviceActivate",
                           &api.error) ||
        !bind_iokit_symbol(&api.cancel, "IOHIDUserDeviceCancel",
                           &api.error) ||
        !bind_iokit_symbol(&api.handle_report_with_timestamp,
                           "IOHIDUserDeviceHandleReportWithTimeStamp",
                           &api.error)) {
        return api;
    }
    return api;
}

const HidUserDeviceApi& hid_user_device_api() {
    static const HidUserDeviceApi api = load_hid_user_device_api();
    return api;
}

void dictionary_set_number(CFMutableDictionaryRef dictionary,
                           CFStringRef key, std::int32_t value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault,
                                        kCFNumberSInt32Type, &value);
    if (number) {
        CFDictionarySetValue(dictionary, key, number);
        CFRelease(number);
    }
}

void dictionary_set_string(CFMutableDictionaryRef dictionary,
                           CFStringRef key, const std::string& value) {
    CFStringRef string = CFStringCreateWithCString(
        kCFAllocatorDefault, value.c_str(), kCFStringEncodingUTF8);
    if (string) {
        CFDictionarySetValue(dictionary, key, string);
        CFRelease(string);
    }
}

std::string io_error(IOReturn result) {
    std::ostringstream out;
    out << "IOReturn 0x" << std::hex << static_cast<std::uint32_t>(result);
    return out.str();
}

using CGPreflightPostEventAccessFn = bool (*)();
using CGRequestPostEventAccessFn = bool (*)();

bool post_event_preflight() {
    static CGPreflightPostEventAccessFn preflight =
        load_function_symbol<CGPreflightPostEventAccessFn>("CGPreflightPostEventAccess");
    if (preflight) return preflight();
    return IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted;
}

bool post_event_request() {
    static CGRequestPostEventAccessFn request =
        load_function_symbol<CGRequestPostEventAccessFn>("CGRequestPostEventAccess");
    if (request) return request();
    return IOHIDRequestAccess(kIOHIDRequestTypePostEvent);
}

bool accessibility_trusted(bool prompt) {
    if (AXIsProcessTrusted()) return true;
    if (!prompt) return false;

    const void* keys[] = { kAXTrustedCheckOptionPrompt };
    const void* values[] = { kCFBooleanTrue };
    CFDictionaryRef options = CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const bool trusted = options ? AXIsProcessTrustedWithOptions(options)
                                 : AXIsProcessTrusted();
    if (options) CFRelease(options);
    return trusted || AXIsProcessTrusted();
}

bool user_visible_output_permission_granted() {
    return accessibility_trusted(false) || post_event_preflight();
}

bool restricted_virtual_hid_entitlement_visible() {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return false;

    CFTypeRef value = SecTaskCopyValueForEntitlement(
        task, CFSTR("com.apple.developer.hid.virtual.device"), nullptr);
    CFRelease(task);
    if (!value) return false;

    bool visible = false;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        visible = CFBooleanGetValue(static_cast<CFBooleanRef>(value));
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 0;
        visible = CFNumberGetValue(static_cast<CFNumberRef>(value),
                                   kCFNumberIntType, &number) && number != 0;
    }
    CFRelease(value);
    return visible;
}

}  // namespace


const char* virtual_hid_permission_status_name(VirtualHidPermissionStatus status) {
    switch (status) {
        case VirtualHidPermissionStatus::unsupported: return "unsupported";
        case VirtualHidPermissionStatus::unknown: return "unknown";
        case VirtualHidPermissionStatus::denied: return "denied";
        case VirtualHidPermissionStatus::granted: return "granted";
    }
    return "unknown";
}

bool virtual_hid_accessibility_trusted() {
    return user_visible_output_permission_granted();
}

bool virtual_hid_post_event_granted() {
    return post_event_preflight();
}

bool virtual_hid_restricted_entitlement_visible() {
    return restricted_virtual_hid_entitlement_visible();
}

VirtualHidPermissionStatus virtual_hid_permission_status() {
    // The visible macOS privacy row for synthetic output is Accessibility, but
    // newer systems expose the actual posting privilege through the
    // CGPreflightPostEventAccess/CGRequestPostEventAccess pair. Treat either a
    // positive AX trust check or a positive post-event preflight as granted, so
    // the UI refreshes correctly after the user toggles the app in Settings.
    if (user_visible_output_permission_granted()) {
        return VirtualHidPermissionStatus::granted;
    }

    const IOHIDAccessType access = IOHIDCheckAccess(kIOHIDRequestTypePostEvent);
    if (access == kIOHIDAccessTypeDenied) {
        return VirtualHidPermissionStatus::denied;
    }
    return VirtualHidPermissionStatus::unknown;
}

bool request_virtual_hid_permission(std::string* error) {
    if (virtual_hid_permission_status() == VirtualHidPermissionStatus::granted) {
        return true;
    }

    // Kept for CLI/developer use. The AppKit UI does not call this path; it
    // opens System Settings once and then re-checks when the app becomes active.
    const bool requested = post_event_request() || accessibility_trusted(true);
    if (requested || virtual_hid_permission_status() == VirtualHidPermissionStatus::granted) {
        return true;
    }

    if (error) {
        *error = "enable X360 Controller Bridge in Privacy & Security > Accessibility, then return to the app";
    }
    return false;
}

struct VirtualGamepad::Impl {
    std::size_t slot = 0;
    VirtualGamepadOptions options;
    IOHIDUserDeviceRef device = nullptr;
    dispatch_queue_t queue = nullptr;
    dispatch_semaphore_t cancelled = nullptr;

    Impl(std::size_t slot_number, VirtualGamepadOptions config)
        : slot(slot_number), options(std::move(config)) {}
};

VirtualGamepad::VirtualGamepad(std::size_t slot,
                               VirtualGamepadOptions options)
    : impl_(std::make_unique<Impl>(slot, std::move(options))) {}

VirtualGamepad::~VirtualGamepad() { destroy(); }

bool VirtualGamepad::create(std::string* error) {
    if (impl_->device) return true;

    if (!virtual_hid_restricted_entitlement_visible()) {
        if (error) {
            *error = "the running task does not expose com.apple.developer.hid.virtual.device. Sign with the restricted virtual-HID entitlement before testing user-space HID output";
        }
        return false;
    }

    // Do not open System Settings from the hot input path. The native UI shows
    // a single Privacy row with an explicit System Settings button; creation
    // simply reports a normal actionable error until the user grants access.
    if (virtual_hid_permission_status() != VirtualHidPermissionStatus::granted) {
        if (error) {
            *error = "Accessibility approval required in Privacy & Security > Accessibility";
        }
        return false;
    }

    const auto& api = hid_user_device_api();
    if (!api.available()) {
        if (error) {
            *error = "the macOS IOHIDUserDevice API is unavailable";
            if (!api.error.empty()) *error += ": " + api.error;
        }
        return false;
    }

    const auto descriptor = make_hid_report_descriptor(impl_->options.hid);
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (!properties) {
        if (error) *error = "could not allocate HID property dictionary";
        return false;
    }

    CFDataRef report_descriptor = CFDataCreate(
        kCFAllocatorDefault, descriptor.data(),
        static_cast<CFIndex>(descriptor.size()));
    if (!report_descriptor) {
        CFRelease(properties);
        if (error) *error = "could not allocate HID report descriptor";
        return false;
    }
    CFDictionarySetValue(properties, CFSTR(kIOHIDReportDescriptorKey),
                         report_descriptor);
    CFRelease(report_descriptor);

    const HidProfile profile = impl_->options.hid.profile;
    const bool xbox360_profile = profile == HidProfile::xbox360_controller;
    const bool series_profile = profile == HidProfile::xbox_series_x_controller;
    const bool xbox_profile = xbox360_profile || series_profile;

    const std::uint16_t vendor =
        xbox_profile ? 0x045E : impl_->options.vendor_id;
    const std::uint16_t product =
        xbox360_profile ? 0x028E :
        (series_profile ? 0x0B12 : impl_->options.product_id);
    const std::string manufacturer =
        xbox_profile ? "Microsoft" : impl_->options.manufacturer;
    const std::string product_name =
        xbox360_profile ? "Xbox 360 Controller " + std::to_string(impl_->slot + 1) :
        (series_profile ? "Xbox Series X Controller " + std::to_string(impl_->slot + 1)
                        : impl_->options.product + " " + std::to_string(impl_->slot + 1));

    dictionary_set_number(properties, CFSTR(kIOHIDVendorIDKey), vendor);
    dictionary_set_number(properties, CFSTR(kIOHIDProductIDKey), product);
    dictionary_set_number(properties, CFSTR(kIOHIDVersionNumberKey), 0x0100);
    dictionary_set_number(properties, CFSTR(kIOHIDPrimaryUsagePageKey), 0x01);
    dictionary_set_number(properties, CFSTR(kIOHIDPrimaryUsageKey), xbox_profile ? 0x05
                          : (impl_->options.hid.joystick_usage ? 0x04 : 0x05));
    dictionary_set_number(properties, CFSTR(kIOHIDLocationIDKey),
                          static_cast<std::int32_t>(0x360000 + impl_->slot));
    dictionary_set_string(properties, CFSTR(kIOHIDManufacturerKey), manufacturer);
    dictionary_set_string(properties, CFSTR(kIOHIDProductKey), product_name);
    dictionary_set_string(properties, CFSTR(kIOHIDSerialNumberKey),
                          "X360BRIDGE-" + std::to_string(impl_->slot + 1));
    dictionary_set_string(properties, CFSTR(kIOHIDTransportKey), "USB");

    impl_->device = api.create_with_properties(
        kCFAllocatorDefault, properties, 0);
    CFRelease(properties);
    if (!impl_->device) {
        if (error) {
            *error = "IOHIDUserDevice creation failed. Grant X360 Controller "
                     "Bridge in System Settings > Privacy & Security > "
                     "Accessibility, then relaunch. If Accessibility is already "
                     "enabled, the build likely still needs Apple's managed "
                     "com.apple.developer.hid.virtual.device entitlement for "
                     "the signing team; SIP/AMFI-disabled development Macs can "
                     "use this user-space path for local testing.";
        }
        return false;
    }

    const std::string queue_name = "org.x360receiverbridge.hid.slot." +
                                   std::to_string(impl_->slot + 1);
    impl_->queue = dispatch_queue_create(queue_name.c_str(),
                                         DISPATCH_QUEUE_SERIAL);
    if (!impl_->queue) {
        CFRelease(impl_->device);
        impl_->device = nullptr;
        if (error) *error = "could not create HID dispatch queue";
        return false;
    }
    impl_->cancelled = dispatch_semaphore_create(0);
    if (!impl_->cancelled) {
        CFRelease(impl_->device);
        impl_->device = nullptr;
        impl_->queue = nullptr;
        if (error) *error = "could not create HID cancellation semaphore";
        return false;
    }

    // The dispatch lifecycle contract requires the cancellation handler to be
    // installed before activation. The handler owns the Create-rule reference
    // and releases it only after pending callbacks have drained.
    IOHIDUserDeviceRef device = impl_->device;
    dispatch_semaphore_t cancelled = impl_->cancelled;
    api.set_dispatch_queue(device, impl_->queue);
    api.set_cancel_handler(device, ^{
        CFRelease(device);
        dispatch_semaphore_signal(cancelled);
    });
    api.activate(device);

    State neutral;
    if (!submit(neutral, error)) {
        destroy();
        return false;
    }
    return true;
}

bool VirtualGamepad::submit(const State& state, std::string* error) {
    if (!impl_->device) {
        if (error) *error = "virtual gamepad is not created";
        return false;
    }
    const auto& api = hid_user_device_api();
    if (!api.available()) {
        if (error) *error = "the macOS IOHIDUserDevice API is unavailable";
        return false;
    }
    auto report = make_hid_input_report(state, impl_->options.hid);
    const IOReturn result = api.handle_report_with_timestamp(
        impl_->device, mach_absolute_time(), report.data(),
        static_cast<CFIndex>(report.size()));
    if (result != kIOReturnSuccess) {
        if (error) *error = "failed to submit HID report: " + io_error(result);
        return false;
    }
    return true;
}

bool VirtualGamepad::is_created() const { return impl_->device != nullptr; }

void VirtualGamepad::destroy() {
    if (!impl_->device) return;

    // Send neutral state before detaching to reduce the chance of a client
    // retaining a pressed button during teardown.
    State neutral;
    std::string ignored;
    submit(neutral, &ignored);

    const auto& api = hid_user_device_api();
    IOHIDUserDeviceRef device = impl_->device;
    dispatch_semaphore_t cancelled = impl_->cancelled;
    impl_->device = nullptr;
    impl_->cancelled = nullptr;

    if (api.cancel) {
        api.cancel(device);
        if (cancelled) {
            const long wait_result = dispatch_semaphore_wait(
                cancelled,
                dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            if (wait_result != 0) {
                // The registered cancellation handler retains responsibility
                // for CFRelease; releasing here would risk a use-after-free.
            }
        }
    } else {
        // This branch is only reachable if the API disappeared after a
        // successful create, which should not happen for a loaded framework.
        CFRelease(device);
    }
    impl_->queue = nullptr;
}

}  // namespace x360bridge
