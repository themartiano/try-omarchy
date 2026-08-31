import Darwin
import Foundation

/// One authenticated connection to QEMU's private machine-protocol socket.
///
/// QMP can interleave asynchronous events with command replies, so every
/// request carries an identifier and waits for the response with that exact
/// identifier. Calls are serialized because a QMP connection is an ordered
/// byte stream.
final class QMPConnection: @unchecked Sendable {
    struct CommandExecution {
        let result: [String: Any]
        let events: [String]
    }

    private struct MatchedResponse {
        let object: [String: Any]
        let events: [String]
    }

    private let descriptor: Int32
    private let identifierPrefix: String
    private let queue = DispatchQueue(label: "dev.tryomarchy.qmp-connection", qos: .userInteractive)
    private var nextIdentifier: UInt64 = 1
    private var closed = false

    init(
        socketPath: String,
        identifierPrefix: String,
        timeoutMilliseconds: Int32 = 2_000
    ) throws {
        let descriptor = try Self.connectSecureSocket(path: socketPath)
        self.descriptor = descriptor
        self.identifierPrefix = identifierPrefix
        do {
            try negotiateCapabilities(timeoutMilliseconds: timeoutMilliseconds)
        } catch {
            Darwin.close(descriptor)
            closed = true
            throw error
        }
    }

    /// Test seam for a connected local socket. Production callers must use
    /// the pathname initializer so ownership, permissions, and type are
    /// checked before connecting.
    init(
        connectedDescriptor descriptor: Int32,
        identifierPrefix: String,
        timeoutMilliseconds: Int32 = 2_000
    ) throws {
        self.descriptor = descriptor
        self.identifierPrefix = identifierPrefix
        do {
            try negotiateCapabilities(timeoutMilliseconds: timeoutMilliseconds)
        } catch {
            Darwin.close(descriptor)
            closed = true
            throw error
        }
    }

    deinit {
        if !closed {
            Darwin.close(descriptor)
        }
    }

    func execute(
        _ command: String,
        arguments: [String: Any]? = nil,
        timeoutMilliseconds: Int32 = 2_000
    ) throws -> [String: Any] {
        try executeCapturingEvents(
            command,
            arguments: arguments,
            timeoutMilliseconds: timeoutMilliseconds
        ).result
    }

    func executeCapturingEvents(
        _ command: String,
        arguments: [String: Any]? = nil,
        timeoutMilliseconds: Int32 = 2_000
    ) throws -> CommandExecution {
        try queue.sync { [self] in
            guard !closed else {
                throw HelperError.io("QMP control is unavailable")
            }
            let identifier = nextCommandIdentifier()
            var request: [String: Any] = [
                "execute": command,
                "id": identifier,
            ]
            if let arguments {
                request["arguments"] = arguments
            }
            do {
                try Self.writeJSON(request, to: descriptor)
                guard let matched = try Self.readResponse(
                    id: identifier,
                    from: descriptor,
                    timeoutMilliseconds: timeoutMilliseconds
                ) else {
                    throw HelperError.io("QMP command \(command) timed out")
                }
                let response = matched.object
                if let error = response["error"] as? [String: Any] {
                    let detail = error["desc"] as? String ?? "unknown QMP error"
                    throw HelperError.io("QMP command \(command) failed: \(detail)")
                }
                guard let result = response["return"] as? [String: Any] else {
                    throw HelperError.io("QMP command \(command) returned an invalid response")
                }
                return CommandExecution(result: result, events: matched.events)
            } catch {
                closeWithoutSynchronization()
                throw error
            }
        }
    }

    /// Sends a latency-sensitive command after negotiating QMP, without
    /// waiting for its reply. The currently available response/event bytes are
    /// drained so a long-lived input connection cannot grow without bound.
    func send(
        _ command: String,
        arguments: [String: Any]? = nil
    ) throws {
        try queue.sync { [self] in
            guard !closed else {
                throw HelperError.io("QMP control is unavailable")
            }
            var request: [String: Any] = [
                "execute": command,
                "id": nextCommandIdentifier(),
            ]
            if let arguments {
                request["arguments"] = arguments
            }
            do {
                try Self.writeJSON(request, to: descriptor)
                Self.drainAvailableInput(from: descriptor)
            } catch {
                closeWithoutSynchronization()
                throw error
            }
        }
    }

    func close() {
        queue.sync { [self] in
            closeWithoutSynchronization()
        }
    }

    private func negotiateCapabilities(timeoutMilliseconds: Int32) throws {
        guard let greeting = try Self.readJSONObject(
            from: descriptor,
            timeoutMilliseconds: timeoutMilliseconds
        ), greeting["QMP"] != nil else {
            throw HelperError.io("QMP socket did not send a valid greeting")
        }
        let identifier = "\(identifierPrefix)-capabilities"
        try Self.writeJSON([
            "execute": "qmp_capabilities",
            "id": identifier,
        ], to: descriptor)
        guard let matched = try Self.readResponse(
            id: identifier,
            from: descriptor,
            timeoutMilliseconds: timeoutMilliseconds
        ), matched.object["return"] != nil, matched.object["error"] == nil else {
            throw HelperError.io("QMP capability negotiation failed")
        }
    }

