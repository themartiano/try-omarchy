import Foundation
import Testing
@testable import OmarchyVMHelper

private struct FakeVolumeProbe: VolumeProbing {
    var result: VolumeCapabilities
    var failure: Error?

    func capabilities(at url: URL) throws -> VolumeCapabilities {
        if let failure { throw failure }
        return result
    }
}

private struct FakeVolumeRootDetector: VolumeRootDetecting {
    var result: Bool

    func isVolumeRoot(_ url: URL) -> Bool { result }
}

private func volume(
    typeName: String = "apfs",
    name: String? = "Test Drive",
    cloning: Bool = true,
    sparse: Bool = true,
    isLocal: Bool = true,
    isInternal: Bool = false,
    available: Int64 = 500_000_000_000
) -> VolumeCapabilities {
    VolumeCapabilities(
        typeName: typeName,
        volumeName: name,
        supportsCloning: cloning,
        supportsSparseFiles: sparse,
        isLocal: isLocal,
        isInternal: isInternal,
        availableBytes: available
    )
}

private let sourceBytes: Int64 = 6_442_450_944
private let workingBytes: Int64 = 25_769_803_776

private let metrics = BundledGuestMetrics(
    identity: String(repeating: "a", count: 64),
    sourceDiskBytes: sourceBytes,
    workingDiskBytes: workingBytes
)

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("omarchy-storage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.standardizedFileURL.resolvingSymlinksInPath()
}

/// Writes the marker exactly as `_qps_write_root_marker` does: the token, one
/// trailing newline, mode 0600. Fixtures must use this rather than an empty
/// file — the launcher rejects anything else, so an empty marker would make a
/// test pass on a folder the real app cannot use.
@discardableResult
private func writeValidRootMarker(in container: URL) throws -> URL {
    let marker = container.appendingPathComponent(
        StorageLocationPolicy.rootMarkerName,
        isDirectory: false
    )
    try Data("\(StorageLocationPolicy.rootMarkerContent)\n".utf8).write(to: marker)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    return marker
}

