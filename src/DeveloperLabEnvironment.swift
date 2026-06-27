import Darwin
import Foundation
import Security

struct DeveloperLabEnvironmentSnapshot: Sendable {
    let virtualHIDEntitlementVisible: Bool
    let bootArgumentsReadable: Bool
    let amfiRelaxationHintDetected: Bool
    let bootArguments: String?
    let teamIdentifier: String?
    let sipStatus: SIPStatus

    var entitlementSummary: String {
        virtualHIDEntitlementVisible
            ? "Restricted virtual-HID entitlement is visible to the running task."
            : "Restricted virtual-HID entitlement is not visible to the running task."
    }

    var signingSummary: String {
        if let teamIdentifier, !teamIdentifier.isEmpty {
            return "Signing team: \(teamIdentifier)."
        }
        return "No Apple team identifier is visible to the running task."
    }

    var amfiSummary: String {
        guard bootArgumentsReadable else {
            return "The app could not read kern.bootargs. Use terminal diagnostics for host-security checks."
        }
        return amfiRelaxationHintDetected
            ? "The AMFI local-lab boot-argument hint was detected."
            : "The AMFI local-lab boot-argument hint was not detected."
    }

    var sipSummary: String {
        switch sipStatus {
        case .enabled:
            return "System Integrity Protection appears enabled."
        case .disabled:
            return "System Integrity Protection appears disabled."
        case .unknown(let detail):
            return detail ?? "System Integrity Protection status could not be read."
        }
    }
}

enum SIPStatus: Sendable {
    case enabled
    case disabled
    case unknown(String?)
}

enum DeveloperLabEnvironment {
    static let virtualHIDEntitlement = "com.apple.developer.hid.virtual.device"
    private static let teamIdentifierEntitlement = "com.apple.developer.team-identifier"

    static func snapshot() -> DeveloperLabEnvironmentSnapshot {
        let bootArguments = readSysctlString("kern.bootargs")
        return DeveloperLabEnvironmentSnapshot(
            virtualHIDEntitlementVisible: hasVirtualHIDEntitlement(),
            bootArgumentsReadable: bootArguments != nil,
            amfiRelaxationHintDetected: bootArguments.map(containsAMFIRelaxation) ?? false,
            bootArguments: bootArguments,
            teamIdentifier: entitlementString(teamIdentifierEntitlement),
            sipStatus: readSIPStatus()
        )
    }

    static func hasVirtualHIDEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                virtualHIDEntitlement as CFString,
                nil
              ) else {
            return false
        }
        return (value as? Bool) == true || (value as? NSNumber)?.boolValue == true
    }

    static func containsAMFIRelaxation(_ bootArguments: String) -> Bool {
        let acceptedValues = Set(["1", "0x1", "0X1", "true", "TRUE"])
        let acceptedKeys = Set(["amfi_get_out_of_my_way", "amfi_allow_any_signature"])

        for token in bootArguments.split(whereSeparator: { $0.isWhitespace }) {
            let components = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard components.count == 2,
                  acceptedKeys.contains(components[0]),
                  acceptedValues.contains(components[1]) else {
                continue
            }
            return true
        }
        return false
    }

    private static func entitlementString(_ name: String) -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil) else {
            return nil
        }
        return value as? String
    }

    private static func readSysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: max(size, 1))
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname(name, bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }

        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
    }

    private static func readSIPStatus() -> SIPStatus {
        guard let output = runProcess("/usr/bin/csrutil", arguments: ["status"]) else {
            return .unknown("The app could not run csrutil status. Use Terminal for SIP diagnostics.")
        }

        let normalized = output.lowercased()
        if normalized.contains("system integrity protection status: enabled") {
            return .enabled
        }
        if normalized.contains("system integrity protection status: disabled") {
            return .disabled
        }
        return .unknown(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func runProcess(_ launchPath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
