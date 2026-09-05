import Foundation

struct DiskCapacityPreference: Codable, Equatable {
    static let minimumGigabytes = 10
    static let defaultGigabytes = 24
    static let maximumGigabytes = 8_192
    static let bytesPerGigabyte: Int64 = 1_073_741_824

    var gigabytes: Int

    static let `default` = Self(gigabytes: defaultGigabytes)

    var bytes: Int64 {
        Int64(gigabytes) * Self.bytesPerGigabyte
    }

    static func validationError(for gigabytes: Int) -> String? {
        guard gigabytes >= minimumGigabytes else {
            return "The VM disk limit must be at least \(minimumGigabytes) GB."
        }
        guard gigabytes <= maximumGigabytes else {
            return "The VM disk limit cannot exceed \(maximumGigabytes) GB."
        }
        return nil
    }
}

struct DiskCapacityPreferenceStore {
    static let key = "diskCapacityPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DiskCapacityPreference {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion,
              DiskCapacityPreference.validationError(for: payload.gigabytes) == nil
        else {
            return .default
        }
        return DiskCapacityPreference(gigabytes: payload.gigabytes)
    }

    func save(_ preference: DiskCapacityPreference) throws {
        if let problem = DiskCapacityPreference.validationError(for: preference.gigabytes) {
            throw DiskCapacityError.invalid(problem)
        }
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            gigabytes: preference.gigabytes
        )
        defaults.set(try JSONEncoder().encode(payload), forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let gigabytes: Int
    }
}

enum DiskCapacityError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            message
        }
    }
}

struct DiskCapacityLaunchConfiguration: Equatable {
    static let environmentKey = "OMARCHY_QEMU_GPU_DISK_SIZE_GB"

    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preference: DiskCapacityPreference
    ) -> Self {
        var environment = baseEnvironment
        environment[environmentKey] = String(preference.gigabytes)
        return Self(environment: environment)
    }
}
