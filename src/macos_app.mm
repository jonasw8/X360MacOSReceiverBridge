#include "x360bridge/receiver.hpp"
#include "x360bridge/virtual_gamepad.hpp"
#include "x360bridge/wired_controller.hpp"

#import "X360BridgeManager.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

extern int x360bridge_cli_main(int argc, char** argv);

using namespace x360bridge;

NSString* const X360BridgeManagerDidChangeNotification = @"X360BridgeManagerDidChangeNotification";

namespace {

NSString* const kScanAtLaunchKey = @"X360Bridge.scanAtLaunch";
NSString* const kOpenInBackgroundKey = @"X360Bridge.openInBackground";
NSString* const kCompatibilityModeKey = @"X360Bridge.compatibilityMode";
NSString* const kAllowUnknownKey = @"X360Bridge.allowUnknownProtocolDevices";
NSString* const kDumpRawKey = @"X360Bridge.dumpRawPackets";
NSString* const kPrivacyAccessibilityPane = @"Privacy_Accessibility";

constexpr NSInteger kWiredControllerTag = 100;
constexpr std::uint8_t kWirelessTestRumbleStrong = 110;
constexpr std::uint8_t kWirelessTestRumbleWeak = 110;
constexpr std::uint8_t kWiredTestRumbleStrong = 120;
constexpr std::uint8_t kWiredTestRumbleWeak = 90;

struct WirelessSlotModel {
    bool connected = false;
    bool headset_present = false;
    bool hid_ready = false;
    bool hid_failed = false;
    std::string hid_message;
    std::optional<State> state;
};

struct WiredModel {
    bool connected = false;
    bool hid_ready = false;
    bool hid_failed = false;
    std::string hid_message;
    WiredControllerInfo info{};
    std::optional<State> state;
};

NSString* ns(const std::string& value) {
    NSString* string = [[NSString alloc] initWithBytes:value.data()
                                              length:value.size()
                                            encoding:NSUTF8StringEncoding];
    return string ? string : @"";
}

NSString* formatUSB(const UsbId& id) {
    return [NSString stringWithFormat:@"%04x:%04x", id.vendor, id.product];
}

NSString* yesNo(bool value) { return value ? @"Yes" : @"No"; }

NSString* logLine(NSString* message) {
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterNoStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    return [NSString stringWithFormat:@"%@  %@", [formatter stringFromDate:NSDate.date], message];
}

NSString* permissionStatusText() {
    switch (virtual_hid_permission_status()) {
        case VirtualHidPermissionStatus::granted:
            return @"Allowed";
        case VirtualHidPermissionStatus::denied:
            return @"Needs approval";
        case VirtualHidPermissionStatus::unknown:
            return @"Not configured";
        case VirtualHidPermissionStatus::unsupported:
            return @"Unavailable";
    }
    return @"Unknown";
}

NSString* permissionSymbolName() {
    switch (virtual_hid_permission_status()) {
        case VirtualHidPermissionStatus::granted:
            return @"checkmark.circle.fill";
        case VirtualHidPermissionStatus::denied:
            return @"hand.raised.fill";
        case VirtualHidPermissionStatus::unknown:
            return @"questionmark.circle.fill";
        case VirtualHidPermissionStatus::unsupported:
            return @"xmark.circle.fill";
    }
    return @"circle";
}

BOOL permissionNeedsUserAction() {
    VirtualHidPermissionStatus status = virtual_hid_permission_status();
    return status != VirtualHidPermissionStatus::granted &&
           status != VirtualHidPermissionStatus::unsupported;
}

void openPrivacyPane(NSString* pane) {
    NSString* urlString = [NSString stringWithFormat:@"x-apple.systempreferences:com.apple.preference.security?%@", pane];
    NSURL* url = [NSURL URLWithString:urlString];
    if (![NSWorkspace.sharedWorkspace openURL:url]) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security"]];
    }
}