@Suite("Storage location policy")
struct StorageLocationPolicyTests {
    @Test("accepts an owned, empty APFS folder and uses it directly")
    func acceptsOwnedAPFSFolder() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let resolution = try StorageLocationPolicy.validate(
            container.path,
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume())
        )
        #expect(resolution.containerPath == container.path)
        #expect(resolution.stateRoot == container.path)
        #expect(resolution.spaceWarning == nil)
    }

    @Test("Finder cruft does not count as content — the folder is still used directly")
    func finderCruftDoesNotCountAsContent() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        try Data().write(to: container.appendingPathComponent(".DS_Store"))

        let resolution = try StorageLocationPolicy.validate(
            container.path,
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume())
        )
        #expect(resolution.stateRoot == container.path)
    }

    @Test("rejects a folder that already has unrelated content instead of nesting inside it")
    func rejectsNonEmptyFolder() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        try Data().write(to: container.appendingPathComponent("notes.txt"))

        #expect(throws: StorageLocationPolicyError.notEmpty(container.path)) {
            try StorageLocationPolicy.validate(
                container.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume())
            )
        }
    }

    @Test("rejects a bare volume root even when it is empty")
    func rejectsVolumeRoot() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(throws: StorageLocationPolicyError.isVolumeRoot(container.path)) {
            try StorageLocationPolicy.validate(
                container.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume()),
                volumeRootDetector: FakeVolumeRootDetector(result: true)
            )
        }
    }

    @Test("re-picking an existing workspace does not nest a second one inside it")
    func reselectingAWorkspaceKeepsIt() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        try writeValidRootMarker(in: container)

        let resolution = try StorageLocationPolicy.validate(
            container.path,
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume())
        )
        #expect(resolution.stateRoot == container.path)
    }

    /// Each of these is a marker the launcher's `_qps_validate_root_marker`
    /// refuses. The picker must refuse them too, or it hands the user a folder
    /// that only fails once QEMU is already starting.
    @Test(
        "a damaged workspace marker is refused in the picker, not at launch",
        arguments: [
            "empty",
            "wrong content",
            "wrong mode",
            "directory",
            "symlink",
        ]
    )
    func rejectsDamagedWorkspaceMarker(kind: String) throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let marker = container.appendingPathComponent(
            StorageLocationPolicy.rootMarkerName,
            isDirectory: false
        )

        switch kind {
        case "empty":
            try Data().write(to: marker)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: marker.path
            )
        case "wrong content":
            try Data("omarchy-qemu-storage-root-v2\n".utf8).write(to: marker)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: marker.path
            )
        case "wrong mode":
            // A marker restored from a backup or copied by Finder lands as 0644.
            try writeValidRootMarker(in: container)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: marker.path
            )
        case "directory":
            try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        default:
            let target = container.appendingPathComponent("elsewhere", isDirectory: false)
            try Data("\(StorageLocationPolicy.rootMarkerContent)\n".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
        }

        #expect(throws: StorageLocationPolicyError.invalidWorkspaceMarker(container.path)) {
            try StorageLocationPolicy.validate(
                container.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume())
            )
        }
    }

    @Test("a damaged marker does not smuggle a volume root past the picker")
    func damagedMarkerDoesNotBypassVolumeRootCheck() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        try Data().write(to: container.appendingPathComponent(StorageLocationPolicy.rootMarkerName))

        // A valid marker skips both the volume-root and emptiness guards; an
        // invalid one must not inherit that exemption.
        #expect(throws: StorageLocationPolicyError.invalidWorkspaceMarker(container.path)) {
            try StorageLocationPolicy.validate(
                container.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume()),
                volumeRootDetector: FakeVolumeRootDetector(result: true)
            )
        }
    }

    @Test("rejects a relative path")
    func rejectsRelativePath() {
        #expect(throws: StorageLocationPolicyError.notAbsolute) {
            try StorageLocationPolicy.validate(
                "Volumes/Data",
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume())
            )
        }
    }

    @Test("rejects roots too broad to hold a VM", arguments: ["/", "/Users", "/private"])
    func rejectsUnsafeRoots(path: String) {
        #expect(throws: StorageLocationPolicyError.unsafeRoot(path)) {
            try StorageLocationPolicy.validate(
                path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume())
            )
        }
    }

    @Test("rejects a symbolic link")
    func rejectsSymbolicLink() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: StorageLocationPolicyError.symbolicLink(link.path)) {
            try StorageLocationPolicy.validate(
                link.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume())
            )
        }
    }

    @Test("rejects a path that does not exist")
    func rejectsMissingPath() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let missing = parent.appendingPathComponent("absent", isDirectory: true)

        #expect(throws: StorageLocationPolicyError.missing(missing.path)) {
            try StorageLocationPolicy.validate(
                missing.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume())
            )
        }
    }

    @Test("rejects a file")
    func rejectsFile() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("disk.img", isDirectory: false)
        try Data().write(to: file)

        #expect(throws: StorageLocationPolicyError.notDirectory(file.path)) {
            try StorageLocationPolicy.validate(
                file.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume())
            )
        }
    }

    @Test("rejects a filesystem that cannot hold the workspace and names it")
    func rejectsUnsupportedFilesystem() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        // exFAT cannot store sparse files, so the working disk would claim its
        // full size the moment it was created. Refuse at selection time.
        let probe = FakeVolumeProbe(
            result: volume(typeName: "exfat", name: "STICK", cloning: false, sparse: false)
        )
        let error = #expect(throws: StorageLocationPolicyError.self) {
            try StorageLocationPolicy.validate(container.path, metrics: metrics, probe: probe)
        }
        #expect(error == .unsupportedFilesystem(filesystem: "exfat", volume: "STICK"))
        #expect(error?.errorDescription?.contains("EXFAT") == true)
    }

    @Test("rejects APFS that cannot clone or store sparse files")
    func rejectsCrippledAPFS() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(throws: StorageLocationPolicyError.self) {
            try StorageLocationPolicy.validate(
                container.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume(sparse: false))
            )
        }
    }

    @Test("rejects a network volume because the disk lock would be unreliable")
    func rejectsNetworkVolume() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(throws: StorageLocationPolicyError.notLocalVolume("Share")) {
            try StorageLocationPolicy.validate(
                container.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume(name: "Share", isLocal: false))
            )
        }
    }

    @Test("rejects a volume that cannot fit the factory image")
    func rejectsInsufficientSpace() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let error = #expect(throws: StorageLocationPolicyError.self) {
            try StorageLocationPolicy.validate(
                container.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume(available: 2_000_000_000))
            )
        }
        guard case .insufficientSpace = error else {
            Issue.record("expected an insufficient-space rejection, got \(String(describing: error))")
            return
        }
    }

    @Test("accepts with a warning between the floor and the comfort target")
    func warnsWhenRoomIsTight() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let requirement = StorageSpaceRequirement(
            sourceBytes: sourceBytes,
            workingBytes: workingBytes,
            sourceAlreadyPresent: false
        )
        let available = (requirement.floorBytes + requirement.comfortBytes) / 2
        let resolution = try StorageLocationPolicy.validate(
            container.path,
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume(available: available))
        )
        #expect(resolution.spaceWarning != nil)
    }

    @Test("an already-materialized factory image is not charged for twice")
    func materializedSourceLowersTheFloor() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        // Below the floor while the source is still unpaid for.
        let tight = sourceBytes
        #expect(throws: StorageLocationPolicyError.self) {
            try StorageLocationPolicy.validate(
                container.path,
                metrics: metrics,
                probe: FakeVolumeProbe(result: volume(available: tight))
            )
        }

        // The marker is always written before `images/` gains content — see
        // `_qps_prepare_state_root` in qemu-persistent-storage.sh — so a
        // realistic "already materialized" fixture carries both.
        try writeValidRootMarker(in: container)
        let images = container.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data().write(to: images.appendingPathComponent("\(metrics.identity).ext4"))

        let resolution = try StorageLocationPolicy.validate(
            container.path,
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume(available: tight))
        )
        #expect(resolution.stateRoot == container.path)
    }

    @Test("skips the space check when the bundle metrics are unavailable")
    func toleratesMissingMetrics() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let resolution = try StorageLocationPolicy.validate(
            container.path,
            metrics: nil,
            probe: FakeVolumeProbe(result: volume(available: 1))
        )
        #expect(resolution.spaceWarning == nil)
    }

    @Test("reports a volume it cannot read rather than assuming it is usable")
    func reportsUnreadableVolume() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(throws: StorageLocationPolicyError.volumeUnreadable(container.path)) {
            try StorageLocationPolicy.validate(
                container.path,
                metrics: metrics,
                probe: FakeVolumeProbe(
                    result: volume(),
                    failure: VolumeProbeError.unreadable(container.path)
                )
            )
        }
    }
}

