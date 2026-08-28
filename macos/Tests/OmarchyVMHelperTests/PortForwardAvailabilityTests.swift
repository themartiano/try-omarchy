import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Port forwarding availability")
struct PortForwardAvailabilityTests {
    @Test("reports an occupied TCP port with an actionable mapping error")
    func occupiedTCPPort() throws {
        let reserved = try ReservedLoopbackPort(protocol: .tcp)
        defer { reserved.close() }

        #expect(throws: PortForwardAvailabilityError.unavailable(.tcp, reserved.port)) {
            try PortForwardAvailability.validate([
                PortForwardMapping(hostPort: reserved.port, guestPort: 3000, protocol: .tcp),
            ])
        }
    }

    @Test("reports an occupied UDP port independently")
    func occupiedUDPPort() throws {
        let reserved = try ReservedLoopbackPort(protocol: .udp)
        defer { reserved.close() }

        #expect(throws: PortForwardAvailabilityError.unavailable(.udp, reserved.port)) {
            try PortForwardAvailability.validate([
                PortForwardMapping(hostPort: reserved.port, guestPort: 5353, protocol: .udp),
            ])
        }
    }

    private final class ReservedLoopbackPort {
        let descriptor: Int32
        let port: Int

        init(protocol protocolValue: PortForwardProtocol) throws {
            let type = protocolValue == .tcp
                ? SOCK_STREAM
                : SOCK_DGRAM
            let localDescriptor = Darwin.socket(AF_INET, type, 0)
            guard localDescriptor >= 0 else {
                throw POSIXError(.ENOTSOCK)
            }
            var shouldClose = true
            defer {
                if shouldClose {
                    Darwin.close(localDescriptor)
                }
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        localDescriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard bound == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
            }
            if protocolValue == .tcp {
                guard Darwin.listen(localDescriptor, 1) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
                }
            }

            var selectedAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let found = withUnsafeMutablePointer(to: &selectedAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(localDescriptor, $0, &length)
                }
            }
            guard found == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            descriptor = localDescriptor
            port = Int(in_port_t(bigEndian: selectedAddress.sin_port))
            shouldClose = false
        }

        func close() {
            Darwin.close(descriptor)
        }
    }
}
