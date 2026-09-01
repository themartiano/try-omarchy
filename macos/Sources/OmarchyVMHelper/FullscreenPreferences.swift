import Foundation

struct FullscreenPreferences: Equatable {
    var isImmersive: Bool

    static let defaults = Self(isImmersive: true)
}

struct FullscreenPreferenceStore {
    static let key = "fullscreenPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> FullscreenPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .defaults
        }
        return FullscreenPreferences(isImmersive: payload.isImmersive)
    }

    func save(_ preferences: FullscreenPreferences) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            isImmersive: preferences.isImmersive
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let isImmersive: Bool
    }
}

struct FullscreenLaunchConfiguration: Equatable {
    static let immersiveEnvironmentKey = "OMARCHY_QEMU_GPU_IMMERSIVE"

    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: FullscreenPreferences
    ) -> Self {
        var environment = baseEnvironment
        environment.removeValue(forKey: immersiveEnvironmentKey)
        environment[immersiveEnvironmentKey] = preferences.isImmersive ? "1" : "0"
        return Self(environment: environment)
    }
}