@Suite("Storage space requirement")
struct StorageSpaceRequirementTests {
    @Test("the floor covers the factory image plus headroom")
    func floorCoversTheFactoryImage() {
        let requirement = StorageSpaceRequirement(
            sourceBytes: sourceBytes,
            workingBytes: workingBytes,
            sourceAlreadyPresent: false
        )
        #expect(requirement.floorBytes == sourceBytes + StorageSpaceRequirement.headroomBytes)
        #expect(requirement.comfortBytes == sourceBytes + workingBytes)
    }

    @Test("a materialized image leaves only the headroom to find")
    func materializedImageLeavesHeadroom() {
        let requirement = StorageSpaceRequirement(
            sourceBytes: sourceBytes,
            workingBytes: workingBytes,
            sourceAlreadyPresent: true
        )
        #expect(requirement.floorBytes == StorageSpaceRequirement.headroomBytes)
        #expect(requirement.comfortBytes == workingBytes)
    }
}

@Suite("Storage location preferences")
struct StorageLocationPreferenceStoreTests {
    private func store() throws -> (StorageLocationPreferenceStore, UserDefaults, String) {
        let name = "omarchy-storage-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (StorageLocationPreferenceStore(defaults: defaults), defaults, name)
    }

    @Test("round-trips a chosen container")
    func roundTrips() throws {
        let (subject, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }

        subject.save(StorageLocationPreference(containerPath: "/Volumes/Data"))
        #expect(subject.load() == StorageLocationPreference(containerPath: "/Volumes/Data"))
        #expect(subject.load().isDefault == false)
    }

