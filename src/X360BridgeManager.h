#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const X360BridgeManagerDidChangeNotification;

@interface X360ControllerSnapshot : NSObject
@property(nonatomic, copy) NSString* identifier;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* detail;
@property(nonatomic, copy) NSString* buttons;
@property(nonatomic, copy) NSString* dpad;
@property(nonatomic, copy) NSString* leftStick;
@property(nonatomic, copy) NSString* rightStick;
@property(nonatomic, copy) NSString* triggers;
@property(nonatomic, copy) NSString* virtualOutput;
@property(nonatomic, copy) NSString* outputError;
@property(nonatomic) NSInteger tag;
@property(nonatomic) uint16_t buttonsMask;
@property(nonatomic) uint8_t leftTrigger;
@property(nonatomic) uint8_t rightTrigger;
@property(nonatomic) int16_t leftX;
@property(nonatomic) int16_t leftY;
@property(nonatomic) int16_t rightX;
@property(nonatomic) int16_t rightY;
@property(nonatomic) BOOL wired;
@property(nonatomic) BOOL connected;
@property(nonatomic) BOOL hasState;
@property(nonatomic) BOOL headsetPresent;
@property(nonatomic) BOOL dpadUp;
@property(nonatomic) BOOL dpadDown;
@property(nonatomic) BOOL dpadLeft;
@property(nonatomic) BOOL dpadRight;
@property(nonatomic) BOOL outputReady;
@property(nonatomic) BOOL outputFailed;
@end

@interface X360USBDeviceSnapshot : NSObject
@property(nonatomic, copy) NSString* identifier;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* detail;
@property(nonatomic, copy) NSString* status;
@property(nonatomic) BOOL wired;
@property(nonatomic) BOOL connected;
@end

@interface X360BridgeManager : NSObject
@property(nonatomic, readonly, getter=isScanning) BOOL scanning;
@property(nonatomic, readonly) NSInteger connectedControllerCount;
@property(nonatomic, readonly, copy) NSArray<X360ControllerSnapshot*>* controllers;
@property(nonatomic, readonly, copy) NSArray<X360USBDeviceSnapshot*>* wirelessReceivers;
@property(nonatomic, readonly, copy) NSArray<X360USBDeviceSnapshot*>* wiredControllers;
@property(nonatomic, readonly, copy) NSArray<NSString*>* diagnostics;
@property(nonatomic, readonly, copy) NSString* lastDiagnostic;
@property(nonatomic, readonly, copy) NSString* permissionStatus;
@property(nonatomic, readonly, copy) NSString* permissionSymbolName;
@property(nonatomic, readonly) BOOL permissionNeedsUserAction;

@property(nonatomic) BOOL scanAtLaunch;
@property(nonatomic) BOOL keepRunningInMenuBar;
@property(nonatomic) BOOL compatibilityMode;
@property(nonatomic) BOOL allowProtocolMatchedDevices;
@property(nonatomic) BOOL rawUSBPacketLogging;

- (void)start;
- (void)stop;
- (void)startScanning;
- (void)stopScanning;
- (void)testRumbleForControllerWithTag:(NSInteger)tag;
- (void)setRumbleForControllerWithTag:(NSInteger)tag intensity:(uint8_t)intensity NS_SWIFT_NAME(setRumbleForController(withTag:intensity:));
- (void)disconnectControllerWithTag:(NSInteger)tag;
- (void)openAccessibilityPrivacy;
- (void)checkPermissions;
- (void)copyDiagnostics;
- (void)clearDiagnostics;
@end

#ifdef __cplusplus
extern "C" {
#endif
int x360bridge_cli_entry(int argc, char* _Nonnull * _Nonnull argv);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