NSString* receiverDescription(const ReceiverInfo& info) {
    NSMutableString* text = [NSMutableString stringWithFormat:@"%@, bus %u, address %u",
                             formatUSB(info.id),
                             static_cast<unsigned>(info.bus),
                             static_cast<unsigned>(info.address)];
    if (!info.product.empty()) [text appendFormat:@", %@", ns(info.product)];
    [text appendFormat:@", %zu slot%@", info.controller_interfaces, info.controller_interfaces == 1 ? @"" : @"s"];
    if (!info.known_id) [text appendString:@", compatibility match"];
    return text;
}

NSString* wiredDescription(const WiredControllerInfo& info) {
    NSMutableString* text = [NSMutableString stringWithFormat:@"%@, bus %u, address %u",
                             formatUSB(info.id),
                             static_cast<unsigned>(info.bus),
                             static_cast<unsigned>(info.address)];
    if (!info.product.empty()) [text appendFormat:@", %@", ns(info.product)];
    if (!info.known_id) [text appendString:@", compatibility match"];
    return text;
}

NSString* buttonSummary(const State& state) {
    NSMutableArray<NSString*>* buttons = [NSMutableArray array];
    if (state.buttons & A) [buttons addObject:@"A"];
    if (state.buttons & B) [buttons addObject:@"B"];
    if (state.buttons & X) [buttons addObject:@"X"];
    if (state.buttons & Y) [buttons addObject:@"Y"];
    if (state.buttons & LB) [buttons addObject:@"LB"];
    if (state.buttons & RB) [buttons addObject:@"RB"];
    if (state.buttons & Back) [buttons addObject:@"Back"];
    if (state.buttons & Start) [buttons addObject:@"Start"];
    if (state.buttons & L3) [buttons addObject:@"L3"];
    if (state.buttons & R3) [buttons addObject:@"R3"];
    if (state.buttons & Guide) [buttons addObject:@"Guide"];
    return buttons.count == 0 ? @"None" : [buttons componentsJoinedByString:@"  "];
}

NSString* dpadSummary(const State& state) {
    NSMutableArray<NSString*>* directions = [NSMutableArray array];
    if (state.dpad_up) [directions addObject:@"Up"];
    if (state.dpad_down) [directions addObject:@"Down"];
    if (state.dpad_left) [directions addObject:@"Left"];
    if (state.dpad_right) [directions addObject:@"Right"];
    return directions.count == 0 ? @"Centered" : [directions componentsJoinedByString:@" + "];
}

NSString* stickSummary(std::int16_t x, std::int16_t y) {
    return [NSString stringWithFormat:@"x %+d   y %+d", x, y];
}

NSString* triggerSummary(const State& state) {
    const unsigned left = static_cast<unsigned>(std::round((static_cast<double>(state.left_trigger) / 255.0) * 100.0));
    const unsigned right = static_cast<unsigned>(std::round((static_cast<double>(state.right_trigger) / 255.0) * 100.0));
    return [NSString stringWithFormat:@"LT %u%%   RT %u%%", left, right];
}

X360USBDeviceSnapshot* usbSnapshot(NSString* identifier, NSString* title, NSString* detail,
                                  NSString* status, BOOL wired, BOOL connected) {
    X360USBDeviceSnapshot* snapshot = [[X360USBDeviceSnapshot alloc] init];
    snapshot.identifier = identifier;
    snapshot.title = title;
    snapshot.detail = detail;
    snapshot.status = status;
    snapshot.wired = wired;
    snapshot.connected = connected;
    return snapshot;
}

