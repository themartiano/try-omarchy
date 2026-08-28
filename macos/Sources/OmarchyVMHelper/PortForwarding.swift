import Darwin
import Foundation

/// The transport protocol QEMU should forward between the Mac and the guest.
enum PortForwardProtocol: String, Codable, CaseIterable, Sendable {
    case tcp
    case udp

    var displayName: String {
        rawValue.uppercased()
    }
}

/// One loopback port on the Mac mapped to a port inside the guest.
struct PortForwardMapping: Codable, Equatable, Hashable, Sendable {
    let hostPort: Int
    let guestPort: Int
    let `protocol`: PortForwardProtocol
}

enum PortForwardPolicyError: LocalizedError, Equatable {
    case invalidHostPort(Int)
    case invalidGuestPort(Int)
    case duplicateHostPort(PortForwardProtocol, Int)
    case tooManyMappings(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .invalidHostPort(let port):
            "The Mac port must be between 1 and 65535 (received \(port))."
        case .invalidGuestPort(let port):
            "The Omarchy port must be between 1 and 65535 (received \(port))."
        case .duplicateHostPort(let transport, let port):
            "Mac \(transport.displayName) port \(port) is already mapped."
        case .tooManyMappings(let maximum):
            "You can add up to \(maximum) port mappings."
        }
    }
}

/// Shared validation and serialization rules for the menu, preferences, and launcher.
enum PortForwardPolicy {
    static let environmentKey = "OMARCHY_QEMU_GPU_PORT_FORWARDS"
    static let guestToHostAddress = "10.0.2.2"
    static let maximumMappings = 32
    static let validPortRange = 1...65_535

    static func validate(_ mapping: PortForwardMapping) throws {
        guard validPortRange.contains(mapping.hostPort) else {
            throw PortForwardPolicyError.invalidHostPort(mapping.hostPort)
        }
        guard validPortRange.contains(mapping.guestPort) else {
            throw PortForwardPolicyError.invalidGuestPort(mapping.guestPort)
        }
    }

    /// Validates a complete ordered set. A host port may be reused only when
    /// the transport protocol differs, matching QEMU's socket semantics.
    static func validate(_ mappings: [PortForwardMapping]) throws {
        guard mappings.count <= maximumMappings else {
            throw PortForwardPolicyError.tooManyMappings(maximum: maximumMappings)
        }

        var occupiedHostPorts = Set<HostPortKey>()
        for mapping in mappings {
            try validate(mapping)
            let key = HostPortKey(protocol: mapping.protocol, port: mapping.hostPort)
            guard occupiedHostPorts.insert(key).inserted else {
                throw PortForwardPolicyError.duplicateHostPort(mapping.protocol, mapping.hostPort)
            }
        }
    }

    /// Returns the strict representation consumed by the launcher script.
    /// Array order is deliberately preserved for stable UI and launch behavior.
    static func encodedEnvironmentValue(for mappings: [PortForwardMapping]) throws -> String? {
        try validate(mappings)
        guard !mappings.isEmpty else { return nil }
        return mappings.map {
            "\($0.protocol.rawValue):\($0.hostPort):\($0.guestPort)"
        }.joined(separator: ";")
    }

    private struct HostPortKey: Hashable {
        let `protocol`: PortForwardProtocol
        let port: Int
    }
}

/// Persists the user's ordered mapping list as one versioned, atomic value.
struct PortForwardingPreferenceStore {
    static let key = "portForwardingPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Unknown, malformed, or policy-invalid data fails closed to no mappings.
    func load() -> [PortForwardMapping] {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion,
              (try? PortForwardPolicy.validate(payload.mappings)) != nil else {
            return []
        }
        return payload.mappings
    }

    /// Invalid edits are rejected without replacing the last valid preference.
    func save(_ mappings: [PortForwardMapping]) throws {
        try PortForwardPolicy.validate(mappings)
        let payload = Payload(schemaVersion: Self.schemaVersion, mappings: mappings)
        defaults.set(try JSONEncoder().encode(payload), forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let mappings: [PortForwardMapping]
    }
}

struct PortForwardLaunchConfiguration: Equatable {
    let mappings: [PortForwardMapping]
    let environment: [String: String]

    /// Strips any inherited forwarding value before considering preferences.
    /// The complete set is emitted only when every mapping is valid.
    static func make(
        baseEnvironment: [String: String],
        mappings: [PortForwardMapping]
    ) -> Self {
        var environment = baseEnvironment
        environment.removeValue(forKey: PortForwardPolicy.environmentKey)

        guard let encoded = try? PortForwardPolicy.encodedEnvironmentValue(for: mappings) else {
            return Self(mappings: [], environment: environment)
        }
        environment[PortForwardPolicy.environmentKey] = encoded
        return Self(mappings: mappings, environment: environment)
    }
}

enum PortForwardAvailabilityError: LocalizedError, Equatable {
    case unavailable(PortForwardProtocol, Int)

    var errorDescription: String? {
        switch self {
        case .unavailable(let protocolValue, let port):
            "Mac \(protocolValue.displayName) port \(port) isn’t available. Another app may already be using it. Choose another Mac port in Port Forwarding and try again."
        }
    }
}

/// Converts QEMU's authoritative host-forward bind failure into a recovery
/// message that keeps the start menu open after the small preflight race.
enum PortForwardStartupFailure {
    private static let qemuBindFailure = "could not set up host forwarding rule"

    static func message(
        standardError: String,
        mappings: [PortForwardMapping]
    ) -> String? {
        guard standardError.localizedCaseInsensitiveContains(qemuBindFailure) else {
            return nil
        }

        if let mapping = mappings.first(where: { mapping in
            standardError.contains(
                "\(mapping.protocol.rawValue):127.0.0.1:\(mapping.hostPort)-"
            )
        }) {
            return "Mac \(mapping.protocol.displayName) port \(mapping.hostPort) couldn’t be opened. Another app may have started using it. Choose another Mac port in Port Forwarding and try again."
        }

        return "A configured Mac port couldn’t be opened. Review Port Forwarding and try another Mac port."
    }
}

/// Gives an immediate, actionable error for the common startup failure where
/// another Mac app already owns a requested loopback port. QEMU still performs
/// the authoritative bind moments later; this preflight exists for better UX.
enum PortForwardAvailability {
    static func validate(_ mappings: [PortForwardMapping]) throws {
        try PortForwardPolicy.validate(mappings)
        for mapping in mappings where !canBind(mapping) {
            throw PortForwardAvailabilityError.unavailable(mapping.protocol, mapping.hostPort)
        }
    }

    private static func canBind(_ mapping: PortForwardMapping) -> Bool {
        let socketType: Int32
        switch mapping.protocol {
        case .tcp:
            socketType = SOCK_STREAM
        case .udp:
            socketType = SOCK_DGRAM
        }
        let descriptor = Darwin.socket(AF_INET, socketType, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(mapping.hostPort).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
    }
}
