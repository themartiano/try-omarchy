import Darwin
import Foundation

/// Where the persistent VM workspace lives.
///
/// `containerPath` is the folder the user picked, used directly as the
/// workspace root — Omarchy never creates a folder inside it on the user's
/// behalf. A folder must already be empty, or already be a workspace Omarchy
/// has used before, to be accepted; anything else is rejected with an
/// explanation rather than silently restructured. `nil` means the default
/// location under Application Support.
struct StorageLocationPreference: Equatable {
    var containerPath: String?

    static let `default` = Self(containerPath: nil)

    var isDefault: Bool { containerPath == nil }
}

struct StorageLocationPreferenceStore {
    static let key = "storageLocationPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> StorageLocationPreference {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .default
        }
        if let path = payload.containerPath, path.isEmpty || !path.hasPrefix("/") {
            return .default
        }
        return StorageLocationPreference(containerPath: payload.containerPath)
    }

    func save(_ preference: StorageLocationPreference) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            containerPath: preference.containerPath
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let containerPath: String?
    }
}

/// The identity and disk sizes `build-app.sh` signs into
/// `Resources/guest/launch.plist`. The app needs them to say how much room a
/// chosen volume must have before the launcher tries to use it.
struct BundledGuestMetrics: Equatable {
    var identity: String
    var sourceDiskBytes: Int64
    var workingDiskBytes: Int64
}

/// How much room the workspace needs on the chosen volume.
///
/// The factory source is a real multi-gigabyte file, written once per guest
/// build. The working disk is an APFS clone of it that is then expanded
/// sparsely, so it costs almost nothing at creation and grows only as the
/// guest writes. That is why the floor and the comfort target differ so much.
struct StorageSpaceRequirement: Equatable {
    var sourceBytes: Int64
    var workingBytes: Int64
    /// True when this volume already holds the materialized factory source for
    /// the current guest build, which is therefore already paid for.
    var sourceAlreadyPresent: Bool

    static let headroomBytes: Int64 = 1_073_741_824

    private var unpaidSourceBytes: Int64 {
        sourceAlreadyPresent ? 0 : sourceBytes
    }

    /// Below this the workspace cannot even be created.
    var floorBytes: Int64 {
        unpaidSourceBytes + Self.headroomBytes
    }

    /// Below this the VM starts but the guest can run out of room later.
    var comfortBytes: Int64 {
        unpaidSourceBytes + workingBytes
    }
}

enum StorageLocationPolicyError: LocalizedError, Equatable {
    case notAbsolute
    case unsupportedCharacter
    case missing(String)
    case symbolicLink(String)
    case notDirectory(String)
    case notOwned(String)
    case unsafeRoot(String)
    case isVolumeRoot(String)
    case notEmpty(String)
    case alreadyAWorkspace(String)
    case isCurrentWorkspace(String)
    case invalidWorkspaceMarker(String)
    case volumeUnreadable(String)
    case notLocalVolume(String)
    case unsupportedFilesystem(filesystem: String, volume: String)
    case insufficientSpace(volume: String, needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .notAbsolute:
            "The Omarchy data folder must be an absolute path."
        case .unsupportedCharacter:
            "That folder path contains a character the launcher cannot pass through."
        case .missing(let path):
            "That folder no longer exists: \(path)"
        case .symbolicLink(let path):
            "The Omarchy data folder cannot be a symbolic link: \(path)"
        case .notDirectory(let path):
            "Choose a folder rather than a file: \(path)"
        case .notOwned(let path):
            "The Omarchy data folder must belong to you: \(path)"
        case .unsafeRoot(let path):
            "That location is too broad to hold the Omarchy VM: \(path)"
        case .isVolumeRoot(let path):
            "Choose a folder inside \(path), not the drive itself. For example, create a folder named \"\(StorageLocationPolicy.workspaceDirectoryName)\" there and pick that."
        case .notEmpty(let path):
            "This folder already has files in it: \(path). Omarchy only uses an empty folder, so it never mixes its virtual machine with anything else stored there. Choose or create an empty folder instead."
        case .alreadyAWorkspace(let path):
            "That folder is already an Omarchy workspace: \(path). Choose an empty folder so the backup is not mixed with another VM."
        case .isCurrentWorkspace(let path):
            "Choose a different folder. That one is the live Omarchy VM: \(path)."
        case .invalidWorkspaceMarker(let path):
            "This folder looks like an Omarchy workspace, but its \"\(StorageLocationPolicy.rootMarkerName)\" file is damaged, so the VM here cannot be opened safely: \(path). Delete that file to reuse the folder as an empty one, or choose a different folder."
        case .volumeUnreadable(let path):
            "Try Omarchy could not read the disk that holds \(path)."
        case .notLocalVolume(let volume):
            "\(volume) is a network volume. Omarchy needs a local APFS disk so it can lock the VM safely."
        case .unsupportedFilesystem(let filesystem, let volume):
            "\(volume) is formatted as \(filesystem.uppercased()). Omarchy needs an APFS disk: the VM disk grows as you use it, and other formats would claim its full size right away."
        case .insufficientSpace(let volume, let needed, let available):
            "\(volume) has \(StorageLocationPolicy.format(bytes: available)) free. Omarchy needs at least \(StorageLocationPolicy.format(bytes: needed)) to create the VM."
        }
    }
}