X360ControllerSnapshot* controllerSnapshot(NSString* identifier, NSString* title, NSString* detail,
                                           NSInteger tag, BOOL wired, BOOL headset,
                                           const std::optional<State>& state,
                                           bool outputReady, bool outputFailed,
                                           const std::string& outputMessage) {
    State value = state.value_or(State{});
    X360ControllerSnapshot* snapshot = [[X360ControllerSnapshot alloc] init];
    snapshot.identifier = identifier;
    snapshot.title = title;
    snapshot.detail = detail;
    snapshot.tag = tag;
    snapshot.wired = wired;
    snapshot.connected = YES;
    snapshot.hasState = state.has_value();
    snapshot.headsetPresent = headset;
    snapshot.buttonsMask = value.buttons;
    snapshot.leftTrigger = value.left_trigger;
    snapshot.rightTrigger = value.right_trigger;
    snapshot.leftX = value.left_x;
    snapshot.leftY = value.left_y;
    snapshot.rightX = value.right_x;
    snapshot.rightY = value.right_y;
    snapshot.dpadUp = value.dpad_up;
    snapshot.dpadDown = value.dpad_down;
    snapshot.dpadLeft = value.dpad_left;
    snapshot.dpadRight = value.dpad_right;
    snapshot.outputReady = outputReady;
    snapshot.outputFailed = outputFailed;
    snapshot.outputError = outputFailed ? ns(outputMessage) : @"";
    snapshot.virtualOutput = outputFailed ? @"Needs Attention" : (outputReady ? @"Ready" : @"Waiting");
    snapshot.buttons = state.has_value() ? buttonSummary(value) : @"Waiting for input";
    snapshot.dpad = state.has_value() ? dpadSummary(value) : @"Waiting";
    snapshot.leftStick = state.has_value() ? stickSummary(value.left_x, value.left_y) : @"Waiting";
    snapshot.rightStick = state.has_value() ? stickSummary(value.right_x, value.right_y) : @"Waiting";
    snapshot.triggers = state.has_value() ? triggerSummary(value) : @"Waiting";
    return snapshot;
}

}  // namespace

@implementation X360ControllerSnapshot
@end

@implementation X360USBDeviceSnapshot
@end

@interface X360BridgeManager () {
@private
    std::mutex _mutex;
    std::unique_ptr<Receiver> _receiver;
    std::unique_ptr<WiredController> _wiredController;
    std::array<std::unique_ptr<VirtualGamepad>, 4> _wirelessPads;
    std::unique_ptr<VirtualGamepad> _wiredPad;
    std::array<WirelessSlotModel, 4> _wirelessSlots;
    WiredModel _wiredModel;
    std::vector<ReceiverInfo> _receivers;
    std::vector<WiredControllerInfo> _wiredControllers;
    std::vector<std::string> _logEntries;
    std::string _lastLog;
    NSTimer* _scanTimer;
    BOOL _started;
    BOOL _scanning;
    BOOL _refreshQueued;
}
@end

@implementation X360BridgeManager

- (instancetype)init {
    self = [super init];
    if (self) {
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            kScanAtLaunchKey: @YES,
            kOpenInBackgroundKey: @NO,
            kCompatibilityModeKey: @NO,
            kAllowUnknownKey: @NO,
            kDumpRawKey: @NO,
        }];
        _started = NO;
        _scanning = NO;
        _refreshQueued = NO;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    BOOL shouldScan = NO;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_started) return;
        _started = YES;
        shouldScan = [NSUserDefaults.standardUserDefaults boolForKey:kScanAtLaunchKey];
    }
    [self appendLog:@"App started."];
    if (shouldScan) [self startScanning];
}

- (void)stop {
    [self stopScanning];
}

- (BOOL)isScanning {
    std::lock_guard<std::mutex> lock(_mutex);
    return _scanning;
}

- (NSInteger)connectedControllerCount {
    std::lock_guard<std::mutex> lock(_mutex);
    NSInteger count = _wiredModel.connected ? 1 : 0;
    for (const auto& slot : _wirelessSlots) if (slot.connected) ++count;
    return count;
}

