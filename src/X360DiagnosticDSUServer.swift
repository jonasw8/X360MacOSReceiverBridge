import Darwin
import Foundation

struct X360DSURumbleCommand {
    let tag: Int
    let intensity: UInt8
}

struct X360DSUControllerSnapshot: Equatable {
    let slot: Int
    let tag: Int
    let wired: Bool
    let buttonsMask: UInt16
    let dpadUp: Bool
    let dpadDown: Bool
    let dpadLeft: Bool
    let dpadRight: Bool
    let leftTrigger: UInt8
    let rightTrigger: UInt8
    let leftX: Int16
    let leftY: Int16
    let rightX: Int16
    let rightY: Int16
}

final class X360DiagnosticDSUServer {
    var onRumble: ((X360DSURumbleCommand) -> Void)?
    var onStateChanged: ((_ isRunning: Bool, _ clientCount: Int, _ error: String?) -> Void)?

    private enum MessageType {
        static let protocolVersion: UInt32 = 0x100000
        static let controllerInfo: UInt32 = 0x100001
        static let controllerData: UInt32 = 0x100002
        static let motorInfo: UInt32 = 0x110001
        static let rumble: UInt32 = 0x110002
    }

    private enum Subscription: Hashable {
        case all
        case slot(Int)
        case mac([UInt8])
    }

    private struct ParsedPacket {
        let messageType: UInt32
        let payload: [UInt8]
    }

    private struct ClientKey: Hashable {
        let address: UInt32
        let port: UInt16
    }

    private struct ClientState {
        let address: sockaddr_in
        var subscriptions = Set<Subscription>()
        var packetCounter: UInt32 = 0
        var lastSeen = Date()
        var rumbleDeadlines: [Int: Date] = [:]
    }

