import Testing
@testable import OmarchyVMHelper

@Suite("Port forwarding availability")
struct PortForwardAvailabilityTests {
    @Test(
        "reports the first unavailable mapping with its protocol",
        arguments: [PortForwardProtocol.tcp, .udp]
    )
    func unavailableMapping(protocol protocolValue: PortForwardProtocol) {
        let mappings = [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: protocolValue),
            PortForwardMapping(hostPort: 2222, guestPort: 22, protocol: .tcp),
        ]
        var probed: [PortForwardMapping] = []

        #expect(throws: PortForwardAvailabilityError.unavailable(protocolValue, 5353)) {
            try PortForwardAvailability.validate(mappings) { mapping in
                probed.append(mapping)
                return mapping.hostPort != 5353
            }
        }
        #expect(probed == Array(mappings.prefix(2)))
    }

    @Test("all mappings are probed in order when every port is available")
    func allAvailable() throws {
        let mappings = [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
        ]
        var probed: [PortForwardMapping] = []

        try PortForwardAvailability.validate(mappings) { mapping in
            probed.append(mapping)
            return true
        }

        #expect(probed == mappings)
    }

    @Test("policy validation runs before any operating-system probe")
    func invalidMappingsAreNotProbed() {
        var probeCount = 0

        #expect(throws: PortForwardPolicyError.invalidHostPort(0)) {
            try PortForwardAvailability.validate([
                PortForwardMapping(hostPort: 0, guestPort: 3000, protocol: .tcp),
            ]) { _ in
                probeCount += 1
                return true
            }
        }
        #expect(probeCount == 0)
    }
}
