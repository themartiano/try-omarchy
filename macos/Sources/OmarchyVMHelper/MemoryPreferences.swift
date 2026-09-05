import Foundation

/// How much host RAM the guest boots with. The value is a boot-time QEMU
/// setting (`-m`), so a change always applies on the next launch; it is never
/// baked into the guest image or the persistent VM data.
enum MemoryPolicy {
    /// Matches `recommendedMemoryMiB` in the guest runtime manifest, which the
    /// launcher verifies at build time.
    static let defaultMemoryMiB = 4096

    /// Matches `minimumMemoryMiB` in the guest runtime manifest.
    static let minimumMemoryMiB = 2048

    /// The fixed menu of allocations the start menu can offer. A short list
    /// keeps the row a one-click choice instead of a text field that needs
    /// validation feedback.
    static let choicesMiB = [4096, 6144, 8192, 12288, 16384]

    /// A non-default choice is offered only when it leaves the host this much
    /// memory. macOS under ~8 GiB of headroom pushes the host into swapping,
    /// which makes the guest slower, not faster.
    static let hostHeadroomMiB = 8192

    static let environmentKey = "OMARCHY_QEMU_GPU_MEMORY_MIB"

    static func hostMemoryMiB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
    }

    /// The allocations the start menu offers on a host with this much RAM.
    /// The default is always available, so the row never goes empty.
    static func allowedChoicesMiB(hostMemoryMiB: Int) -> [Int] {
        choicesMiB.filter {
            $0 == defaultMemoryMiB || $0 + hostHeadroomMiB <= hostMemoryMiB
        }
    }

    /// The allocation to actually launch with. A stored preference that no
    /// longer fits this host (or was never a listed choice) falls back to the
    /// default instead of failing the launch.
    static func resolvedMemoryMiB(preferredMiB: Int, hostMemoryMiB: Int) -> Int {
        allowedChoicesMiB(hostMemoryMiB: hostMemoryMiB).contains(preferredMiB)
            ? preferredMiB
            : defaultMemoryMiB
    }

    static func displayLabel(memoryMiB: Int) -> String {
        memoryMiB % 1024 == 0
            ? "\(memoryMiB / 1024) GiB"
            : "\(memoryMiB) MiB"
    }
}

struct MemoryPreferences: Equatable {
    var memoryMiB: Int

    static let defaults = Self(memoryMiB: MemoryPolicy.defaultMemoryMiB)
}

struct MemoryPreferenceStore {
    static let key = "memoryPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> MemoryPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .defaults
        }
        return MemoryPreferences(memoryMiB: payload.memoryMiB)
    }

    func save(_ preferences: MemoryPreferences) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            memoryMiB: preferences.memoryMiB
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let memoryMiB: Int
    }
}

struct MemoryLaunchConfiguration: Equatable {
    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: MemoryPreferences,
        hostMemoryMiB: Int
    ) -> Self {
        var environment = baseEnvironment
        environment[MemoryPolicy.environmentKey] = String(
            MemoryPolicy.resolvedMemoryMiB(
                preferredMiB: preferences.memoryMiB,
                hostMemoryMiB: hostMemoryMiB
            )
        )
        return Self(environment: environment)
    }
}
