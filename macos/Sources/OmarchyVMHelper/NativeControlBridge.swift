import Darwin
import CoreFoundation
import Foundation

/// A small, one-way control protocol used for update completion and boot
/// health.  The guest is user-controlled, so messages are treated as status
/// reports rather than as authority to choose host paths or operations.
struct GuestControlMessage: Equatable {
    enum Kind: String, Equatable {
        case health
        case update
    }

    enum Readiness: String, Equatable {
        case graphical
        case system
    }

    static let protocolVersion = 1
    static let maximumLineBytes = 4 * 1024

    let bootABI: String
    let errorCode: String?
    let fromGuestStateSchema: Int?
    let guestStateSchema: Int
    let kind: Kind
    let protocolVersion: Int
    let readiness: Readiness?
    let status: String
    let transaction: String?

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumLineBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawKind = object["type"] as? String,
              let kind = Kind(rawValue: rawKind),
              let bootABI = object["bootABI"] as? String,
              isSafeBootABI(bootABI),
              let schema = exactInteger(object["guestStateSchema"]), schema > 0,
              let version = exactInteger(object["protocolVersion"]),
              version == protocolVersion,
              let status = object["status"] as? String else {
            throw HelperError.io("guest sent an invalid control message")
        }

        let transaction = object["transaction"] as? String
        var errorCode: String?
        var fromGuestStateSchema: Int?
        var readiness: Readiness?
        switch kind {
        case .health:
            let allowed = transaction == nil
                ? Set(["bootABI", "guestStateSchema", "protocolVersion", "readiness", "status", "type"])
                : Set(["bootABI", "guestStateSchema", "protocolVersion", "readiness", "status", "transaction", "type"])
            let expectedReadiness: Readiness = transaction == nil ? .graphical : .system
            guard Set(object.keys) == allowed,
                  status == "ready",
                  let rawReadiness = object["readiness"] as? String,
                  let decodedReadiness = Readiness(rawValue: rawReadiness),
                  decodedReadiness == expectedReadiness,
                  transaction.map(isIdentity) ?? true else {
                throw HelperError.io("guest health message has an unexpected schema")
            }
            readiness = decodedReadiness
        case .update:
            let completionKeys = Set([
                "bootABI", "fromGuestStateSchema", "guestStateSchema", "protocolVersion", "status",
                "transaction", "type",
            ])
            let failureKeys = completionKeys.union(["errorCode"])
            guard (status == "complete" && Set(object.keys) == completionKeys)
                    || (status == "failed" && Set(object.keys) == failureKeys),
                  let sourceSchema = exactInteger(object["fromGuestStateSchema"]), sourceSchema >= 0,
                  sourceSchema <= schema,
                  let transaction, isIdentity(transaction) else {
                throw HelperError.io("guest update message has an unexpected schema")
            }
            if status == "failed" {
                guard let decodedErrorCode = object["errorCode"] as? String,
                      isErrorCode(decodedErrorCode) else {
                    throw HelperError.io("guest update failure has an invalid error code")
                }
                errorCode = decodedErrorCode
            }
            fromGuestStateSchema = sourceSchema
        }

