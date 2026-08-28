import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Port forwarding policy")
struct PortForwardPolicyTests {
    @Test("accepts both inclusive port boundaries")
    func acceptsPortBoundaries() throws {
        let mappings = [
            PortForwardMapping(hostPort: 1, guestPort: 65_535, protocol: .tcp),
            PortForwardMapping(hostPort: 65_535, guestPort: 1, protocol: .udp),
        ]

        try PortForwardPolicy.validate(mappings)
        #expect(try PortForwardPolicy.encodedEnvironmentValue(for: mappings)
            == "tcp:1:65535;udp:65535:1")
    }

    @Test("rejects host and guest ports outside the valid range")
    func rejectsInvalidPorts() {
        #expect(throws: PortForwardPolicyError.invalidHostPort(0)) {
            try PortForwardPolicy.validate(.init(hostPort: 0, guestPort: 80, protocol: .tcp))
        }
        #expect(throws: PortForwardPolicyError.invalidHostPort(65_536)) {
            try PortForwardPolicy.validate(.init(hostPort: 65_536, guestPort: 80, protocol: .tcp))
        }
        #expect(throws: PortForwardPolicyError.invalidGuestPort(0)) {
            try PortForwardPolicy.validate(.init(hostPort: 8080, guestPort: 0, protocol: .tcp))
        }
        #expect(throws: PortForwardPolicyError.invalidGuestPort(65_536)) {
            try PortForwardPolicy.validate(.init(hostPort: 8080, guestPort: 65_536, protocol: .tcp))
        }
    }

    @Test("host-port uniqueness is scoped to the protocol")
    func duplicateSemantics() throws {
        try PortForwardPolicy.validate([
            .init(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            .init(hostPort: 8080, guestPort: 3000, protocol: .udp),
        ])

        #expect(throws: PortForwardPolicyError.duplicateHostPort(.tcp, 8080)) {
            try PortForwardPolicy.validate([
                .init(hostPort: 8080, guestPort: 3000, protocol: .tcp),
                .init(hostPort: 8080, guestPort: 4000, protocol: .tcp),
            ])
        }
    }

    @Test("encoding is canonical and preserves the user's order")
    func canonicalEncodingPreservesOrder() throws {
        let mappings = [
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 2222, guestPort: 22, protocol: .tcp),
        ]

        #expect(try PortForwardPolicy.encodedEnvironmentValue(for: mappings)
            == "udp:5353:5353;tcp:8080:3000;tcp:2222:22")
        #expect(try PortForwardPolicy.encodedEnvironmentValue(for: []) == nil)
    }

    @Test("the mapping limit is inclusive")
    func mappingLimit() throws {
        let maximum = makeMappings(count: PortForwardPolicy.maximumMappings)
        try PortForwardPolicy.validate(maximum)

        #expect(throws: PortForwardPolicyError.tooManyMappings(maximum: 32)) {
            try PortForwardPolicy.validate(makeMappings(count: PortForwardPolicy.maximumMappings + 1))
        }
    }

    private func makeMappings(count: Int) -> [PortForwardMapping] {
        (0..<count).map {
            PortForwardMapping(hostPort: 10_000 + $0, guestPort: 20_000 + $0, protocol: .tcp)
        }
    }
}

@Suite("Port forwarding preferences")
struct PortForwardingPreferenceStoreTests {
    @Test("an ordered mapping list survives a relaunch")
    func roundTripPreservesOrder() throws {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let expected = [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
        ]

        #expect(fixture.store.load().isEmpty)
        try fixture.store.save(expected)

        #expect(PortForwardingPreferenceStore(defaults: fixture.defaults).load() == expected)
    }

    @Test("invalid saves do not replace the last valid value")
    func rejectsInvalidSave() throws {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let valid = [PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp)]
        try fixture.store.save(valid)