- (NSArray<X360ControllerSnapshot*>*)controllers {
    NSMutableArray<X360ControllerSnapshot*>* snapshots = [NSMutableArray array];
    std::lock_guard<std::mutex> lock(_mutex);
    for (std::size_t i = 0; i < _wirelessSlots.size(); ++i) {
        const WirelessSlotModel& slot = _wirelessSlots[i];
        if (!slot.connected) continue;
        [snapshots addObject:controllerSnapshot(
            [NSString stringWithFormat:@"wireless-%zu", i],
            [NSString stringWithFormat:@"Wireless Controller %zu", i + 1],
            [NSString stringWithFormat:@"Receiver slot %zu, headset %@", i + 1, yesNo(slot.headset_present)],
            static_cast<NSInteger>(i), NO, slot.headset_present, slot.state,
            slot.hid_ready, slot.hid_failed, slot.hid_message)];
    }
    if (_wiredModel.connected) {
        NSString* detail = (_wiredModel.info.id.vendor || _wiredModel.info.id.product) ?
            wiredDescription(_wiredModel.info) : @"Wired USB controller";
        [snapshots addObject:controllerSnapshot(
            @"wired", @"Wired USB Controller", detail, kWiredControllerTag, YES, NO,
            _wiredModel.state, _wiredModel.hid_ready, _wiredModel.hid_failed,
            _wiredModel.hid_message)];
    }
    return snapshots;
}

- (NSArray<X360USBDeviceSnapshot*>*)wirelessReceivers {
    NSMutableArray<X360USBDeviceSnapshot*>* snapshots = [NSMutableArray array];
    std::lock_guard<std::mutex> lock(_mutex);
    for (std::size_t i = 0; i < _receivers.size(); ++i) {
        [snapshots addObject:usbSnapshot(
            [NSString stringWithFormat:@"receiver-%zu", i],
            [NSString stringWithFormat:@"Receiver %zu", i + 1],
            receiverDescription(_receivers[i]),
            (_receiver && _receiver->is_running() && i == 0) ? @"Open" : @"Discovered",
            NO,
            (_receiver && _receiver->is_running() && i == 0))];
    }
    return snapshots;
}

- (NSArray<X360USBDeviceSnapshot*>*)wiredControllers {
    NSMutableArray<X360USBDeviceSnapshot*>* snapshots = [NSMutableArray array];
    std::lock_guard<std::mutex> lock(_mutex);
    if (_wiredModel.connected) {
        NSString* detail = (_wiredModel.info.id.vendor || _wiredModel.info.id.product) ?
            wiredDescription(_wiredModel.info) : @"Wired USB controller";
        [snapshots addObject:usbSnapshot(@"wired-open", @"Wired USB Controller", detail, @"Open", YES, YES)];
        return snapshots;
    }
    for (std::size_t i = 0; i < _wiredControllers.size(); ++i) {
        [snapshots addObject:usbSnapshot(
            [NSString stringWithFormat:@"wired-%zu", i],
            [NSString stringWithFormat:@"Controller %zu", i + 1],
            wiredDescription(_wiredControllers[i]),
            @"Discovered", YES, NO)];
    }
    return snapshots;
}

- (NSArray<NSString*>*)diagnostics {
    NSMutableArray<NSString*>* values = [NSMutableArray array];
    std::lock_guard<std::mutex> lock(_mutex);
    for (const std::string& entry : _logEntries) [values addObject:ns(entry)];
    return values;
}

- (NSString*)lastDiagnostic {
    std::lock_guard<std::mutex> lock(_mutex);
    return _lastLog.empty() ? @"No events recorded yet." : ns(_lastLog);
}

- (NSString*)permissionStatus { return permissionStatusText(); }
- (NSString*)permissionSymbolName { return permissionSymbolName(); }
- (BOOL)permissionNeedsUserAction { return permissionNeedsUserAction(); }

