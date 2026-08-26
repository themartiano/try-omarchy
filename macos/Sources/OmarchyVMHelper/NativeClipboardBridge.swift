import AppKit
import CryptoKit
import Darwin
import Foundation

/// One clipboard payload crossing the virtio channel in either direction.
struct ClipboardMessage: Equatable {
    enum Format: String, CaseIterable, Equatable {
        case text = "text/plain;charset=utf-8"
        case png = "image/png"
    }

    /// Raw payload bytes before base64. Large enough for screenshots and
    /// pasted documents; bounded so a runaway selection cannot exhaust memory.
    static let maximumPayloadBytes = 16 * 1024 * 1024
    static let maximumLineBytes = maximumPayloadBytes * 4 / 3 + 4096

    let format: Format
    let payload: Data

    init?(format: Format, payload: Data) {
        guard !payload.isEmpty, payload.count <= Self.maximumPayloadBytes else { return nil }
        if format == .text, String(data: payload, encoding: .utf8) == nil {
            return nil
        }
        self.format = format
        self.payload = payload
    }

    var text: String? {
        guard format == .text else { return nil }
        return String(data: payload, encoding: .utf8)
    }

    /// Stable identity used to suppress echoes between the two sides.
    var fingerprint: String {
        var hasher = SHA256()
        hasher.update(data: Data(format.rawValue.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: payload)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func encode() throws -> Data {
        let object: [String: Any] = [
            "type": "clipboard",
            "format": format.rawValue,
            "data": payload.base64EncodedString(),
        ]
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    enum GuestLine: Equatable {
        case clipboard(ClipboardMessage)
        case sync
        case ignored
    }

    /// Decodes one guest line. Unknown formats are ignored rather than fatal
    /// so a newer guest agent cannot take the whole bridge down.
    static func decode(_ data: Data) throws -> GuestLine {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw HelperError.io("guest sent an invalid clipboard message")
        }
        switch type {
        case "sync":
            guard object.keys.sorted() == ["type"] else {
                throw HelperError.io("guest clipboard sync has an unexpected schema")
            }
            return .sync
        case "clipboard":
            guard object.keys.sorted() == ["data", "format", "type"],
                  let rawFormat = object["format"] as? String,
                  let encoded = object["data"] as? String else {
                throw HelperError.io("guest clipboard message has an unexpected schema")
            }
            guard let format = Format(rawValue: rawFormat) else { return .ignored }
            guard let payload = Data(base64Encoded: encoded) else {
                throw HelperError.io("guest clipboard payload is not base64")
            }
            guard let message = ClipboardMessage(format: format, payload: payload) else {
                return .ignored
            }
            return .clipboard(message)
        default:
            throw HelperError.io("guest sent an unknown clipboard message type")
        }
    }
}

/// Echo-safe two-way bookkeeping shared by the tests and the live bridge.
/// Applying the guest's selection to the Mac pasteboard bumps the pasteboard
/// change count, and writing the Mac pasteboard into the guest triggers the
/// guest watcher; both are recognized by fingerprint and dropped.
///
/// A marker only protects content that is still on the other side's
/// clipboard. Accepting a new change in one direction therefore clears the
/// other direction's marker: after guest copies B and Mac copies A, the
/// pasteboard no longer holds B, so a later Mac copy of B is new content and
/// must not be mistaken for the original echo. Echoes are delivered in order
/// before any later user copy, so clearing cannot let one through. A short
/// expiry backs this up for markers that never see an opposite change.
struct ClipboardSyncState: Equatable {
    /// How long a write may be mirrored back before it counts as new content.
    static let echoWindow: TimeInterval = 2

    private struct Marker: Equatable {
        let fingerprint: String
        let at: TimeInterval
    }

    private var fromHost: Marker?
    private var fromGuest: Marker?

    var lastFromHost: String? { fromHost?.fingerprint }
    var lastFromGuest: String? { fromGuest?.fingerprint }

    private static func isEcho(_ marker: Marker?, _ key: String, at now: TimeInterval) -> Bool {
        guard let marker, marker.fingerprint == key else { return false }
        return now - marker.at <= echoWindow
    }

    /// Returns true when the host update should be forwarded to the guest.
    mutating func hostChanged(
        _ message: ClipboardMessage,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let key = message.fingerprint
        // Applying a guest selection bumps the pasteboard change count; only
        // that echo is dropped. A repeat of earlier Mac content is a change.
        guard !Self.isEcho(fromGuest, key, at: now) else { return false }
        fromHost = Marker(fingerprint: key, at: now)
        fromGuest = nil
        return true
    }

    /// Returns true when the guest update should be applied to the pasteboard.
    mutating func guestChanged(
        _ message: ClipboardMessage,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let key = message.fingerprint
        guard !Self.isEcho(fromHost, key, at: now) else { return false }
        fromGuest = Marker(fingerprint: key, at: now)
        fromHost = nil
        return true
    }
}

protocol HostPasteboardProviding: AnyObject {
    var changeCount: Int { get }
    func read() -> ClipboardMessage?
    func write(_ message: ClipboardMessage)
}

/// NSPasteboard adapter. Text wins over images when both are offered because
/// rich text copies usually carry a preview image alongside the string.
final class GeneralPasteboard: HostPasteboardProviding {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func read() -> ClipboardMessage? {
        if let text = pasteboard.string(forType: .string),
           let message = ClipboardMessage(format: .text, payload: Data(text.utf8)) {
            return message
        }
        if let png = pasteboard.data(forType: .png),
           let message = ClipboardMessage(format: .png, payload: png) {
            return message
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]),
           let message = ClipboardMessage(format: .png, payload: png) {
            return message
        }
        return nil
    }

    func write(_ message: ClipboardMessage) {
        pasteboard.clearContents()
        switch message.format {
        case .text:
            if let text = message.text {
                pasteboard.setString(text, forType: .string)
            }
        case .png:
            pasteboard.setData(message.payload, forType: .png)
        }
    }
}

final class NativeClipboardBridge {
    private let descriptor: Int32
    private let pasteboard: HostPasteboardProviding
    private let stateQueue = DispatchQueue(label: "dev.tryomarchy.native.clipboard-bridge-state")
    private let writeQueue = DispatchQueue(label: "dev.tryomarchy.native.clipboard-bridge-writes")
    private let stopLock = NSLock()
    private var state = ClipboardSyncState()
    private var observedChangeCount: Int
    private var poller: DispatchSourceTimer?
    private var stopped = false