        #expect(throws: PortForwardPolicyError.invalidHostPort(0)) {
            try fixture.store.save([.init(hostPort: 0, guestPort: 3000, protocol: .tcp)])
        }
        #expect(fixture.store.load() == valid)
    }

    @Test("corrupt, future-schema, and policy-invalid values fail closed")
    func invalidPersistedValuesFailClosed() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let invalidValues = [
            Data("not-json".utf8),
            Data(#"{"schemaVersion":99,"mappings":[]}"#.utf8),
            Data(#"{"schemaVersion":1,"mappings":[{"hostPort":0,"guestPort":80,"protocol":"tcp"}]}"#.utf8),
            Data(#"{"schemaVersion":1,"mappings":[{"hostPort":8080,"guestPort":80,"protocol":"tcp"},{"hostPort":8080,"guestPort":81,"protocol":"tcp"}]}"#.utf8),
            Data(#"{"schemaVersion":1,"mappings":[{"hostPort":8080,"guestPort":80,"protocol":"sctp"}]}"#.utf8),
        ]

        for data in invalidValues {
            fixture.defaults.set(data, forKey: PortForwardingPreferenceStore.key)
            #expect(fixture.store.load().isEmpty)
            #expect(fixture.defaults.data(forKey: PortForwardingPreferenceStore.key) == data)
        }
    }

    @Test("the store accepts 32 mappings and fails closed on a persisted 33rd")
    func persistedMaximumCount() throws {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let maximum = makeMappings(count: PortForwardPolicy.maximumMappings)
        try fixture.store.save(maximum)
        #expect(fixture.store.load() == maximum)

        let tooManyJSON = """
        {"schemaVersion":1,"mappings":[\(mappingObjects(count: PortForwardPolicy.maximumMappings + 1))]}
        """
        fixture.defaults.set(Data(tooManyJSON.utf8), forKey: PortForwardingPreferenceStore.key)
        #expect(fixture.store.load().isEmpty)
    }

    private func makeMappings(count: Int) -> [PortForwardMapping] {
        (0..<count).map {
            PortForwardMapping(hostPort: 10_000 + $0, guestPort: 20_000 + $0, protocol: .tcp)
        }
    }

    private func mappingObjects(count: Int) -> String {
        (0..<count).map {
            #"{"hostPort":\#(10_000 + $0),"guestPort":\#(20_000 + $0),"protocol":"tcp"}"#
        }.joined(separator: ",")
    }

    private final class DefaultsFixture {
        let suiteName = "dev.tryomarchy.native.tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: PortForwardingPreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = PortForwardingPreferenceStore(defaults: defaults)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("Port forwarding launch configuration")
struct PortForwardLaunchConfigurationTests {
    @Test("valid mappings replace an inherited value with canonical encoding")
    func emitsValidatedMappings() {
        let mappings = [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
        ]

        let configuration = PortForwardLaunchConfiguration.make(
            baseEnvironment: [
                "KEEP_ME": "yes",
                PortForwardPolicy.environmentKey: "tcp:1:1;injected",
            ],
            mappings: mappings
        )

        #expect(configuration.mappings == mappings)
        #expect(configuration.environment["KEEP_ME"] == "yes")
        #expect(configuration.environment[PortForwardPolicy.environmentKey]
            == "tcp:8080:3000;udp:5353:5353")
    }

    @Test("empty or invalid mappings strip inherited forwarding and fail closed")
    func stripsInheritedValue() {
        let inherited = [
            "KEEP_ME": "yes",
            PortForwardPolicy.environmentKey: "tcp:9000:9000",
        ]

        let empty = PortForwardLaunchConfiguration.make(
            baseEnvironment: inherited,
            mappings: []
        )
        #expect(empty.mappings.isEmpty)
        #expect(empty.environment == ["KEEP_ME": "yes"])

        let invalid = PortForwardLaunchConfiguration.make(
            baseEnvironment: inherited,
            mappings: [
                .init(hostPort: 8080, guestPort: 3000, protocol: .tcp),
                .init(hostPort: 0, guestPort: 4000, protocol: .tcp),
            ]
        )
        #expect(invalid.mappings.isEmpty)
        #expect(invalid.environment == ["KEEP_ME": "yes"])
    }
}

@Suite("Port forwarding startup failure")
struct PortForwardStartupFailureTests {
    private let mappings = [
        PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
        PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
    ]

    @Test("identifies the mapping in QEMU's authoritative bind failure")
    func identifiesFailedMapping() {
        let message = PortForwardStartupFailure.message(
            standardError: "qemu: Could not set up host forwarding rule 'udp:127.0.0.1:5353-:5353'",
            mappings: mappings
        )

        #expect(message?.contains("UDP port 5353") == true)
        #expect(message?.contains("Port Forwarding") == true)
    }

    @Test("falls back safely when QEMU omits the matching rule")
    func genericBindFailure() {
        let message = PortForwardStartupFailure.message(
            standardError: "Could not set up host forwarding rule",
            mappings: mappings
        )

        #expect(message == "A configured Mac port couldn’t be opened. Review Port Forwarding and try another Mac port.")
    }

    @Test("does not relabel unrelated startup errors")
    func ignoresUnrelatedErrors() {
        #expect(PortForwardStartupFailure.message(
            standardError: "QEMU exited before creating its private QMP socket",
            mappings: mappings
        ) == nil)
    }
}