    private func nextCommandIdentifier() -> String {
        defer { nextIdentifier += 1 }
        return "\(identifierPrefix)-\(nextIdentifier)"
    }

    private func closeWithoutSynchronization() {
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }

    private static func connectSecureSocket(path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw HelperError.io("QMP socket path must be an absolute pathname")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path else {
            throw HelperError.io("QMP socket path must already be standardized")
        }
        let parent = url.deletingLastPathComponent()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == getuid(),
              (parentInfo.st_mode & 0o077) == 0 else {
            throw HelperError.io("QMP socket parent must be a private directory owned by this user")
        }
        var socketInfo = stat()
        guard lstat(path, &socketInfo) == 0,
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              socketInfo.st_uid == getuid() else {
            throw HelperError.io("QMP endpoint must be a Unix socket owned by this user")
        }

        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw HelperError.io("QMP socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }

        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw HelperError.io("cannot create QMP socket") }
        var noSignal: Int32 = 1
        guard withUnsafePointer(to: &noSignal, {
            setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }) == 0 else {
            Darwin.close(fileDescriptor)
            throw HelperError.io("cannot make QMP socket resilient to guest exit")
        }
        let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        let length = socklen_t(offset + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, length)
            }
        }
        guard result == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(fileDescriptor)
            throw HelperError.io("cannot connect to QMP socket: \(detail)")
        }
        return fileDescriptor
    }

    static func writeJSON(_ object: [String: Any], to descriptor: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(contentsOf: [0x0D, 0x0A])
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    rawBuffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else {
                    throw HelperError.io("cannot write QMP command")
                }
            }
        }
    }

    private static func readResponse(
        id: String,
        from descriptor: Int32,
        timeoutMilliseconds: Int32
    ) throws -> MatchedResponse? {
        let deadline = deadline(afterMilliseconds: timeoutMilliseconds)
        var events: [String] = []
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard let object = try readJSONObject(
                from: descriptor,
                deadline: deadline
            ) else {
                return nil
            }
            if let event = object["event"] as? String {
                events.append(event)
            }
            if object["id"] as? String == id {
                return MatchedResponse(object: object, events: events)
            }
        }
        return nil
    }

    private static func readJSONObject(
        from descriptor: Int32,
        timeoutMilliseconds: Int32
    ) throws -> [String: Any]? {
        try readJSONObject(
            from: descriptor,
            deadline: deadline(afterMilliseconds: timeoutMilliseconds)
        )
    }

    private static func readJSONObject(
        from descriptor: Int32,
        deadline: UInt64
    ) throws -> [String: Any]? {
        var bytes = Data()
        while bytes.count <= 1_048_576 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            let remainingNanoseconds = deadline - now
            let roundedMilliseconds = remainingNanoseconds / 1_000_000
                + (remainingNanoseconds % 1_000_000 == 0 ? 0 : 1)
            let remainingMilliseconds = Int32(min(
                UInt64(Int32.max),
                roundedMilliseconds
            ))
            var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptorPoll, 1, remainingMilliseconds)
            if ready == 0 { return nil }
            if ready < 0 {
                if errno == EINTR { continue }
                throw HelperError.io("cannot poll QMP socket")
            }
            guard descriptorPoll.revents & Int16(POLLIN) != 0 else {
                throw HelperError.io("QMP socket closed while awaiting a response")
            }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    guard let object = try JSONSerialization.jsonObject(with: bytes)
                        as? [String: Any] else {
                        throw HelperError.io("QMP response is not a JSON object")
                    }
                    return object
                }
                if byte != 0x0D { bytes.append(byte) }
            } else if count == 0 {
                throw HelperError.io("QMP socket closed while awaiting a response")
            } else if errno != EINTR {
                throw HelperError.io("cannot read QMP socket")
            }
        }
        throw HelperError.io("QMP response exceeds one MiB")
    }

    private static func deadline(afterMilliseconds milliseconds: Int32) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard milliseconds > 0 else { return now }
        let delta = UInt64(milliseconds) * 1_000_000
        let (deadline, overflow) = now.addingReportingOverflow(delta)
        return overflow ? UInt64.max : deadline
    }

    private static func drainAvailableInput(from descriptor: Int32) {
        var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while Darwin.poll(&descriptorPoll, 1, 0) > 0,
              descriptorPoll.revents & Int16(POLLIN) != 0 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count <= 0 { return }
            descriptorPoll.revents = 0
        }
    }
}
