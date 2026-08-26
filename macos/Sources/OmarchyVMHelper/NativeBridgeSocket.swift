import Darwin
import Foundation

/// Connects the helper to one of QEMU's private virtio-serial chardev sockets.
/// The socket must already exist inside the launcher's owned, mode-0700 run
/// directory so another local user cannot pre-create or swap the endpoint.
enum NativeBridgeSocket {
    static func connectSecure(path: String, label: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw HelperError.io("\(label) socket path must be an absolute pathname")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path else {
            throw HelperError.io("\(label) socket path must already be standardized")
        }
        let parent = url.deletingLastPathComponent()
        var parentInfo = stat()
        var socketInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == getuid(),
              (parentInfo.st_mode & 0o077) == 0,
              lstat(path, &socketInfo) == 0,
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              socketInfo.st_uid == getuid() else {
            throw HelperError.io("\(label) endpoint must be a private owned Unix socket")
        }

        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw HelperError.io("\(label) socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }
        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw HelperError.io("cannot create \(label) socket") }
        var noSignal: Int32 = 1
        guard withUnsafePointer(to: &noSignal, {
            setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }) == 0 else {
            Darwin.close(socketDescriptor)
            throw HelperError.io("cannot configure \(label) socket")
        }
        let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        let length = socklen_t(offset + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, length)
            }
        }
        guard result == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(socketDescriptor)
            throw HelperError.io("cannot connect to \(label) socket: \(detail)")
        }
        return socketDescriptor
    }

    /// Writes every byte, retrying on EINTR, or throws.
    static func writeAll(_ data: Data, to descriptor: Int32, label: String) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    throw HelperError.io("cannot write the guest \(label) channel")
                }
            }
        }
    }
}