/// A validated choice: the folder the user picked, the workspace inside it, and
/// anything worth telling them before they commit.
struct StorageLocationResolution: Equatable {
    var containerPath: String
    var stateRoot: String
    var capabilities: VolumeCapabilities
    /// Set when the volume clears the floor but not the comfort target.
    var spaceWarning: String?
}

/// Mirrors the launcher's own state-root checks so the start menu can explain a
/// rejected folder before QEMU ever sees it, and adds the two guards the shell
/// library cannot express cheaply: the filesystem must be APFS, and there must
/// be room for the factory image.
enum StorageLocationPolicy {
    static let environmentKey = "OMARCHY_QEMU_GPU_STATE_ROOT"
    static let workspaceDirectoryName = "Try Omarchy"
    static let rootMarkerName = ".omarchy-qemu-storage"

    /// The marker's only valid contents. Kept byte-identical to
    /// `QEMU_PERSISTENT_STORAGE_ROOT_MARKER` in qemu-persistent-storage.sh,
    /// which is the side that writes it. Change one and you must change both;
    /// StorageLocationContractTests pins them together.
    static let rootMarkerContent = "omarchy-qemu-storage-root-v1"

    /// Kept byte-identical to `validatedConfiguredRoot` in QEMUGPULauncher.swift
    /// and `_qps_assert_safe_root_path` in qemu-persistent-storage.sh. Change
    /// one and you must change all three.
    static let unsafeRoots: Set<String> = ["/", "/Users", "/private", "/private/tmp", "/tmp"]

    /// Normalizes a chosen container path. The container itself is always the
    /// workspace root — `validate` below is what decides whether a container
    /// is acceptable, not this function.
    static func stateRoot(forContainer path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// Finder- or filesystem-owned entries that don't count as real content
    /// when deciding whether a picked folder is empty enough to use directly.
    private static let ignorableEntries: Set<String> = [".DS_Store", ".localized", "Icon\r", rootMarkerName]

    /// Whether the marker is one this app would itself have written.
    ///
    /// Mirrors `_qps_validate_root_marker` plus `_qps_assert_private_regular_file`
    /// in qemu-persistent-storage.sh exactly. Checking only that *something*
    /// named `.omarchy-qemu-storage` exists would let the picker accept a folder
    /// the launcher then refuses, moving the failure from a message the user can
    /// act on to one the shell script prints mid-launch.
    static func hasValidRootMarker(in container: URL) -> Bool {
        let marker = container.appendingPathComponent(rootMarkerName, isDirectory: false)

        var information = stat()
        guard Darwin.lstat(marker.path, &information) == 0 else { return false }
        guard (information.st_mode & S_IFMT) == S_IFREG else { return false }
        guard information.st_uid == getuid() else { return false }
        // `_qps_permissions` is `stat -f '%Lp'`, which reports only the nine
        // permission bits — a setuid marker prints 600 there — so masking with
        // 0o777 is the exact mirror, not a laxer one.
        guard (information.st_mode & 0o777) == 0o600 else { return false }

        guard let data = try? Data(contentsOf: marker),
              let contents = String(data: data, encoding: .utf8) else { return false }
        // Command substitution strips trailing newlines and nothing else, so a
        // marker that *starts* with one is content the shell would reject.
        // Trimming both ends here would accept it and defer the failure to
        // launch, which is the mismatch this check exists to prevent.
        var body = Substring(contents)
        while body.hasSuffix("\n") { body = body.dropLast() }
        return body == rootMarkerContent
    }

    /// Whether anything at all occupies the marker path, valid or not. A folder
    /// carrying a damaged marker must be rejected outright rather than falling
    /// through to the emptiness check, which ignores the marker name and would
    /// wave the folder through with a misleading explanation.
    private static func hasRootMarkerEntry(in container: URL) -> Bool {
        let marker = container.appendingPathComponent(rootMarkerName, isDirectory: false)
        var information = stat()
        return Darwin.lstat(marker.path, &information) == 0
    }

    private static func isEffectivelyEmpty(_ container: URL, fileManager: FileManager) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        return entries.allSatisfy { ignorableEntries.contains($0.lastPathComponent) }
    }