    init(
        targetPID: pid_t,
        socketPath: String,
        pasteboard: HostPasteboardProviding = GeneralPasteboard()
    ) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("native clipboard bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "clipboard bridge")
        self.pasteboard = pasteboard
        observedChangeCount = pasteboard.changeCount
    }

    deinit {
        stop()
    }

    func run() throws {
        startPolling()
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                var start = 0
                for index in 0..<count where chunk[index] == 0x0A {
                    line.append(contentsOf: chunk[start..<index])
                    try handle(line)
                    line.removeAll(keepingCapacity: true)
                    start = index + 1
                }
                line.append(contentsOf: chunk[start..<count])
                guard line.count <= ClipboardMessage.maximumLineBytes else {
                    throw HelperError.io("guest clipboard message exceeds the size limit")
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest clipboard channel")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()
        poller?.cancel()
        poller = nil
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func hasStopped() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    /// NSPasteboard has no change notification; a quarter-second poll of the
    /// integer change count is the documented approach and costs nothing
    /// until something is actually copied.
    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, !self.hasStopped() else { return }
            self.pollPasteboard()
        }
        timer.resume()
        poller = timer
    }

    private func pollPasteboard() {
        let current = pasteboard.changeCount
        guard current != observedChangeCount else { return }
        observedChangeCount = current
        guard let message = pasteboard.read(), state.hostChanged(message) else { return }
        do {
            try send(message.encode())
        } catch {
            fputs("[clipboard-bridge] \(error.localizedDescription)\n", stderr)
            stop()
        }
    }

    private func handle(_ data: Data) throws {
        try stateQueue.sync {
            switch try ClipboardMessage.decode(data) {
            case .sync:
                guard let message = pasteboard.read() else { return }
                // A fresh guest session asks for the current Mac clipboard.
                // Reset the host marker so the same text can be re-sent.
                state = ClipboardSyncState()
                guard state.hostChanged(message) else { return }
                try send(message.encode())
            case .clipboard(let message):
                guard state.guestChanged(message) else { return }
                pasteboard.write(message)
                observedChangeCount = pasteboard.changeCount
            case .ignored:
                return
            }
        }
    }

    private func send(_ data: Data) throws {
        try writeQueue.sync {
            try NativeBridgeSocket.writeAll(data, to: descriptor, label: "clipboard")
        }
    }
}