    @Test("an absent preference is the default location")
    func absentPreferenceIsDefault() throws {
        let (subject, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(subject.load() == .default)
        #expect(subject.load().isDefault)
    }

    @Test("a future schema falls back to the default without rewriting")
    func futureSchemaFallsBack() throws {
        let (subject, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }

        let payload = #"{"schemaVersion":99,"containerPath":"/Volumes/Data"}"#
        defaults.set(Data(payload.utf8), forKey: StorageLocationPreferenceStore.key)
        #expect(subject.load() == .default)
        #expect(defaults.data(forKey: StorageLocationPreferenceStore.key) != nil)
    }

    @Test("a relative stored path is discarded")
    func relativeStoredPathIsDiscarded() throws {
        let (subject, defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }

        let payload = #"{"schemaVersion":1,"containerPath":"Volumes/Data"}"#
        defaults.set(Data(payload.utf8), forKey: StorageLocationPreferenceStore.key)
        #expect(subject.load() == .default)
    }
}

@Suite("Storage location launch configuration")
struct StorageLocationLaunchConfigurationTests {
    @Test("the development override wins over a stored preference")
    func environmentOverrideWins() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let configuration = StorageLocationLaunchConfiguration.make(
            baseEnvironment: [StorageLocationPolicy.environmentKey: "/tmp/override-root"],
            preference: StorageLocationPreference(containerPath: container.path),
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume())
        )
        #expect(configuration.stateRoot == "/tmp/override-root")
        #expect(configuration.environment[StorageLocationPolicy.environmentKey] == "/tmp/override-root")
    }

    @Test("a valid preference is published to the launcher")
    func publishesValidPreference() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let configuration = StorageLocationLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: StorageLocationPreference(containerPath: container.path),
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume())
        )
        #expect(configuration.stateRoot == container.path)
        #expect(configuration.environment[StorageLocationPolicy.environmentKey] == container.path)
    }

    @Test("the default preference publishes nothing")
    func defaultPreferencePublishesNothing() {
        let configuration = StorageLocationLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: .default,
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume())
        )
        #expect(configuration.stateRoot == nil)
        #expect(configuration.environment[StorageLocationPolicy.environmentKey] == nil)
    }

    @Test("a rejected preference does not reach the launcher")
    func rejectedPreferenceIsNotPublished() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let configuration = StorageLocationLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: StorageLocationPreference(containerPath: container.path),
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume(typeName: "exfat", cloning: false, sparse: false))
        )
        #expect(configuration.stateRoot == nil)
        #expect(configuration.environment[StorageLocationPolicy.environmentKey] == nil)
        // Absent the env var the launcher silently uses the default workspace,
        // so a rejected preference must also carry the reason that makes
        // callers refuse to start it at all. Reset depends on this: falling
        // back would erase the default VM instead of the chosen one.
        #expect(configuration.unavailableReason != nil)
    }

    @Test("an unreachable chosen folder reports why rather than falling back silently")
    func unavailableChoiceIsReported() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        // Stands in for an external drive that is no longer mounted.
        let missing = parent.appendingPathComponent("unplugged", isDirectory: true)

        let configuration = StorageLocationLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: StorageLocationPreference(containerPath: missing.path),
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume())
        )
        #expect(configuration.stateRoot == nil)
        #expect(configuration.environment[StorageLocationPolicy.environmentKey] == nil)
        #expect(
            configuration.unavailableReason
                == StorageLocationPolicyError.missing(missing.path).localizedDescription
        )
    }

    @Test("the default location is not an unavailable one")
    func defaultChoiceIsAvailable() {
        let configuration = StorageLocationLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: .default,
            metrics: metrics,
            probe: FakeVolumeProbe(result: volume())
        )
        #expect(configuration.stateRoot == nil)
        #expect(configuration.unavailableReason == nil)
    }
}

@Suite("Storage location menu state")
struct StorageLocationMenuStateTests {
    @Test("the default location reports itself as default")
    func defaultLocation() {
        let state = StorageLocationMenuState.make(
            preference: .default,
            metrics: metrics,
            homeDirectory: "/Users/example",
            probe: FakeVolumeProbe(result: volume())
        )
        #expect(state == .defaultLocation)
        #expect(state.isDefault)
    }

    @Test("a chosen external drive reports its volume name")
    func chosenExternalDrive() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let state = StorageLocationMenuState.make(
            preference: StorageLocationPreference(containerPath: container.path),
            metrics: metrics,
            homeDirectory: "/Users/example",
            probe: FakeVolumeProbe(result: volume(name: "WD-2TB", isInternal: false))
        )
        #expect(state.isDefault == false)
        #expect(state.isExternal)
        #expect(state.volumeName == "WD-2TB")
        #expect(state.problem == nil)
    }

    @Test("an unusable drive surfaces the problem instead of a path")
    func unusableDriveSurfacesProblem() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let state = StorageLocationMenuState.make(
            preference: StorageLocationPreference(containerPath: container.path),
            metrics: metrics,
            homeDirectory: "/Users/example",
            probe: FakeVolumeProbe(result: volume(typeName: "hfs", cloning: false, sparse: false))
        )
        #expect(state.stateRoot == nil)
        #expect(state.problem != nil)
    }
}