    /// Whether a chosen folder may already be an Omarchy workspace.
    enum WorkspaceAcceptance: Equatable {
        /// Empty folder, or one this app has already used.
        case emptyOrExisting
        /// Empty folder only. Existing workspaces are refused so a backup
        /// cannot mix with, or overwrite, another VM.
        case emptyOnly
    }

    static func validate(
        _ path: String,
        metrics: BundledGuestMetrics?,
        probe: VolumeProbing,
        volumeRootDetector: VolumeRootDetecting = FileManagerVolumeRootDetector(),
        fileManager: FileManager = .default,
        workspaceAcceptance: WorkspaceAcceptance = .emptyOrExisting,
        currentStateRoot: String? = nil
    ) throws -> StorageLocationResolution {
        guard path.hasPrefix("/") else { throw StorageLocationPolicyError.notAbsolute }
        guard !path.contains("\n"), !path.contains("\r"), !path.utf8.contains(0) else {
            throw StorageLocationPolicyError.unsupportedCharacter
        }

        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var information = stat()
        guard Darwin.lstat(standardized.path, &information) == 0 else {
            throw StorageLocationPolicyError.missing(standardized.path)
        }
        guard (information.st_mode & S_IFMT) != S_IFLNK else {
            throw StorageLocationPolicyError.symbolicLink(standardized.path)
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            throw StorageLocationPolicyError.notDirectory(standardized.path)
        }

        // Breadth is checked before ownership, as SharedFolderPolicy does, so a
        // system directory reports what is actually wrong with it rather than
        // complaining that root owns it.
        let container = standardized.resolvingSymlinksInPath().path
        guard !unsafeRoots.contains(container) else {
            throw StorageLocationPolicyError.unsafeRoot(container)
        }
        guard information.st_uid == getuid() else {
            throw StorageLocationPolicyError.notOwned(container)
        }

        let containerURL = URL(fileURLWithPath: container, isDirectory: true)
        let root = stateRoot(forContainer: container)
        if let currentStateRoot, !currentStateRoot.isEmpty {
            let currentRoot = URL(fileURLWithPath: currentStateRoot, isDirectory: true)
                .standardizedFileURL.path
            if root == currentRoot {
                throw StorageLocationPolicyError.isCurrentWorkspace(root)
            }
        }

        let isExistingWorkspace = hasValidRootMarker(in: containerURL)
        if workspaceAcceptance == .emptyOnly, isExistingWorkspace {
            throw StorageLocationPolicyError.alreadyAWorkspace(container)
        }
        if !isExistingWorkspace, hasRootMarkerEntry(in: containerURL) {
            // The launcher would refuse this folder too, but only after the user
            // committed to it. Say so now, while they can still pick another.
            throw StorageLocationPolicyError.invalidWorkspaceMarker(container)
        }
        if !isExistingWorkspace {
            // Never restructure a folder the user picked: use it exactly as
            // given, or explain why not and let them pick again. A bare
            // volume root is refused even when empty — writing our files
            // directly onto a drive's top level is the one case nesting used
            // to exist to prevent.
            guard !volumeRootDetector.isVolumeRoot(containerURL) else {
                throw StorageLocationPolicyError.isVolumeRoot(container)
            }
            guard isEffectivelyEmpty(containerURL, fileManager: fileManager) else {
                throw StorageLocationPolicyError.notEmpty(container)
            }
        }

        let capabilities: VolumeCapabilities
        do {
            capabilities = try probe.capabilities(at: URL(fileURLWithPath: container, isDirectory: true))
        } catch {
            throw StorageLocationPolicyError.volumeUnreadable(container)
        }
        let volumeLabel = capabilities.volumeName ?? container
        guard capabilities.isLocal else {
            throw StorageLocationPolicyError.notLocalVolume(volumeLabel)
        }
        guard capabilities.supportsPersistentDisk else {
            throw StorageLocationPolicyError.unsupportedFilesystem(
                filesystem: capabilities.typeName,
                volume: volumeLabel
            )
        }

        var warning: String?
        if let metrics {
            let requirement = StorageSpaceRequirement(
                sourceBytes: metrics.sourceDiskBytes,
                workingBytes: metrics.workingDiskBytes,
                sourceAlreadyPresent: hasMaterializedSource(
                    stateRoot: root,
                    identity: metrics.identity,
                    fileManager: fileManager
                )
            )
            guard capabilities.availableBytes >= requirement.floorBytes else {
                throw StorageLocationPolicyError.insufficientSpace(
                    volume: volumeLabel,
                    needed: requirement.floorBytes,
                    available: capabilities.availableBytes
                )
            }
            if capabilities.availableBytes < requirement.comfortBytes {
                warning = "\(volumeLabel) has \(format(bytes: capabilities.availableBytes)) free. The VM disk grows as you use it and can need up to \(format(bytes: requirement.comfortBytes))."
            }
        }

        return StorageLocationResolution(
            containerPath: container,
            stateRoot: root,
            capabilities: capabilities,
            spaceWarning: warning
        )
    }