- (BOOL)scanAtLaunch { return [NSUserDefaults.standardUserDefaults boolForKey:kScanAtLaunchKey]; }
- (void)setScanAtLaunch:(BOOL)value { [self setDefaultBool:value key:kScanAtLaunchKey label:@"Scan when app opens"]; }
- (BOOL)keepRunningInMenuBar { return [NSUserDefaults.standardUserDefaults boolForKey:kOpenInBackgroundKey]; }
- (void)setKeepRunningInMenuBar:(BOOL)value { [self setDefaultBool:value key:kOpenInBackgroundKey label:@"Keep running in menu bar"]; }
- (BOOL)compatibilityMode { return [NSUserDefaults.standardUserDefaults boolForKey:kCompatibilityModeKey]; }
- (void)setCompatibilityMode:(BOOL)value { [self setDefaultBool:value key:kCompatibilityModeKey label:@"Compatibility mode"]; }
- (BOOL)allowProtocolMatchedDevices { return [NSUserDefaults.standardUserDefaults boolForKey:kAllowUnknownKey]; }
- (void)setAllowProtocolMatchedDevices:(BOOL)value { [self setDefaultBool:value key:kAllowUnknownKey label:@"Allow protocol-matched USB devices"]; }
- (BOOL)rawUSBPacketLogging { return [NSUserDefaults.standardUserDefaults boolForKey:kDumpRawKey]; }
- (void)setRawUSBPacketLogging:(BOOL)value { [self setDefaultBool:value key:kDumpRawKey label:@"Raw USB packet logging"]; }

- (void)setDefaultBool:(BOOL)value key:(NSString*)key label:(NSString*)label {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
    [NSUserDefaults.standardUserDefaults synchronize];
    [self appendLog:[NSString stringWithFormat:@"%@ %@.", label, value ? @"enabled" : @"disabled"]];
    [self notifyChanged];
}

- (BOOL)allowUnknownProtocolDevices {
    return [NSUserDefaults.standardUserDefaults boolForKey:kAllowUnknownKey] ||
           [NSUserDefaults.standardUserDefaults boolForKey:kCompatibilityModeKey];
}

- (BOOL)dumpRawPackets {
    return [NSUserDefaults.standardUserDefaults boolForKey:kDumpRawKey];
}

- (void)appendLog:(NSString*)message {
    if (message.length == 0) return;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        const char* utf8 = [logLine(message) UTF8String];
        _lastLog = utf8 ? utf8 : "";
        _logEntries.push_back(_lastLog);
        if (_logEntries.size() > 500) {
            _logEntries.erase(_logEntries.begin(), _logEntries.begin() + (_logEntries.size() - 500));
        }
    }
    [self notifyChanged];
}

- (void)notifyChanged {
    BOOL shouldNotify = NO;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (!_refreshQueued) {
            _refreshQueued = YES;
            shouldNotify = YES;
        }
    }
    if (!shouldNotify) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        {
            std::lock_guard<std::mutex> lock(self->_mutex);
            self->_refreshQueued = NO;
        }
        [NSNotificationCenter.defaultCenter postNotificationName:X360BridgeManagerDidChangeNotification object:self];
    });
}

- (void)startScanning {
    BOOL startTimer = NO;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (!_scanning) {
            _scanning = YES;
            startTimer = YES;
        }
    }
    if (startTimer) {
        [self appendLog:@"Scanning started."];
        _scanTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(scanTick:)
                                                    userInfo:nil
                                                     repeats:YES];
        [_scanTimer fire];
    }
    [self notifyChanged];
}

- (void)stopScanning {
    if (_scanTimer) {
        [_scanTimer invalidate];
        _scanTimer = nil;
    }

    std::unique_ptr<Receiver> oldReceiver;
    std::unique_ptr<WiredController> oldWired;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _scanning = NO;
        oldReceiver.swap(_receiver);
        oldWired.swap(_wiredController);
        for (auto& pad : _wirelessPads) pad.reset();
        _wiredPad.reset();
        for (auto& slot : _wirelessSlots) slot = WirelessSlotModel{};
        _wiredModel = WiredModel{};
    }
    if (oldReceiver) oldReceiver->stop();
    if (oldWired) oldWired->stop();
    [self appendLog:@"Scanning stopped."];
    [self notifyChanged];
}