        return Self(
            bootABI: bootABI,
            errorCode: errorCode,
            fromGuestStateSchema: fromGuestStateSchema,
            guestStateSchema: schema,
            kind: kind,
            protocolVersion: version,
            readiness: readiness,
            status: status,
            transaction: transaction
        )
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.intValue
        guard number.doubleValue == Double(integer) else { return nil }
        return integer
    }

    private static func isSafeBootABI(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isIdentity(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func isErrorCode(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 64,
              bytes.first != 45, bytes.last != 45 else { return false }
        var previousWasHyphen = false
        for byte in bytes {
            let isHyphen = byte == 45
            guard (byte >= 48 && byte <= 57)
                    || (byte >= 97 && byte <= 122)
                    || isHyphen,
                  !(isHyphen && previousWasHyphen) else { return false }
            previousWasHyphen = isHyphen
        }
        return true
    }
}

struct GuestControlExpectation: Equatable {
    let bootABI: String
    let guestStateSchema: Int
    let kind: GuestControlMessage.Kind
    let transaction: String?

    func accepts(_ message: GuestControlMessage) -> Bool {
        message.protocolVersion == GuestControlMessage.protocolVersion
            && message.kind == kind
            && message.bootABI == bootABI
            && message.guestStateSchema == guestStateSchema
            && message.transaction == transaction
    }
}

struct GuestControlSequence: Equatable {
    private let expectation: GuestControlExpectation
    private var updateCompleted: Bool

    init(expectation: GuestControlExpectation) {
        self.expectation = expectation
        updateCompleted = expectation.kind == .health
    }

    /// Returns true only when the complete expected sequence has reached a
    /// health-gated commit point. An update completion by itself is never
    /// enough to activate a candidate disk.
    mutating func receive(_ message: GuestControlMessage) throws -> Bool {
        if !updateCompleted {
            guard expectation.accepts(message) else {
                throw HelperError.io("guest update completion does not match this launch")
            }
            if let errorCode = message.errorCode {
                throw HelperError.io("guest update failed: \(errorCode)")
            }
            updateCompleted = true
            return false
        }
        let health = GuestControlExpectation(
            bootABI: expectation.bootABI,
            guestStateSchema: expectation.guestStateSchema,
            kind: .health,
            transaction: expectation.transaction
        )
        guard health.accepts(message) else {
            throw HelperError.io("guest health report does not match this launch")
        }
        return true
    }
}

/// Connects to the QEMU virtio-serial control endpoint and publishes one
/// validated event through an O_EXCL marker.  The shell launcher commits an
/// update only after this marker exists.
final class NativeControlBridge {
    private let descriptor: Int32
    private let eventPath: String
    private let expectation: GuestControlExpectation
    private let stopLock = NSLock()
    private var stopped = false

    init(
        targetPID: pid_t,
        socketPath: String,
        eventPath: String,
        expectation: GuestControlExpectation
    ) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("native control bridge target is not a QEMU system process")
        }
        try Self.validateEventPath(eventPath)
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "control bridge")
        self.eventPath = eventPath
        self.expectation = expectation
    }

    deinit {
        stop()
    }

    func run() throws {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        var sequence = GuestControlSequence(expectation: expectation)
        while true {
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                var start = 0
                for index in 0..<count where chunk[index] == 0x0A {
                    line.append(contentsOf: chunk[start..<index])
                    let message = try GuestControlMessage.decode(line)
                    if try sequence.receive(message) {
                        try publishEvent()
                        return
                    }
                    line.removeAll(keepingCapacity: true)
                    start = index + 1
                }
                line.append(contentsOf: chunk[start..<count])
                guard line.count <= GuestControlMessage.maximumLineBytes else {
                    throw HelperError.io("guest control message exceeds the size limit")
                }
            } else if count == 0 {
                throw HelperError.io("guest control channel closed before reporting readiness")
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest control channel")
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
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func publishEvent() throws {
        let descriptor = Darwin.open(eventPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw HelperError.io("cannot publish the validated guest control event")
        }
        defer { Darwin.close(descriptor) }
        try NativeBridgeSocket.writeAll(Data("validated\n".utf8), to: descriptor, label: "control event")
        guard Darwin.fsync(descriptor) == 0 else {
            throw HelperError.io("cannot flush the validated guest control event")
        }
    }

    private static func validateEventPath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw HelperError.io("control event path must be absolute")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path, url.lastPathComponent == ".control-event" else {
            throw HelperError.io("control event path is outside the launcher contract")
        }
        let parent = url.deletingLastPathComponent()
        var information = stat()
        guard lstat(parent.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == getuid(),
              information.st_mode & 0o077 == 0,
              lstat(path, &information) != 0,
              errno == ENOENT else {
            throw HelperError.io("control event path must be absent inside a private directory")
        }
    }
}