    /// An empty APFS folder that can receive a copy of the live VM.
    ///
    /// Existing workspaces are refused: a backup must not mix with, or
    /// overwrite, another VM. The live workspace is refused for the same
    /// reason. Factory-image space is not demanded here — backup copies the
    /// working disk, not a new guest build.
    static func validateBackupDestination(
        _ path: String,
        currentStateRoot: String?,
        probe: VolumeProbing,
        volumeRootDetector: VolumeRootDetecting = FileManagerVolumeRootDetector(),
        fileManager: FileManager = .default
    ) throws -> StorageLocationResolution {
        try validate(
            path,
            metrics: nil,
            probe: probe,
            volumeRootDetector: volumeRootDetector,
            fileManager: fileManager,
            workspaceAcceptance: .emptyOnly,
            currentStateRoot: currentStateRoot
        )
    }

    /// True when the factory source for this guest build is already written to
    /// the workspace, so its bytes must not be demanded a second time.
    static func hasMaterializedSource(
        stateRoot: String,
        identity: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let source = URL(fileURLWithPath: stateRoot, isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("\(identity).ext4", isDirectory: false)
        return fileManager.fileExists(atPath: source.path)
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

    /// Always renders something, unlike the reclaimable-space formatter, which
    /// returns nil when there is nothing worth reporting.
    static func format(bytes: Int64) -> String {
        guard bytes > 0 else { return "0 GB" }
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes < 0.1 {
            return "less than 0.1 GB"
        }
        return String(format: "%.1f GB", gigabytes)
    }
}

struct StorageLocationLaunchConfiguration: Equatable {
    let stateRoot: String?
    let environment: [String: String]

    /// Why the stored choice could not be honored, when there was one.
    ///
    /// A chosen folder that fails validation must never quietly become the
    /// default: reset would then erase the default workspace while reporting
    /// success, and the VM the user meant to act on would sit untouched on a
    /// drive that is not plugged in. Callers refuse to start the launcher while
    /// this is set, so the fallback cannot happen behind the user's back.
    let unavailableReason: String?

    /// Publishes the chosen workspace to the launcher script.
    ///
    /// Unlike the shared folder, an inherited value is *kept*:
    /// `OMARCHY_QEMU_GPU_STATE_ROOT` is the documented development and test
    /// override, and the storage suite drives the whole library through it. A
    /// leaked value here only relocates VM data, so the override wins over the
    /// stored preference rather than being stripped for safety.
    static func make(
        baseEnvironment: [String: String],
        preference: StorageLocationPreference,
        metrics: BundledGuestMetrics?,
        probe: VolumeProbing = URLVolumeProbe(),
        volumeRootDetector: VolumeRootDetecting = FileManagerVolumeRootDetector(),
        fileManager: FileManager = .default
    ) -> Self {
        if let inherited = baseEnvironment[StorageLocationPolicy.environmentKey], !inherited.isEmpty {
            return Self(stateRoot: inherited, environment: baseEnvironment, unavailableReason: nil)
        }
        var environment = baseEnvironment
        guard let container = preference.containerPath else {
            return Self(stateRoot: nil, environment: environment, unavailableReason: nil)
        }
        do {
            let resolution = try StorageLocationPolicy.validate(
                container,
                metrics: metrics,
                probe: probe,
                volumeRootDetector: volumeRootDetector,
                fileManager: fileManager
            )
            environment[StorageLocationPolicy.environmentKey] = resolution.stateRoot
            return Self(stateRoot: resolution.stateRoot, environment: environment, unavailableReason: nil)
        } catch {
            fputs("[storage] \(error.localizedDescription); refusing to fall back to the default data folder\n", stderr)
            return Self(
                stateRoot: nil,
                environment: environment,
                unavailableReason: error.localizedDescription
            )
        }
    }
}

/// What the start menu shows for the data-location row.
struct StorageLocationMenuState: Equatable {
    let containerPath: String?
    let stateRoot: String?
    let displayPath: String?
    let volumeName: String?
    let isDefault: Bool
    let isExternal: Bool
    let problem: String?
    let warning: String?
    /// True when OMARCHY_QEMU_GPU_STATE_ROOT decided this location, overriding
    /// whatever the user picked. The menu must report the workspace a launch or
    /// reset will actually act on, not the one merely stored in preferences.
    let isEnvironmentOverride: Bool

    static let defaultLocation = Self(
        containerPath: nil,
        stateRoot: nil,
        displayPath: nil,
        volumeName: nil,
        isDefault: true,
        isExternal: false,
        problem: nil,
        warning: nil,
        isEnvironmentOverride: false
    )

    /// The workspace an override points at.
    ///
    /// The override is the documented development and test escape hatch and it
    /// beats the stored preference in `StorageLocationLaunchConfiguration`, so
    /// the launcher — not this policy — owns validating it. Reporting it
    /// unvalidated is deliberate: the alternative is a confirmation sheet that
    /// names one workspace while reset erases another.
    static func overriding(
        stateRoot: String,
        homeDirectory: String
    ) -> Self {
        Self(
            containerPath: stateRoot,
            stateRoot: stateRoot,
            displayPath: StorageLocationPolicy.displayPath(
                stateRoot,
                homeDirectory: homeDirectory
            ),
            volumeName: nil,
            isDefault: false,
            isExternal: false,
            problem: nil,
            warning: nil,
            isEnvironmentOverride: true
        )
    }

    static func make(
        preference: StorageLocationPreference,
        metrics: BundledGuestMetrics?,
        homeDirectory: String,
        environmentOverride: String? = nil,
        probe: VolumeProbing = URLVolumeProbe(),
        volumeRootDetector: VolumeRootDetecting = FileManagerVolumeRootDetector(),
        fileManager: FileManager = .default
    ) -> Self {
        if let environmentOverride, !environmentOverride.isEmpty {
            return .overriding(stateRoot: environmentOverride, homeDirectory: homeDirectory)
        }
        guard let container = preference.containerPath else { return .defaultLocation }
        do {
            let resolution = try StorageLocationPolicy.validate(
                container,
                metrics: metrics,
                probe: probe,
                volumeRootDetector: volumeRootDetector,
                fileManager: fileManager
            )
            return Self(
                containerPath: resolution.containerPath,
                stateRoot: resolution.stateRoot,
                displayPath: StorageLocationPolicy.displayPath(
                    resolution.stateRoot,
                    homeDirectory: homeDirectory
                ),
                volumeName: resolution.capabilities.volumeName,
                isDefault: false,
                isExternal: !resolution.capabilities.isInternal,
                problem: nil,
                warning: resolution.spaceWarning,
                isEnvironmentOverride: false
            )
        } catch {
            return Self(
                containerPath: container,
                stateRoot: nil,
                displayPath: StorageLocationPolicy.displayPath(
                    container,
                    homeDirectory: homeDirectory
                ),
                volumeName: nil,
                isDefault: false,
                isExternal: false,
                problem: error.localizedDescription,
                warning: nil,
                isEnvironmentOverride: false
            )
        }
    }
}