- (void)scanTick:(NSTimer*)timer {
    (void)timer;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            [self discoverDevices];
        }
    });
}

- (void)discoverDevices {
    bool scanning = false;
    bool receiverRunning = false;
    bool wiredRunning = false;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        scanning = _scanning;
        receiverRunning = _receiver && _receiver->is_running();
        wiredRunning = _wiredController && _wiredController->is_running();
    }
    if (!scanning) return;

    std::string receiverError;
    std::string wiredError;
    std::vector<ReceiverInfo> receivers = Receiver::discover([self allowUnknownProtocolDevices], &receiverError);
    std::vector<WiredControllerInfo> wired = WiredController::discover([self allowUnknownProtocolDevices], &wiredError);
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _receivers = receivers;
        _wiredControllers = wired;
        scanning = _scanning;
    }
    if (!scanning) return;
    if (!receiverError.empty()) [self appendLog:[NSString stringWithFormat:@"Receiver scan: %@", ns(receiverError)]];
    if (!wiredError.empty()) [self appendLog:[NSString stringWithFormat:@"Wired scan: %@", ns(wiredError)]];

    if (!receiverRunning && !receivers.empty()) [self startReceiverAtIndex:0];
    if (!wiredRunning && !wired.empty()) [self startWiredAtIndex:0];
    [self notifyChanged];
}

- (void)startReceiverAtIndex:(std::size_t)index {
    std::unique_ptr<Receiver> oldReceiver;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_receiver && _receiver->is_running()) return;
        oldReceiver.swap(_receiver);
    }
    if (oldReceiver) oldReceiver->stop();

    auto receiver = std::make_unique<Receiver>();
    ReceiverOptions options;
    options.receiver_index = index;
    options.allow_unknown_protocol_match = [self allowUnknownProtocolDevices];
    options.dump_raw = [self dumpRawPackets];
    __weak X360BridgeManager* weakSelf = self;
    std::string error;
    bool opened = receiver->open(options,
        [weakSelf](const SlotEvent& event) {
            X360BridgeManager* strong = weakSelf;
            if (strong) [strong handleWirelessEvent:event];
        },
        [weakSelf](const std::string& message) {
            X360BridgeManager* strong = weakSelf;
            if (strong) [strong appendLog:ns(message)];
        }, &error);
    if (!opened) {
        [self appendLog:[NSString stringWithFormat:@"Could not open receiver: %@", ns(error)]];
        return;
    }
    if (!receiver->start(&error)) {
        [self appendLog:[NSString stringWithFormat:@"Could not start receiver: %@", ns(error)]];
        receiver->stop();
        return;
    }
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _receiver = std::move(receiver);
    }
    [self appendLog:@"Wireless receiver connected."];
    [self notifyChanged];
}

- (void)startWiredAtIndex:(std::size_t)index {
    std::unique_ptr<WiredController> oldWired;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        if (_wiredController && _wiredController->is_running()) return;
        oldWired.swap(_wiredController);
    }
    if (oldWired) oldWired->stop();

    auto wired = std::make_unique<WiredController>();
    WiredControllerOptions options;
    options.controller_index = index;
    options.allow_unknown_protocol_match = [self allowUnknownProtocolDevices];
    options.dump_raw = [self dumpRawPackets];
    __weak X360BridgeManager* weakSelf = self;
    std::string error;
    bool opened = wired->open(options,
        [weakSelf](const WiredControllerEvent& event) {
            X360BridgeManager* strong = weakSelf;
            if (strong) [strong handleWiredEvent:event];
        },
        [weakSelf](const std::string& message) {
            X360BridgeManager* strong = weakSelf;
            if (strong) [strong appendLog:ns(message)];
        }, &error);
    if (!opened) {
        [self appendLog:[NSString stringWithFormat:@"Could not open wired controller: %@", ns(error)]];
        return;
    }
    if (!wired->start(&error)) {
        [self appendLog:[NSString stringWithFormat:@"Could not start wired controller: %@", ns(error)]];
        wired->stop();
        return;
    }
    WiredControllerInfo info = wired->info();
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _wiredModel.info = info;
        _wiredController = std::move(wired);
    }
    [self appendLog:@"Wired controller connected."];
    [self notifyChanged];
}

