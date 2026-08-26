import Darwin
import Foundation

/// The single Mac folder that the guest may read and write under its own name.
struct SharedFolderPreference: Equatable {
    var path: String?
    var isEnabled: Bool

    static let disabled = Self(path: nil, isEnabled: false)

    /// The folder the launcher exports, or nil when sharing is off.
    var activePath: String? {
        guard isEnabled, let path, !path.isEmpty else { return nil }
        return path
    }
}

struct SharedFolderPreferenceStore {
    static let key = "sharedFolderPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SharedFolderPreference {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .disabled
        }
        if let path = payload.path, path.isEmpty || !path.hasPrefix("/") {
            return .disabled
        }
        return SharedFolderPreference(path: payload.path, isEnabled: payload.isEnabled && payload.path != nil)
    }

    func save(_ preference: SharedFolderPreference) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            path: preference.path,
            isEnabled: preference.isEnabled
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let path: String?
        let isEnabled: Bool
    }
}

enum SharedFolderPolicyError: LocalizedError, Equatable {
    case notAbsolute
    case unsupportedCharacter
    case missing(String)
    case symbolicLink(String)
    case notOwned(String)
    case systemDirectory(String)
    case homeDirectory
    case libraryDirectory

    var errorDescription: String? {
        switch self {
        case .notAbsolute: "The shared folder must be an absolute path."
        case .unsupportedCharacter: "The shared folder path contains a character QEMU cannot pass through."
        case .missing(let path): "The shared folder no longer exists: \(path)"
        case .symbolicLink(let path): "The shared folder cannot be a symbolic link: \(path)"
        case .notOwned(let path): "The shared folder must belong to you: \(path)"
        case .systemDirectory(let path): "System folders cannot be shared: \(path)"
        case .homeDirectory: "Choose a folder inside your home folder rather than the whole home folder."
        case .libraryDirectory: "The Library folder cannot be shared."
        }
    }
}

/// Mirrors the launcher script's own checks so the start menu can explain a
/// rejected folder before QEMU ever sees it. The guest gains full read/write
/// access as the Mac user, so whole-home and system trees stay off limits.
enum SharedFolderPolicy {
    static let environmentKey = "OMARCHY_QEMU_GPU_SHARED_FOLDER"
    static let systemDirectories: Set<String> = [
        "/", "/Users", "/private", "/private/tmp", "/tmp", "/System", "/Library", "/Applications", "/Volumes",
    ]

    /// Returns the canonical, symlink-resolved path for a valid folder.
    static func validate(
        _ path: String,
        homeDirectory: String,
        fileManager: FileManager = .default
    ) throws -> String {
        guard path.hasPrefix("/") else { throw SharedFolderPolicyError.notAbsolute }
        guard !path.contains("\n"), !path.contains("\r"), !path.contains(","), !path.utf8.contains(0) else {
            throw SharedFolderPolicyError.unsupportedCharacter
        }
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var information = stat()
        guard Darwin.lstat(standardized.path, &information) == 0 else {
            throw SharedFolderPolicyError.missing(standardized.path)
        }
        guard (information.st_mode & S_IFMT) != S_IFLNK else {
            throw SharedFolderPolicyError.symbolicLink(standardized.path)
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            throw SharedFolderPolicyError.missing(standardized.path)
        }
        let canonical = standardized.resolvingSymlinksInPath().path
        guard !canonical.contains(",") else { throw SharedFolderPolicyError.unsupportedCharacter }
        guard !systemDirectories.contains(canonical) else {
            throw SharedFolderPolicyError.systemDirectory(canonical)
        }
        guard information.st_uid == getuid() else {
            throw SharedFolderPolicyError.notOwned(canonical)
        }
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard canonical != home else { throw SharedFolderPolicyError.homeDirectory }
        let library = home + "/Library"
        guard canonical != library, !canonical.hasPrefix(library + "/") else {
            throw SharedFolderPolicyError.libraryDirectory
        }
        return canonical
    }

    /// The name the guest links inside its home directory.
    static func guestLinkName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty || name == "/" ? "Mac" : name
    }

    static func displayPath(_ path: String, homeDirectory: String) -> String {
        if path == homeDirectory {
            return "~"
        }
        if path.hasPrefix(homeDirectory + "/") {
            return "~" + path.dropFirst(homeDirectory.count)
        }
        return path
    }
}

struct SharedFolderLaunchConfiguration: Equatable {
    let sharedFolder: String?
    let environment: [String: String]

    /// Publishes the validated folder to the launcher script, or removes any
    /// inherited value so an environment leak can never share a folder the
    /// user did not pick in this app.
    static func make(
        baseEnvironment: [String: String],
        preference: SharedFolderPreference,
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> Self {
        var environment = baseEnvironment
        environment.removeValue(forKey: SharedFolderPolicy.environmentKey)
        guard let path = preference.activePath else {
            return Self(sharedFolder: nil, environment: environment)
        }
        do {
            let canonical = try SharedFolderPolicy.validate(
                path,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            environment[SharedFolderPolicy.environmentKey] = canonical
            return Self(sharedFolder: canonical, environment: environment)
        } catch {
            fputs("[shared-folder] \(error.localizedDescription); sharing is off for this launch\n", stderr)
            return Self(sharedFolder: nil, environment: environment)
        }
    }
}

/// What the start menu shows for the share row.
struct SharedFolderMenuState: Equatable {
    let path: String?
    let displayPath: String?
    let isEnabled: Bool
    let problem: String?

    static let disabled = Self(path: nil, displayPath: nil, isEnabled: false, problem: nil)

    static func make(
        preference: SharedFolderPreference,
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> Self {
        guard let path = preference.path else { return .disabled }
        var problem: String?
        if preference.isEnabled {
            do {
                _ = try SharedFolderPolicy.validate(path, homeDirectory: homeDirectory, fileManager: fileManager)
            } catch {
                problem = error.localizedDescription
            }
        }
        return Self(
            path: path,
            displayPath: SharedFolderPolicy.displayPath(path, homeDirectory: homeDirectory),
            isEnabled: preference.isEnabled,
            problem: problem
        )
    }
}