    private let port: UInt16
    private let serverID = UInt32.random(in: 1...UInt32.max)
    private let queue = DispatchQueue(label: "org.x360receiverbridge.diagnostics.dsu")
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var clients: [ClientKey: ClientState] = [:]
    private var controllers: [Int: X360DSUControllerSnapshot] = [:]
    private var isRunning = false
    private var sendTimer: DispatchSourceTimer?

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    func updateControllers(_ snapshots: [X360DSUControllerSnapshot]) {
        queue.async { [weak self] in
            self?.controllers = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.slot, $0) })
        }
    }

    private func startOnQueue() {
        guard socketFD < 0 else {
            notifyState(error: nil)
            return
        }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            notifyState(isRunning: false, error: socketError("socket"))
            return
        }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = socketError("bind")
            Darwin.close(fd)
            notifyState(isRunning: false, error: error)
            return
        }

        socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receiveAvailableDatagrams() }
        readSource = source
        source.resume()

        isRunning = true
        notifyState(error: nil)
        startSendTimer()
    }

    private func stopOnQueue() {
        sendTimer?.cancel()
        sendTimer = nil

        readSource?.cancel()
        readSource = nil
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }

        clients.removeAll()
        isRunning = false
        notifyState(isRunning: false, error: nil)
    }

    private func receiveAvailableDatagrams() {
        guard socketFD >= 0 else { return }

        while true {
            var buffer = [UInt8](repeating: 0, count: 2048)
            var storage = sockaddr_storage()
            var storageLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &storage) { storagePointer in
                    storagePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.recvfrom(socketFD, baseAddress, rawBuffer.count, 0, sockaddrPointer, &storageLength)
                    }
                }
            }

            if count > 0 {
                handleDatagram(Array(buffer.prefix(count)), from: storage)
            } else if count == 0 {
                return
            } else {
                let errorCode = errno
                if errorCode == EWOULDBLOCK || errorCode == EAGAIN { return }
                notifyState(error: socketError("recvfrom", code: errorCode))
                return
            }
        }
    }

    private func handleDatagram(_ data: [UInt8], from storage: sockaddr_storage) {
        guard let (key, address) = clientEndpoint(from: storage),
              let packet = parsePacket(Data(data)) else {
            return
        }

        if clients[key] == nil {
            clients[key] = ClientState(address: address)
            notifyState(error: nil)
        }
        clients[key]?.lastSeen = Date()
        handle(packet, from: key)
    }

    private func clientEndpoint(from storage: sockaddr_storage) -> (ClientKey, sockaddr_in)? {
        var storage = storage
        return withUnsafePointer(to: &storage) { storagePointer in
            storagePointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addressPointer -> (ClientKey, sockaddr_in)? in
                let address = addressPointer.pointee
                guard Int32(address.sin_family) == AF_INET else { return nil }
                let hostAddress = UInt32(bigEndian: address.sin_addr.s_addr)
                guard (hostAddress & 0xFF00_0000) == 0x7F00_0000 else { return nil }
                return (
                    ClientKey(address: address.sin_addr.s_addr, port: UInt16(bigEndian: address.sin_port)),
                    address
                )
            }
        }
    }

    private func handle(_ packet: ParsedPacket, from clientKey: ClientKey) {
        switch packet.messageType {
        case MessageType.protocolVersion:
            sendPacket(messageType: packet.messageType, payload: littleEndian(UInt16(1001)) + [0, 0], to: clientKey)
        case MessageType.controllerInfo:
            for slot in requestedInfoSlots(packet.payload) {
                sendPacket(messageType: packet.messageType, payload: controllerInfoPayload(slot: slot), to: clientKey)
            }
        case MessageType.controllerData:
            subscribe(clientKey: clientKey, payload: packet.payload)
            sendSubscribedControllerData(to: clientKey)
        case MessageType.motorInfo:
            for slot in targetSlots(fromIdentifierPayload: packet.payload) {
                sendPacket(messageType: packet.messageType, payload: motorInfoPayload(slot: slot), to: clientKey)
            }
        case MessageType.rumble:
            handleRumble(packet.payload, from: clientKey)
        default:
            break
        }
    }

    private func requestedInfoSlots(_ payload: [UInt8]) -> [Int] {
        guard payload.count >= 4 else { return Array(0..<4) }
        let count = min(max(Int(int32LE(payload, offset: 0) ?? 4), 0), 4)
        let slots = payload.dropFirst(4).prefix(count).map(Int.init).filter { (0..<4).contains($0) }
        return slots.isEmpty ? Array(0..<4) : slots
    }

    private func subscribe(clientKey: ClientKey, payload: [UInt8]) {
        guard var client = clients[clientKey] else { return }
        client.subscriptions.insert(subscription(fromIdentifierPayload: payload))
        client.lastSeen = Date()
        clients[clientKey] = client
        notifyState(error: nil)
    }

    private func subscription(fromIdentifierPayload payload: [UInt8]) -> Subscription {
        guard let flags = payload.first else { return .all }
        if (flags & 0x01) != 0, payload.count >= 2 {
            return .slot(Int(payload[1]).clamped(to: 0...3))
        }
        if (flags & 0x02) != 0, payload.count >= 8 {
            return .mac(Array(payload[2..<8]))
        }
        return .all
    }

    private func targetSlots(fromIdentifierPayload payload: [UInt8]) -> [Int] {
        switch subscription(fromIdentifierPayload: payload) {
        case .all:
            return controllers.keys.sorted()
        case .slot(let slot):
            return controllers[slot] == nil ? [] : [slot]
        case .mac(let mac):
            return controllers.values.filter { macBytes(for: $0) == mac }.map(\.slot).sorted()
        }
    }

    private func handleRumble(_ payload: [UInt8], from clientKey: ClientKey) {
        guard payload.count >= 10 else { return }
        let intensity = payload[9]
        let slots = targetSlots(fromIdentifierPayload: Array(payload.prefix(8)))
        guard !slots.isEmpty else { return }

        if var client = clients[clientKey] {
            let deadline = Date().addingTimeInterval(5)
            for slot in slots {
                client.rumbleDeadlines[slot] = intensity == 0 ? nil : deadline
            }
            clients[clientKey] = client
        }

        for slot in slots {
            guard let controller = controllers[slot] else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.onRumble?(X360DSURumbleCommand(tag: controller.tag, intensity: intensity))
            }
        }
    }

    private func startSendTimer() {
        sendTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(8), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sendTick() }
        timer.resume()
        sendTimer = timer
    }

    private func sendTick() {
        let now = Date()
        for key in Array(clients.keys) {
            guard var client = clients[key] else { continue }
            if now.timeIntervalSince(client.lastSeen) > 5 {
                for slot in client.rumbleDeadlines.keys {
                    if let controller = controllers[slot] {
                        DispatchQueue.main.async { [weak self] in
                            self?.onRumble?(X360DSURumbleCommand(tag: controller.tag, intensity: 0))
                        }
                    }
                }
                clients[key] = nil
                notifyState(error: nil)
                continue
            }

            for (slot, deadline) in client.rumbleDeadlines where deadline <= now {
                client.rumbleDeadlines[slot] = nil
                if let controller = controllers[slot] {
                    DispatchQueue.main.async { [weak self] in
                        self?.onRumble?(X360DSURumbleCommand(tag: controller.tag, intensity: 0))
                    }
                }
            }

            clients[key] = client
            sendSubscribedControllerData(to: key)
        }
    }

    private func sendSubscribedControllerData(to clientKey: ClientKey) {
        guard var client = clients[clientKey], !client.subscriptions.isEmpty else { return }
        for slot in subscribedSlots(for: client) {
            guard let controller = controllers[slot] else { continue }
            let payload = controllerDataPayload(controller, packetCounter: client.packetCounter)
            client.packetCounter &+= 1
            sendPacket(messageType: MessageType.controllerData, payload: payload, to: clientKey)
        }
        clients[clientKey] = client
    }

    private func subscribedSlots(for client: ClientState) -> [Int] {
        var slots = Set<Int>()
        for subscription in client.subscriptions {
            switch subscription {
            case .all:
                slots.formUnion(controllers.keys)
            case .slot(let slot):
                if controllers[slot] != nil { slots.insert(slot) }
            case .mac(let mac):
                for controller in controllers.values where macBytes(for: controller) == mac {
                    slots.insert(controller.slot)
                }
            }
        }
        return slots.sorted()
    }

    private func controllerInfoPayload(slot: Int) -> [UInt8] {
        guard let controller = controllers[slot] else { return disconnectedControllerHeader(slot: slot) + [0] }
        return sharedControllerHeader(controller) + [0]
    }

    private func motorInfoPayload(slot: Int) -> [UInt8] {
        guard let controller = controllers[slot] else { return disconnectedControllerHeader(slot: slot) + [0] }
        return sharedControllerHeader(controller) + [1]
    }

    private func controllerDataPayload(_ controller: X360DSUControllerSnapshot, packetCounter: UInt32) -> [UInt8] {
        var payload = sharedControllerHeader(controller)
        payload.append(1)
        payload.append(contentsOf: littleEndian(packetCounter))

        var buttons1: UInt8 = 0
        if controller.dpadLeft { buttons1 |= 0x80 }
        if controller.dpadDown { buttons1 |= 0x40 }
        if controller.dpadRight { buttons1 |= 0x20 }
        if controller.dpadUp { buttons1 |= 0x10 }
        if controller.has(.start) { buttons1 |= 0x08 }
        if controller.has(.rightStick) { buttons1 |= 0x04 }
        if controller.has(.leftStick) { buttons1 |= 0x02 }
        if controller.has(.back) { buttons1 |= 0x01 }

        var buttons2: UInt8 = 0
        if controller.has(.y) { buttons2 |= 0x80 }
        if controller.has(.b) { buttons2 |= 0x40 }
        if controller.has(.a) { buttons2 |= 0x20 }
        if controller.has(.x) { buttons2 |= 0x10 }
        if controller.has(.rightShoulder) { buttons2 |= 0x08 }
        if controller.has(.leftShoulder) { buttons2 |= 0x04 }
        if controller.rightTrigger > 0 { buttons2 |= 0x02 }
        if controller.leftTrigger > 0 { buttons2 |= 0x01 }

        payload.append(buttons1)
        payload.append(buttons2)
        payload.append(controller.has(.guide) ? 1 : 0)
        payload.append(0)
        payload.append(axisByte(controller.leftX))
        payload.append(yAxisByte(controller.leftY))
        payload.append(axisByte(controller.rightX))
        payload.append(yAxisByte(controller.rightY))
        payload.append(controller.dpadLeft ? 255 : 0)
        payload.append(controller.dpadDown ? 255 : 0)
        payload.append(controller.dpadRight ? 255 : 0)
        payload.append(controller.dpadUp ? 255 : 0)
        payload.append(controller.has(.x) ? 255 : 0)
        payload.append(controller.has(.a) ? 255 : 0)
        payload.append(controller.has(.b) ? 255 : 0)
        payload.append(controller.has(.y) ? 255 : 0)
        payload.append(controller.has(.rightShoulder) ? 255 : 0)
        payload.append(controller.has(.leftShoulder) ? 255 : 0)
        payload.append(controller.rightTrigger)
        payload.append(controller.leftTrigger)
        payload.append(contentsOf: Array(repeating: 0, count: 12))
        payload.append(contentsOf: littleEndian(currentMicroseconds()))
        payload.append(contentsOf: Array(repeating: 0, count: 24))
        return payload
    }

    private func sharedControllerHeader(_ controller: X360DSUControllerSnapshot) -> [UInt8] {
        var payload: [UInt8] = [
            UInt8(controller.slot.clamped(to: 0...3)),
            2,
            1,
            controller.wired ? 1 : 2
        ]
        payload.append(contentsOf: macBytes(for: controller))
        payload.append(0x05)
        return payload
    }

    private func disconnectedControllerHeader(slot: Int) -> [UInt8] {
        [UInt8(slot.clamped(to: 0...3)), 0, 0, 0] + Array(repeating: 0, count: 7)
    }

    private func sendPacket(messageType: UInt32, payload: [UInt8], to clientKey: ClientKey) {
        guard socketFD >= 0, var address = clients[clientKey]?.address else { return }
        let packet = buildPacket(messageType: messageType, payload: payload)
        let result = packet.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.sendto(socketFD, baseAddress, rawBuffer.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if result < 0 {
            notifyState(error: socketError("sendto"))
        }
    }

    private func buildPacket(messageType: UInt32, payload: [UInt8]) -> Data {
        var bytes = Array("DSUS".utf8)
        bytes.append(contentsOf: littleEndian(UInt16(1001)))
        bytes.append(contentsOf: littleEndian(UInt16(4 + payload.count)))
        bytes.append(contentsOf: littleEndian(UInt32(0)))
        bytes.append(contentsOf: littleEndian(serverID))
        bytes.append(contentsOf: littleEndian(messageType))
        bytes.append(contentsOf: payload)
        let crc = CRC32.checksum(bytes)
        writeLittleEndian(crc, into: &bytes, at: 8)
        return Data(bytes)
    }

    private func parsePacket(_ data: Data) -> ParsedPacket? {
        var bytes = Array(data)
        guard bytes.count >= 20,
              bytes[0] == UInt8(ascii: "D"),
              bytes[1] == UInt8(ascii: "S"),
              bytes[2] == UInt8(ascii: "U"),
              bytes[3] == UInt8(ascii: "C"),
              (uint16LE(bytes, offset: 4) ?? 0) <= 1001,
              let length = uint16LE(bytes, offset: 6),
              length >= 4 else {
            return nil
        }

        let packetLength = 16 + Int(length)
        guard bytes.count >= packetLength else { return nil }
        bytes = Array(bytes.prefix(packetLength))
        let expectedCRC = uint32LE(bytes, offset: 8) ?? 0
        if expectedCRC != 0 {
            var checkBytes = bytes
            writeLittleEndian(UInt32(0), into: &checkBytes, at: 8)
            guard CRC32.checksum(checkBytes) == expectedCRC else { return nil }
        }

        guard let messageType = uint32LE(bytes, offset: 16) else { return nil }
        return ParsedPacket(messageType: messageType, payload: Array(bytes[20..<packetLength]))
    }

    private func notifyState(error: String?) {
        notifyState(isRunning: isRunning, error: error)
    }

    private func notifyState(isRunning: Bool, error: String?) {
        let clientCount = clients.count
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(isRunning, clientCount, error)
        }
    }

    private func socketError(_ operation: String, code: Int32 = errno) -> String {
        "DSU UDP \(operation) failed: \(String(cString: strerror(code)))."
    }
}