- (void)handleWirelessEvent:(SlotEvent)event {
    if (event.slot >= _wirelessSlots.size()) return;
    std::string hidError;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        WirelessSlotModel& slot = _wirelessSlots[event.slot];
        if (event.connected.has_value()) {
            slot.connected = *event.connected;
            slot.headset_present = event.headset_present;
            if (!slot.connected) {
                slot.state.reset();
                slot.hid_ready = false;
                slot.hid_failed = false;
                slot.hid_message.clear();
                _wirelessPads[event.slot].reset();
            } else if (_receiver) {
                (void)_receiver->set_led(event.slot, static_cast<std::uint8_t>(0x06 + event.slot), nullptr);
            }
        }
        if (event.state.has_value()) {
            slot.connected = true;
            slot.state = *event.state;
            if (!_wirelessPads[event.slot]) {
                VirtualGamepadOptions options;
                options.product = "Xbox 360 Wireless Controller";
                options.manufacturer = "X360 Controller Bridge";
                _wirelessPads[event.slot] = std::make_unique<VirtualGamepad>(event.slot, options);
                if (!_wirelessPads[event.slot]->create(&hidError)) {
                    slot.hid_failed = true;
                    slot.hid_ready = false;
                    slot.hid_message = hidError;
                } else {
                    slot.hid_failed = false;
                    slot.hid_ready = true;
                    slot.hid_message = "ready";
                }
            }
            if (_wirelessPads[event.slot] && _wirelessPads[event.slot]->is_created()) {
                if (!_wirelessPads[event.slot]->submit(*event.state, &hidError)) {
                    slot.hid_failed = true;
                    slot.hid_ready = false;
                    slot.hid_message = hidError;
                }
            }
        }
    }
    [self notifyChanged];
}

- (void)handleWiredEvent:(WiredControllerEvent)event {
    std::string hidError;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _wiredModel.connected = event.connected;
        if (!event.connected) {
            _wiredModel.state.reset();
            _wiredModel.hid_ready = false;
            _wiredModel.hid_failed = false;
            _wiredModel.hid_message.clear();
            _wiredPad.reset();
        }
        if (event.state.has_value()) {
            _wiredModel.connected = true;
            _wiredModel.state = *event.state;
            if (!_wiredPad) {
                VirtualGamepadOptions options;
                options.product = "Xbox 360 Wired Controller";
                options.manufacturer = "X360 Controller Bridge";
                _wiredPad = std::make_unique<VirtualGamepad>(4, options);
                if (!_wiredPad->create(&hidError)) {
                    _wiredModel.hid_failed = true;
                    _wiredModel.hid_ready = false;
                    _wiredModel.hid_message = hidError;
                } else {
                    _wiredModel.hid_failed = false;
                    _wiredModel.hid_ready = true;
                    _wiredModel.hid_message = "ready";
                }
            }
            if (_wiredPad && _wiredPad->is_created()) {
                if (!_wiredPad->submit(*event.state, &hidError)) {
                    _wiredModel.hid_failed = true;
                    _wiredModel.hid_ready = false;
                    _wiredModel.hid_message = hidError;
                }
            }
        }
    }
    [self notifyChanged];
}

