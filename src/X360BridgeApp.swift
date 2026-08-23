import AppKit
import Foundation
import SwiftUI


private func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: key, comment: "")
}

@main
struct X360ControllerBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BridgeViewModel()

    init() {
        runCommandLineModeIfNeeded()
    }

    var body: some Scene {
        WindowGroup("X360 Controller Bridge", id: "main") {
            ContentView(model: model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)

        MenuBarExtra("X360 Controller Bridge", systemImage: "gamecontroller") {
            StatusMenu(model: model)
        }

        Settings {
            VStack(alignment: .leading, spacing: 10) {
                Text("X360 Controller Bridge settings are in the main window.")
                    .font(.headline)
                Text("Use the Settings pane in the sidebar for startup, compatibility, and diagnostic options.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 440)
        }
    }

    private func runCommandLineModeIfNeeded() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else { return }

        var cArguments = arguments.map { strdup($0)! }
        let result = cArguments.withUnsafeMutableBufferPointer { buffer -> Int32 in
            x360bridge_cli_entry(Int32(arguments.count), buffer.baseAddress!)
        }
        for argument in cArguments {
            free(argument)
        }
        exit(result)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
final class BridgeViewModel: ObservableObject {
    private enum Keys {
        static let diagnosticsDSUEnabled = "X360Bridge.diagnosticsDSUEnabled"
    }

    private let manager = X360BridgeManager()
    private let dsuServer = X360DiagnosticDSUServer(port: 26760)
    private var observer: NSObjectProtocol?
    private var started = false

    @Published private(set) var isScanning = false
    @Published private(set) var connectedControllerCount = 0
    @Published private(set) var controllers: [X360ControllerSnapshot] = []
    @Published private(set) var wirelessReceivers: [X360USBDeviceSnapshot] = []
    @Published private(set) var wiredControllers: [X360USBDeviceSnapshot] = []
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var lastDiagnostic = "No events recorded yet."
    @Published private(set) var permissionStatus = "Unknown"
    @Published private(set) var permissionSymbolName = "circle"
    @Published private(set) var permissionNeedsUserAction = false
    @Published private(set) var virtualHIDDevices: [String] = []
    @Published private(set) var runtimeEnvironment = DeveloperLabEnvironment.snapshot()
    @Published private(set) var diagnosticsDSURunning = false
    @Published private(set) var diagnosticsDSUClientCount = 0
    @Published private(set) var diagnosticsDSUError: String?
    @Published var diagnosticsDSUEnabled = UserDefaults.standard.bool(forKey: Keys.diagnosticsDSUEnabled) {
        didSet {
            UserDefaults.standard.set(diagnosticsDSUEnabled, forKey: Keys.diagnosticsDSUEnabled)
            configureDiagnosticDSU()
        }
    }

    init() {
        sync()
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("X360BridgeManagerDidChangeNotification"),
            object: manager,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        dsuServer.onRumble = { [weak self] command in
            Task { @MainActor in
                self?.setRumble(tag: command.tag, intensity: command.intensity)
            }
        }
        dsuServer.onStateChanged = { [weak self] isRunning, clientCount, error in
            Task { @MainActor in
                self?.diagnosticsDSURunning = isRunning
                self?.diagnosticsDSUClientCount = clientCount
                self?.diagnosticsDSUError = error
            }
        }
        configureDiagnosticDSU()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        manager.stop()
        dsuServer.stop()
    }

    func start() {
        guard !started else { return }
        started = true
        manager.start()
        refreshRuntimeEnvironment()
        sync()
    }

    func sync() {
        isScanning = manager.isScanning
        connectedControllerCount = manager.connectedControllerCount
        controllers = manager.controllers
        wirelessReceivers = manager.wirelessReceivers
        wiredControllers = manager.wiredControllers
        diagnostics = manager.diagnostics
        lastDiagnostic = manager.lastDiagnostic
        permissionStatus = manager.permissionStatus
        permissionSymbolName = manager.permissionSymbolName
        permissionNeedsUserAction = manager.permissionNeedsUserAction
        virtualHIDDevices = manager.virtualHIDDevices
        dsuServer.updateControllers(dsuSnapshots(from: controllers))
    }

    var scanAtLaunch: Bool { manager.scanAtLaunch }
    var keepRunningInMenuBar: Bool { manager.keepRunningInMenuBar }
    var compatibilityMode: Bool { manager.compatibilityMode }
    var allowProtocolMatchedDevices: Bool { manager.allowProtocolMatchedDevices }
    var rawUSBPacketLogging: Bool { manager.rawUSBPacketLogging }

    func setScanAtLaunch(_ value: Bool) { manager.scanAtLaunch = value; sync() }
    func setKeepRunningInMenuBar(_ value: Bool) { manager.keepRunningInMenuBar = value; sync() }
    func setCompatibilityMode(_ value: Bool) { manager.compatibilityMode = value; sync() }
    func setAllowProtocolMatchedDevices(_ value: Bool) { manager.allowProtocolMatchedDevices = value; sync() }
    func setRawUSBPacketLogging(_ value: Bool) { manager.rawUSBPacketLogging = value; sync() }

    func startScanning() { manager.startScanning(); sync() }
    func stopScanning() { manager.stopScanning(); sync() }
    func toggleScanning() { isScanning ? stopScanning() : startScanning() }
    func testRumble(tag: Int) { manager.testRumbleForController(withTag: tag) }
    func setRumble(tag: Int, intensity: UInt8) { manager.setRumbleForController(withTag: tag, intensity: intensity) }
    func disconnect(tag: Int) { manager.disconnectController(withTag: tag) }
    func powerOff(tag: Int) { manager.powerOffController(withTag: tag) }
    func batteryHandshake(tag: Int, variant: Int) { manager.runBatteryHandshakeForController(withTag: tag, variant: variant) }
    func send0165Init(tag: Int) { manager.send0165InitForController(withTag: tag) }
    func openAccessibilityPrivacy() { manager.openAccessibilityPrivacy() }
    func checkPermissions() { manager.checkPermissions(); refreshRuntimeEnvironment(); sync() }
    func copyDiagnostics() { manager.copyDiagnostics(); sync() }
    func clearDiagnostics() { manager.clearDiagnostics(); sync() }

    var hidProfile: Int { manager.hidProfile }
    func setHidProfile(_ value: Int) { manager.hidProfile = value; sync() }
    func refreshVirtualHIDDevices() { manager.refreshVirtualHIDDevices(); sync() }

    func refreshRuntimeEnvironment() {
        runtimeEnvironment = DeveloperLabEnvironment.snapshot()
    }

    var diagnosticsDSUStatusText: String {
        if let diagnosticsDSUError, !diagnosticsDSUError.isEmpty { return diagnosticsDSUError }
        guard diagnosticsDSUEnabled else { return "Off" }
        guard diagnosticsDSURunning else { return "Starting" }
        return "127.0.0.1:26760 - \(diagnosticsDSUClientCount) client\(diagnosticsDSUClientCount == 1 ? "" : "s")"
    }

    private func configureDiagnosticDSU() {
        if diagnosticsDSUEnabled {
            dsuServer.start()
            dsuServer.updateControllers(dsuSnapshots(from: controllers))
        } else {
            dsuServer.stop()
        }
    }

    private func dsuSnapshots(from controllers: [X360ControllerSnapshot]) -> [X360DSUControllerSnapshot] {
        controllers.prefix(4).enumerated().map { index, controller in
            X360DSUControllerSnapshot(
                slot: index,
                tag: controller.tag,
                wired: controller.wired,
                buttonsMask: controller.buttonsMask,
                dpadUp: controller.dpadUp,
                dpadDown: controller.dpadDown,
                dpadLeft: controller.dpadLeft,
                dpadRight: controller.dpadRight,
                leftTrigger: controller.leftTrigger,
                rightTrigger: controller.rightTrigger,
                leftX: controller.leftX,
                leftY: controller.leftY,
                rightX: controller.rightX,
                rightY: controller.rightY
            )
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: BridgeViewModel
    @State private var selectedSection: SettingsSection? = .controllers

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
        }
        .frame(minWidth: 860, minHeight: 660)
    }

    private var sidebar: some View {
        List(SettingsSection.allCases, selection: $selectedSection) { section in
            NavigationLink(value: section) {
                Label(L(section.title), systemImage: section.systemImage)
            }
        }
        .navigationTitle("X360 Bridge")
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedSection ?? .controllers {
        case .controllers:
            controllersPage
        case .usb:
            usbPage
        case .output:
            outputPage
        case .settings:
            settingsPageContent
        case .diagnostics:
            diagnosticsPage
        }
    }

    private var controllersPage: some View {
        settingsPage(title: "Game Controllers", subtitle: controllerSubtitle) {
            if model.controllers.isEmpty {
                emptyControllerSection
            } else {
                ForEach(model.controllers, id: \.identifier) { controller in
                    connectedControllerSection(controller)
                }
            }

            settingsSection("Connection") {
                settingsRow(title: "Discovery", detail: discoveryDetail) {
                    HStack(spacing: 8) {
                        if model.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        scanToggleButton
                    }
                }
            }
        }
    }

    private var usbPage: some View {
        settingsPage(title: "Devices", subtitle: "Receiver and wired-controller discovery.") {
            settingsSection("Connection") {
                settingsRow(title: "Discovery", detail: discoveryDetail) {
                    HStack(spacing: 8) {
                        if model.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        scanToggleButton
                    }
                }
                rowDivider()
                instructionRow(
                    title: "Wireless pairing",
                    message: "Plug in the Xbox 360 wireless receiver, turn on Scan, press the receiver sync button, then press the controller sync button."
                )
                rowDivider()
                instructionRow(
                    title: "Wired controller",
                    message: "Plug in an official wired Xbox 360 USB controller, then turn on Scan. Third-party protocol matches require compatibility mode."
                )
            }

            settingsSection("Wireless Receiver") {
                if model.wirelessReceivers.isEmpty {
                    emptyRow(
                        title: model.isScanning ? "No receiver found yet" : "No receiver connected",
                        message: model.isScanning ? "The bridge is watching for Xbox 360 receiver interfaces." : "Connect a receiver and turn on Scan."
                    )
                } else {
                    ForEach(model.wirelessReceivers, id: \.identifier) { receiver in
                        usbDeviceRow(receiver)
                        if receiver.identifier != model.wirelessReceivers.last?.identifier {
                            rowDivider()
                        }
                    }
                }
            }

            settingsSection("Wired USB Controller") {
                if model.wiredControllers.isEmpty {
                    emptyRow(
                        title: model.isScanning ? "No wired controller found yet" : "No wired controller connected",
                        message: model.isScanning ? "The bridge is watching for official wired Xbox 360 USB controllers." : "Connect a wired controller and turn on Scan."
                    )
                } else {
                    ForEach(model.wiredControllers, id: \.identifier) { controller in
                        usbDeviceRow(controller)
                        if controller.identifier != model.wiredControllers.last?.identifier {
                            rowDivider()
                        }
                    }
                }
            }
        }
    }

    private var outputPage: some View {
        settingsPage(title: "Output", subtitle: "Virtual HID publication and macOS privacy status.") {
            settingsSection("macOS Virtual Controller") {
                environmentRow(
                    title: "Accessibility",
                    value: model.permissionStatus
                )
                rowDivider()
                settingsRow(title: "Privacy", detail: "Open System Settings only when you choose to, then return here and check again.") {
                    HStack(spacing: 8) {
                        Button("Open") { model.openAccessibilityPrivacy() }
                        Button("Check Again") { model.checkPermissions() }
                    }
                }
                rowDivider()
                environmentRow(
                    title: "Entitlement Boundary",
                    value: "Public distribution still requires Apple approval for com.apple.developer.hid.virtual.device. The app reports host-policy failures instead of pretending to bypass them."
                )
            }

            settingsSection("HID Profile") {
                settingsRow(title: "Profile", detail: "Switch without rebuilding. Reconnect or restart scanning after changing the profile.") {
                    Picker("", selection: Binding(get: { model.hidProfile }, set: { model.setHidProfile($0) })) {
                        Text("Generic Joystick (1209:0360)").tag(0)
                        Text("Xbox 360 Controller (045E:028E)").tag(1)
                        Text("Xbox Series X Controller (045E:0B12)").tag(2)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                rowDivider()
                instructionRow(
                    title: "Current test",
                    message: model.hidProfile == 1
                        ? "The virtual HID advertises Microsoft Xbox 360 Controller identity 045E:028E with Game Pad usage."
                        : (model.hidProfile == 2
                            ? "The virtual HID advertises Microsoft Xbox Series X Controller identity 045E:0B12 with Game Pad usage. The proven bridge input report layout is retained for compatibility testing."
                            : "The virtual HID uses the original generic Joystick identity 1209:0360.")
                )
            }

            settingsSection("User-Space HID Runtime") {
                environmentRow(
                    title: "Publisher",
                    value: "IOHIDUserDevice user-space virtual HID backend."
                )
                rowDivider()
                environmentRow(
                    title: "Virtual HID Entitlement",
                    value: model.runtimeEnvironment.entitlementSummary
                )
                rowDivider()
                environmentRow(
                    title: "Signing",
                    value: model.runtimeEnvironment.signingSummary
                )
                rowDivider()
                environmentRow(
                    title: "System Integrity Protection",
                    value: model.runtimeEnvironment.sipSummary
                )
                rowDivider()
                environmentRow(
                    title: "AMFI Hint",
                    value: model.runtimeEnvironment.amfiSummary
                )
            }

            settingsSection("Controller Output") {
                if model.controllers.isEmpty {
                    emptyRow(
                        title: "No published controllers",
                        message: "Connect a controller to create virtual output."
                    )
                } else {
                    ForEach(model.controllers, id: \.identifier) { controller in
                        environmentRow(
                            title: controller.title,
                            value: controller.outputFailed ? controller.outputError : controller.virtualOutput
                        )
                        if controller.identifier != model.controllers.last?.identifier {
                            rowDivider()
                        }
                    }
                }
            }

            settingsSection("IOHID Inspector") {
                settingsRow(title: "Refresh", detail: "Enumerate currently published X360 virtual HID devices in the IOHID registry.") {
                    Button("Refresh") { model.refreshVirtualHIDDevices() }
                }
                if model.virtualHIDDevices.isEmpty {
                    rowDivider()
                    emptyRow(title: "No X360 virtual HID device found", message: "Create a controller first, then refresh. If it still does not appear, the failure is below IOHIDUserDevice publication or due to host policy.")
                } else {
                    ForEach(model.virtualHIDDevices, id: \.self) { device in
                        rowDivider()
                        environmentRow(title: "IOHID device", value: device)
                    }
                }
            }

            settingsSection("Validation") {
                instructionRow(
                    title: "Recognition order",
                    message: "Validate virtual-device creation first, then IORegistry or raw HID visibility, then SDL or browser Gamepad API, and finally the target game. The System Settings Game Controllers pane is not a definitive pass or fail signal."
                )
            }
        }
    }

    private var settingsPageContent: some View {
        settingsPage(title: "Settings", subtitle: "Startup and development options.") {
            settingsSection("Startup") {
                settingsRow(title: "Scan when app opens", detail: "Automatically look for receivers and controllers after launch.") {
                    Toggle("", isOn: Binding(get: { model.scanAtLaunch }, set: { model.setScanAtLaunch($0) }))
                        .labelsHidden()
                }
                rowDivider()
                settingsRow(title: "Keep running in menu bar", detail: "Closing the main window keeps the bridge available from the menu bar.") {
                    Toggle("", isOn: Binding(get: { model.keepRunningInMenuBar }, set: { model.setKeepRunningInMenuBar($0) }))
                        .labelsHidden()
                }
            }

            settingsSection("Development") {
                settingsRow(title: "Compatibility mode", detail: "For local SIP/AMFI-disabled development machines only.") {
                    Toggle("", isOn: Binding(get: { model.compatibilityMode }, set: { model.setCompatibilityMode($0) }))
                        .labelsHidden()
                }
                rowDivider()
                settingsRow(title: "Allow protocol-matched USB devices", detail: "Try compatible third-party receivers or wired controllers after descriptor validation.") {
                    Toggle("", isOn: Binding(get: { model.allowProtocolMatchedDevices }, set: { model.setAllowProtocolMatchedDevices($0) }))
                        .labelsHidden()
                }
                rowDivider()
                settingsRow(title: "Raw USB packet logging", detail: "Adds backend packet logs for diagnostics.") {
                    Toggle("", isOn: Binding(get: { model.rawUSBPacketLogging }, set: { model.setRawUSBPacketLogging($0) }))
                        .labelsHidden()
                }
            }

            if model.permissionNeedsUserAction {
                settingsSection("Privacy") {
                    environmentRow(
                        title: "Accessibility",
                        value: model.permissionStatus
                    )
                    rowDivider()
                    settingsRow(title: "Controller Output", detail: "Allow X360 Controller Bridge in Privacy & Security > Accessibility if macOS requires it.") {
                        HStack(spacing: 8) {
                            Button("Open") { model.openAccessibilityPrivacy() }
                            Button("Check Again") { model.checkPermissions() }
                        }
                    }
                }
            }
        }
    }

    private var diagnosticsPage: some View {
        settingsPage(title: "Diagnostics", subtitle: "Recent receiver, controller, and virtual-output events.") {
            settingsSection("DSU / Cemuhook") {
                settingsRow(title: "Controller UDP Stream", detail: "Publishes controller input on localhost for Dolphin, Cemu-compatible clients, and other DSU consumers.") {
                    Toggle("", isOn: $model.diagnosticsDSUEnabled)
                        .labelsHidden()
                }
                rowDivider()
                controllerMetricRow("Endpoint", model.diagnosticsDSUStatusText)
                rowDivider()
                instructionRow(
                    title: "Client Setup",
                    message: "Configure DSU clients to use UDP 127.0.0.1:26760. Rumble requests are forwarded to the matching bridged controller."
                )
            }

            settingsSection("Status") {
                settingsRow(title: "Bridge Services", detail: model.isScanning ? "Scanning and USB callbacks are active." : "Scanning is stopped.") {
                    Text(model.isScanning ? "Running" : "Stopped")
                        .foregroundStyle(.secondary)
                }
                rowDivider()
                settingsRow(title: "Last Event", detail: model.lastDiagnostic) {
                    HStack(spacing: 8) {
                        Button("Copy") { model.copyDiagnostics() }
                        Button("Clear") { model.clearDiagnostics() }
                    }
                }
            }

            settingsSection("Log") {
                if model.diagnostics.isEmpty {
                    emptyRow(
                        title: "No log entries",
                        message: "Start scanning to record receiver, wired-controller, and virtual-output events."
                    )
                } else {
                    diagnosticLog
                }
            }
        }
    }

    private var emptyControllerSection: some View {
        settingsSection {
            HStack(spacing: 22) {
                ControllerArtwork(active: false)
                    .frame(width: 160, height: 118)
                    .padding(.leading, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("No Game Controllers")
                        .font(.title3.weight(.semibold))
                    Text(model.isScanning ? "Searching for an Xbox 360 wireless receiver, synced wireless controller, or official wired USB controller." : "Turn on Scan, then sync a wireless controller with the receiver or plug in an official wired Xbox 360 USB controller.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    scanToggleButton
                        .padding(.top, 4)
                }
                Spacer()
            }
            .padding(16)
        }
    }

    private func connectedControllerSection(_ controller: X360ControllerSnapshot) -> some View {
        settingsSection(controller.title) {
            HStack(alignment: .center, spacing: 22) {
                ControllerArtwork(active: true)
                    .frame(width: 180, height: 130)
                    .padding(.leading, 4)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(controller.wired ? "Wired Controller" : "Wireless Controller")
                                .font(.title3.weight(.semibold))
                            Text(controller.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        outputBadge(controller)
                    }

                    HStack(spacing: 8) {
                        Button("Test Rumble") { model.testRumble(tag: controller.tag) }
                        if !controller.wired {
                            Menu("Handshake Lab") {
                                Button("Re-send 0.16.5 sequence") {
                                    model.send0165Init(tag: controller.tag)
                                }
                                Divider()
                                Button("A: Presence → LED") {
                                    model.batteryHandshake(tag: controller.tag, variant: 1)
                                }
                                Button("B: LED → Presence") {
                                    model.batteryHandshake(tag: controller.tag, variant: 2)
                                }
                                Button("C: Presence → LED → Presence") {
                                    model.batteryHandshake(tag: controller.tag, variant: 3)
                                }
                            }
                            Button("Power Off") { model.powerOff(tag: controller.tag) }
                        }
                        Button("Disconnect") { model.disconnect(tag: controller.tag) }
                    }
                }
            }
            .padding(16)

            rowDivider()
            controllerMetricRow("Buttons", controller.buttons)
            rowDivider()
            controllerMetricRow("Directional Pad", controller.dpad)
            rowDivider()
            controllerMetricRow("Left Stick", controller.leftStick)
            rowDivider()
            controllerMetricRow("Right Stick", controller.rightStick)
            rowDivider()
            controllerMetricRow("Triggers", controller.triggers)
            rowDivider()
            controllerMetricRow("Battery", controller.batteryStatus)
            rowDivider()
            controllerMetricRow("Virtual Output", controller.outputFailed ? controller.outputError : controller.virtualOutput)
        }
    }

    private func usbDeviceRow(_ device: X360USBDeviceSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.title)
                    .font(.body.weight(.medium))
                Text(device.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text(device.status)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var diagnosticLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.diagnostics.suffix(120).enumerated()), id: \.offset) { index, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption.monospaced())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260, maxHeight: 380)
            .onReceive(model.$diagnostics) { diagnostics in
                guard !diagnostics.isEmpty else { return }
                proxy.scrollTo(min(diagnostics.count - 1, 119), anchor: .bottom)
            }
        }
    }

    private func settingsPage<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(title))
                        .font(.largeTitle.weight(.semibold))
                    Text(L(subtitle))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .background(.background)
    }

    private func settingsSection<Content: View>(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(L(title))
                    .font(.headline)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
            }
        }
    }

    private func settingsRow<Trailing: View>(
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title))
                Text(L(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 20)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func controllerMetricRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L(title))
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func environmentRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func instructionRow(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title))
                Text(L(message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func emptyRow(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title))
                Text(L(message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func rowDivider() -> some View {
        Divider()
            .padding(.leading, 12)
    }

    @ViewBuilder
    private var scanToggleButton: some View {
        if model.isScanning {
            Button("Stop Scanning") { model.stopScanning() }
        } else {
            Button("Scan") { model.startScanning() }
        }
    }

    private var statusBadge: some View {
        Text(statusBadgeText)
            .font(.callout)
            .foregroundStyle(statusColor)
    }

    private func outputBadge(_ controller: X360ControllerSnapshot) -> some View {
        Text(L(controller.outputFailed ? "Needs Attention" : (controller.outputReady ? "Output Ready" : "Connected")))
        .font(.callout)
        .foregroundStyle(controller.outputFailed ? .orange : (controller.outputReady ? .green : .secondary))
    }

    private var controllerSubtitle: String {
        if model.controllers.isEmpty {
            return L(model.isScanning ? "Searching for Xbox 360 controllers." : "No connected controller.")
        }
        return L("Monitor and identify bridged Xbox 360 controllers.")
    }

    private var discoveryDetail: String {
        model.isScanning ? L("Listening for Xbox 360 wireless receivers and wired USB controllers.") : L("Ready to scan.")
    }

    private var statusBadgeText: String {
        if model.connectedControllerCount > 0 {
            return String(format: L("%d Connected"), model.connectedControllerCount)
        }
        return model.isScanning ? L("Scanning") : L("Ready")
    }

    private var statusColor: Color {
        if model.connectedControllerCount > 0 { return .green }
        return model.isScanning ? .blue : .secondary
    }

}

struct StatusMenu: View {
    @ObservedObject var model: BridgeViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.connectedControllerCount == 0
             ? L("No controllers connected")
             : String(format: L(model.connectedControllerCount == 1 ? "%d controller connected" : "%d controllers connected"),
                      model.connectedControllerCount))

        Divider()

        Button("Show X360 Controller Bridge") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button(model.isScanning ? "Stop Scanning" : "Scan") {
            model.toggleScanning()
        }

        Divider()

        if !model.controllers.isEmpty {
            Menu("Controllers") {
                ForEach(model.controllers, id: \.identifier) { controller in
                    Text(controller.title)
                    Text(controller.detail)
                    Text(String(format: L("Battery: %@"), controller.batteryStatus))
                    Button("Identify") { model.testRumble(tag: controller.tag) }
                    Button("Disconnect") { model.disconnect(tag: controller.tag) }
                    if controller.identifier != model.controllers.last?.identifier {
                        Divider()
                    }
                }
            }

            Divider()
        }

        Menu("Diagnostics") {
            Text(model.diagnosticsDSUStatusText)
            Button("Copy Log") { model.copyDiagnostics() }
            Button("Clear Log") { model.clearDiagnostics() }
        }

        Button("Open Accessibility Settings") {
            model.openAccessibilityPrivacy()
        }

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case controllers
    case usb
    case output
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controllers: return "Game Controllers"
        case .usb: return "Devices"
        case .output: return "Output"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .controllers: return "gamecontroller"
        case .usb: return "cable.connector"
        case .output: return "display.and.arrow.down"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}

private struct ControllerArtwork: View {
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            let outline = active ? Color.primary : Color.secondary

            ZStack {
                Xbox360ControllerOutlineShape()
                    .stroke(
                        outline.opacity(active ? 0.82 : 0.52),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                    )
                    .padding(min(geometry.size.width, geometry.size.height) * 0.06)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct Xbox360ControllerOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: CGPoint(x: rect.minX + w * 0.23, y: rect.minY + h * 0.20))
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.77, y: rect.minY + h * 0.20),
            control1: CGPoint(x: rect.minX + w * 0.36, y: rect.minY + h * 0.07),
            control2: CGPoint(x: rect.minX + w * 0.64, y: rect.minY + h * 0.07)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.94, y: rect.minY + h * 0.55),
            control1: CGPoint(x: rect.minX + w * 0.88, y: rect.minY + h * 0.22),
            control2: CGPoint(x: rect.minX + w * 0.94, y: rect.minY + h * 0.37)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.86, y: rect.minY + h * 0.91),
            control1: CGPoint(x: rect.minX + w * 0.96, y: rect.minY + h * 0.78),
            control2: CGPoint(x: rect.minX + w * 0.94, y: rect.minY + h * 0.90)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.68, y: rect.minY + h * 0.74),
            control1: CGPoint(x: rect.minX + w * 0.78, y: rect.minY + h * 0.93),
            control2: CGPoint(x: rect.minX + w * 0.75, y: rect.minY + h * 0.78)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.32, y: rect.minY + h * 0.74),
            control1: CGPoint(x: rect.minX + w * 0.58, y: rect.minY + h * 0.68),
            control2: CGPoint(x: rect.minX + w * 0.42, y: rect.minY + h * 0.68)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.14, y: rect.minY + h * 0.91),
            control1: CGPoint(x: rect.minX + w * 0.25, y: rect.minY + h * 0.78),
            control2: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * 0.93)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.06, y: rect.minY + h * 0.55),
            control1: CGPoint(x: rect.minX + w * 0.06, y: rect.minY + h * 0.90),
            control2: CGPoint(x: rect.minX + w * 0.04, y: rect.minY + h * 0.78)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.23, y: rect.minY + h * 0.20),
            control1: CGPoint(x: rect.minX + w * 0.06, y: rect.minY + h * 0.37),
            control2: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.22)
        )
        path.closeSubpath()
        return path
    }
}
