#include "x360bridge/virtual_gamepad.hpp"

#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDKeys.h>
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

}  // namespace

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

    dictionary_set_number(properties, CFSTR(kIOHIDVendorIDKey),
                          impl_->options.vendor_id);
    dictionary_set_number(properties, CFSTR(kIOHIDProductIDKey),
                          impl_->options.product_id);
    dictionary_set_number(properties, CFSTR(kIOHIDVersionNumberKey), 0x0100);
    dictionary_set_number(properties, CFSTR(kIOHIDPrimaryUsagePageKey), 0x01);
    dictionary_set_number(properties, CFSTR(kIOHIDPrimaryUsageKey),
                          impl_->options.hid.joystick_usage ? 0x04 : 0x05);
    dictionary_set_number(properties, CFSTR(kIOHIDLocationIDKey),
                          static_cast<std::int32_t>(0x360000 + impl_->slot));
    dictionary_set_string(properties, CFSTR(kIOHIDManufacturerKey),
                          impl_->options.manufacturer);
    dictionary_set_string(properties, CFSTR(kIOHIDProductKey),
                          impl_->options.product + " " +
                          std::to_string(impl_->slot + 1));
    dictionary_set_string(properties, CFSTR(kIOHIDSerialNumberKey),
                          "X360BRIDGE-" + std::to_string(impl_->slot + 1));
    dictionary_set_string(properties, CFSTR(kIOHIDTransportKey), "USB");

    impl_->device = api.create_with_properties(
        kCFAllocatorDefault, properties, 0);
    CFRelease(properties);
    if (!impl_->device) {
        if (error) {
            *error = "IOHIDUserDevice creation failed. On current macOS this "
                     "normally means the signed executable lacks the managed "
                     "com.apple.developer.hid.virtual.device entitlement.";
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