- (void)testRumbleForControllerWithTag:(NSInteger)tag {
    if (tag == kWiredControllerTag) {
        WiredController* controller = nullptr;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            controller = _wiredController.get();
        }
        if (controller) {
            controller->set_rumble(kWiredTestRumbleStrong, kWiredTestRumbleWeak, nullptr);
            __weak X360BridgeManager* weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                X360BridgeManager* strong = weakSelf;
                if (strong) [strong stopRumbleForTag:kWiredControllerTag];
            });
        }
        return;
    }
    if (tag < 0 || tag >= 4) return;
    Receiver* receiver = nullptr;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        receiver = _receiver.get();
    }
    if (receiver) {
        std::size_t slot = static_cast<std::size_t>(tag);
        receiver->set_rumble(slot, kWirelessTestRumbleStrong, kWirelessTestRumbleWeak, nullptr);
        __weak X360BridgeManager* weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            X360BridgeManager* strong = weakSelf;
            if (strong) [strong stopRumbleForTag:tag];
        });
    }
}

- (void)setRumbleForControllerWithTag:(NSInteger)tag intensity:(uint8_t)intensity {
    if (tag == kWiredControllerTag) {
        WiredController* controller = nullptr;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            controller = _wiredController.get();
        }
        if (controller) {
            controller->set_rumble(intensity, static_cast<std::uint8_t>(intensity / 2), nullptr);
        }
        return;
    }

    if (tag < 0 || tag >= 4) return;
    Receiver* receiver = nullptr;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        receiver = _receiver.get();
    }
    if (receiver) {
        receiver->set_rumble(static_cast<std::size_t>(tag), intensity,
                             static_cast<std::uint8_t>(intensity / 2), nullptr);
    }
}

- (void)stopRumbleForTag:(NSInteger)tag {
    if (tag == kWiredControllerTag) {
        WiredController* controller = nullptr;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            controller = _wiredController.get();
        }
        if (controller) controller->set_rumble(0, 0, nullptr);
        return;
    }
    if (tag < 0 || tag >= 4) return;
    Receiver* receiver = nullptr;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        receiver = _receiver.get();
    }
    if (receiver) receiver->set_rumble(static_cast<std::size_t>(tag), 0, 0, nullptr);
}

- (void)disconnectControllerWithTag:(NSInteger)tag {
    if (tag == kWiredControllerTag) {
        std::unique_ptr<WiredController> oldWired;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            oldWired.swap(_wiredController);
            _wiredPad.reset();
            _wiredModel = WiredModel{};
        }
        if (oldWired) oldWired->stop();
        [self appendLog:@"Wired controller disconnected from the bridge."];
        [self notifyChanged];
        return;
    }
    if (tag < 0 || tag >= 4) return;
    Receiver* receiver = nullptr;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        receiver = _receiver.get();
    }
    if (receiver) {
        std::string error;
        if (!receiver->power_off(static_cast<std::size_t>(tag), &error)) {
            [self appendLog:[NSString stringWithFormat:@"Disconnect failed: %@", ns(error)]];
        } else {
            [self appendLog:[NSString stringWithFormat:@"Disconnect requested for controller %ld.", static_cast<long>(tag + 1)]];
        }
    }
}

- (void)openAccessibilityPrivacy {
    openPrivacyPane(kPrivacyAccessibilityPane);
    [self appendLog:@"Opened Privacy & Security > Accessibility."];
}

- (void)checkPermissions {
    [self appendLog:[NSString stringWithFormat:@"Accessibility permission: %@", permissionStatusText()]];
    [self notifyChanged];
}

- (void)copyDiagnostics {
    NSMutableString* text = [NSMutableString string];
    {
        std::lock_guard<std::mutex> lock(_mutex);
        for (const std::string& entry : _logEntries) [text appendFormat:@"%@\n", ns(entry)];
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    [self appendLog:@"Copied diagnostics to the pasteboard."];
}

- (void)clearDiagnostics {
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _logEntries.clear();
        _lastLog.clear();
    }
    [self notifyChanged];
}

@end

extern "C" int x360bridge_cli_entry(int argc, char** argv) {
    return x360bridge_cli_main(argc, argv);
}