private enum X360DSUButton: UInt16 {
    case a = 1
    case b = 2
    case x = 4
    case y = 8
    case leftShoulder = 16
    case rightShoulder = 32
    case back = 64
    case start = 128
    case leftStick = 256
    case rightStick = 512
    case guide = 1024
}

private extension X360DSUControllerSnapshot {
    func has(_ button: X360DSUButton) -> Bool {
        (buttonsMask & button.rawValue) != 0
    }
}

private func macBytes(for controller: X360DSUControllerSnapshot) -> [UInt8] {
    let seed = UInt64(0x3600_0000) | UInt64(UInt8(controller.tag & 0xFF))
    return stride(from: 0, to: 6, by: 1).map { offset in
        UInt8((seed >> UInt64(offset * 8)) & 0xFF)
    }
}

private func axisByte(_ value: Int16) -> UInt8 {
    let normalized = (Int(value) + 32768).clamped(to: 0...65535)
    return UInt8(clamping: normalized / 257)
}

private func yAxisByte(_ value: Int16) -> UInt8 {
    UInt8(255 - Int(axisByte(value)))
}

private func currentMicroseconds() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1_000_000)
}

private func int32LE(_ bytes: [UInt8], offset: Int) -> Int32? {
    uint32LE(bytes, offset: offset).map { Int32(bitPattern: $0) }
}

private func uint16LE(_ bytes: [UInt8], offset: Int) -> UInt16? {
    guard bytes.count >= offset + 2 else { return nil }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func uint32LE(_ bytes: [UInt8], offset: Int) -> UInt32? {
    guard bytes.count >= offset + 4 else { return nil }
    return UInt32(bytes[offset]) |
        (UInt32(bytes[offset + 1]) << 8) |
        (UInt32(bytes[offset + 2]) << 16) |
        (UInt32(bytes[offset + 3]) << 24)
}

private func littleEndian(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
}

private func littleEndian(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF)
    ]
}

private func littleEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) }
}

private func writeLittleEndian(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
    let encoded = littleEndian(value)
    guard bytes.count >= offset + encoded.count else { return }
    for index in 0..<encoded.count {
        bytes[offset + index] = encoded[index]
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if (crc & 1) != 0 {
                crc = 0xEDB88320 ^ (crc >> 1)
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
