import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("QEMU GPU app launch request")
struct QEMUGPULaunchRequestTests {
    @Test("accepts only the launcher storage flags and an optional absolute guest directory")
    func parsesAllowedArguments() {
        let guest = "/private/tmp/omarchy guest"
        #expect(QEMUGPULaunchRequest(arguments: []) == QEMUGPULaunchRequest(
            storageOption: nil,
            guestDirectoryPath: nil
        ))
        #expect(QEMUGPULaunchRequest(arguments: ["--ephemeral"]) == QEMUGPULaunchRequest(
            storageOption: .ephemeral,
            guestDirectoryPath: nil
        ))
        #expect(QEMUGPULaunchRequest(arguments: ["--reset-storage", guest]) == QEMUGPULaunchRequest(
            storageOption: .resetStorage,
            guestDirectoryPath: guest
        ))
        #expect(QEMUGPULaunchRequest(arguments: ["--reset-storage-only", guest]) == QEMUGPULaunchRequest(
            storageOption: .resetStorageOnly,
            guestDirectoryPath: guest
        ))
        #expect(QEMUGPULaunchRequest(arguments: [guest]) == QEMUGPULaunchRequest(
            storageOption: nil,
            guestDirectoryPath: guest
        ))
    }

    @Test("rejects unknown flags, relative paths, reordered flags, and extra arguments")
    func rejectsUnsafeArguments() {
        for arguments in [
            ["--unknown"],
            ["relative/guest"],
            ["/guest", "--ephemeral"],
            ["--ephemeral", "--reset-storage"],
            ["--ephemeral", "/guest", "/other"],
            ["/guest\nother"],
        ] {
            #expect(QEMUGPULaunchRequest(arguments: arguments) == nil)
        }
    }

    @Test("canonicalizes a safe guest directory before passing it to the script")
    func validatesGuestDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-qemu-request-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let request = try #require(QEMUGPULaunchRequest(arguments: ["--ephemeral", root.path]))
        #expect(try request.validatedScriptArguments() == ["--ephemeral", root.resolvingSymlinksInPath().path])
    }

    @Test("rejects a final guest-directory symlink")
    func rejectsGuestSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-qemu-request-\(UUID().uuidString)", isDirectory: true)
        let guest = root.appendingPathComponent("guest", isDirectory: true)
        let link = root.appendingPathComponent("guest-link", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: guest)

        let request = try #require(QEMUGPULaunchRequest(arguments: [link.path]))
        #expect(throws: HelperError.self) {
            try request.validatedScriptArguments()
        }
    }

}

@Suite("QEMU runtime environment")
struct QEMUGPURuntimeEnvironmentTests {
    @Test("ordinary launches strip build-only controls")
    func sanitizesLaunch() {
        let environment = QEMUGPURuntimeEnvironment.sanitizedForLaunch([
            "KEEP_ME": "yes",
            QEMUGPURuntimeEnvironment.inspectOnlyKey: "1",
            QEMUGPURuntimeEnvironment.dryRunKey: "1",
        ])

        #expect(environment == ["KEEP_ME": "yes"])
    }

    @Test("storage reset ignores inherited integration settings")
    func sanitizesReset() {
        let controlledKeys = [
            AudioLaunchConfiguration.inheritedSDLDeviceNameKey,
            AudioLaunchConfiguration.outputDeviceNameKey,
            AudioLaunchConfiguration.inputDeviceNameKey,
            SharedFolderPolicy.environmentKey,
            PortForwardPolicy.environmentKey,
            QEMUGPURuntimeEnvironment.inspectOnlyKey,
            QEMUGPURuntimeEnvironment.dryRunKey,
        ]
        var inherited = ["KEEP_ME": "yes"]
        for key in controlledKeys {
            inherited[key] = "untrusted inherited value"
        }

        #expect(QEMUGPURuntimeEnvironment.sanitizedForReset(inherited)
            == ["KEEP_ME": "yes"])
    }
}

@Suite("QEMU standard-error drain")
struct QEMUStandardErrorDrainTests {
    @Test("drains a bounded tail without waiting for EOF and restores descriptor flags")
    func boundedNonblockingDrain() throws {
        let pipe = Pipe()
        var writerClosed = false
        defer {
            pipe.fileHandleForReading.closeFile()
            if !writerClosed {
                pipe.fileHandleForWriting.closeFile()
            }
        }

        let payload = Data("trailing QEMU diagnostic".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let originalFlags = Darwin.fcntl(descriptor, F_GETFL)
        #expect(originalFlags >= 0)

        let first = QEMUGPUProcessSupervisor.drainAvailableStandardError(
            from: pipe.fileHandleForReading,
            maximumBytes: 8
        )
        #expect(first.data == Data(payload.prefix(8)))
        #expect(!first.reachedEnd)
        #expect(Darwin.fcntl(descriptor, F_GETFL) == originalFlags)

        let second = QEMUGPUProcessSupervisor.drainAvailableStandardError(
            from: pipe.fileHandleForReading,
            maximumBytes: 1_024
        )
        #expect(second.data == Data(payload.dropFirst(8)))
        #expect(!second.reachedEnd)
        #expect(Darwin.fcntl(descriptor, F_GETFL) == originalFlags)

        pipe.fileHandleForWriting.closeFile()
        writerClosed = true
        let end = QEMUGPUProcessSupervisor.drainAvailableStandardError(
            from: pipe.fileHandleForReading,
            maximumBytes: 1_024
        )
        #expect(end.data.isEmpty)
        #expect(end.reachedEnd)
        #expect(Darwin.fcntl(descriptor, F_GETFL) == originalFlags)
    }
}

@Suite("QEMU storage-space estimate")
struct QEMUGPUStorageSpaceEstimateTests {
    @Test("shows the app data folder while keeping the VM layout versioned")
    func displaysStorageRoot() throws {
        let configuredRoot = "/private/tmp/try-omarchy-configured/../data"
        let configuredEnvironment = ["OMARCHY_QEMU_GPU_STATE_ROOT": configuredRoot]
        let standardizedConfiguredRoot = URL(
            fileURLWithPath: configuredRoot,
            isDirectory: true
        ).standardizedFileURL
        #expect(QEMUGPUStorageSpaceEstimate.dataDirectoryDisplayPath(
            environment: configuredEnvironment
        ) == "/private/tmp/data")
        #expect(QEMUGPUStorageSpaceEstimate.dataDirectoryURL(
            environment: configuredEnvironment
        ) == standardizedConfiguredRoot)
        #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: configuredEnvironment
        ) == standardizedConfiguredRoot)

        let defaultDirectory = try #require(QEMUGPUStorageSpaceEstimate.dataDirectoryDisplayPath(
            environment: [:]
        ))
        #expect(defaultDirectory == "~/Library/Application Support/Try Omarchy")

        let defaultDirectoryURL = try #require(QEMUGPUStorageSpaceEstimate.dataDirectoryURL(
            environment: [:]
        ))
        let defaultStorageRoot = try #require(QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: [:]
        ))
        #expect(defaultStorageRoot == defaultDirectoryURL
            .appendingPathComponent("VM/v1", isDirectory: true)
            .standardizedFileURL)

        for invalidRoot in ["relative/path", "/private/tmp/..", "/tmp", "/bad\npath"] {
            let invalidEnvironment = ["OMARCHY_QEMU_GPU_STATE_ROOT": invalidRoot]
            #expect(QEMUGPUStorageSpaceEstimate.dataDirectoryURL(
                environment: invalidEnvironment
            ) == nil)
            #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(
                environment: invalidEnvironment
            ) == nil)
        }
    }

    @Test("a chosen data folder replaces the default without the versioned suffix")
    func honorsStoredPreference() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let preference = StorageLocationPreference(containerPath: container.path)

        // A chosen workspace is the state root itself, exactly as the launcher
        // script treats OMARCHY_QEMU_GPU_STATE_ROOT — the picked folder is
        // used directly, with no folder nested inside it.
        let expected = URL(fileURLWithPath: container.path, isDirectory: true)
            .standardizedFileURL
        #expect(QEMUGPUStorageSpaceEstimate.dataDirectoryURL(
            environment: [:],
            preference: preference
        ) == expected)
        #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: [:],
            preference: preference
        ) == expected)
    }

    @Test("the development override still wins over a stored preference")
    func overrideBeatsPreference() {
        let configured = "/private/tmp/try-omarchy-override"
        let expected = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: ["OMARCHY_QEMU_GPU_STATE_ROOT": configured],
            preference: StorageLocationPreference(containerPath: "/Volumes/Ignored")
        ) == expected)
    }

    @Test("formats allocated bytes as a readable decimal gigabyte estimate")
    func formatsGigabytes() {
        #expect(QEMUGPUStorageSpaceEstimate.format(bytes: 0) == nil)
        #expect(QEMUGPUStorageSpaceEstimate.format(bytes: 50_000_000) == "less than 0.1 GB")
        #expect(QEMUGPUStorageSpaceEstimate.format(bytes: 3_250_000_000) == "3.2 GB")
    }

    @Test("selects the same single or development workspace used by the launcher")
    func selectsStorageKey() {
        let identity = String(repeating: "a", count: 64)
        #expect(QEMUGPUStorageSpaceEstimate.storageKey(
            environment: [:],
            bundleIdentity: identity
        ) == "current")
        #expect(QEMUGPUStorageSpaceEstimate.storageKey(
            environment: ["OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK": "0"],
            bundleIdentity: identity
        ) == "current")
        #expect(QEMUGPUStorageSpaceEstimate.storageKey(
            environment: ["OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK": "1"],
            bundleIdentity: identity
        ) == identity)
        #expect(QEMUGPUStorageSpaceEstimate.storageKey(
            environment: ["OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK": "1"],
            bundleIdentity: nil
        ) == nil)
        #expect(QEMUGPUStorageSpaceEstimate.storageKey(
            environment: ["OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK": "invalid"],
            bundleIdentity: identity
        ) == nil)
    }

    @Test("counts every safely recognized disk removed by a single-disk reset")
    func countsResettableLegacyDisks() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "try-omarchy-space-estimate-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let disks = root.appendingPathComponent("state/disks", isDirectory: true)
        try fileManager.createDirectory(at: disks, withIntermediateDirectories: true)

        let identityA = String(repeating: "a", count: 64)
        let identityB = String(repeating: "b", count: 64)
        let identityC = String(repeating: "c", count: 64)
        let current = try makeWorkspace(
            in: disks,
            name: "current",
            identity: identityA,
            payloadBytes: 8_192
        )
        let legacy = try makeWorkspace(
            in: disks,
            name: identityB,
            identity: identityB,
            payloadBytes: 12_288
        )
        _ = try makeWorkspace(
            in: disks,
            name: identityC,
            identity: identityC,
            payloadBytes: 16_384,
            addUnknownFile: true
        )

        let allocated = try [current, legacy].reduce(Int64(0)) { total, disk in
            let values = try disk.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
            ])
            return total + Int64(try #require(
                values.totalFileAllocatedSize ?? values.fileAllocatedSize
            ))
        }
        let environment = ["OMARCHY_QEMU_GPU_STATE_ROOT": root.appendingPathComponent("state").path]
        #expect(QEMUGPUStorageSpaceEstimate.reclaimableBytes(
            environment: environment,
            bundleIdentity: identityA,
            fileManager: fileManager
        ) == allocated)

        #expect(QEMUGPUStorageSpaceEstimate.reclaimableBytes(
            environment: environment.merging(
                ["OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK": "1"],
                uniquingKeysWith: { _, new in new }
            ),
            bundleIdentity: identityB,
            fileManager: fileManager
        ) == allocatedSize(of: legacy))
    }

    @Test("ignores semantically valid metadata with noncanonical whitespace or key order")
    func ignoresNoncanonicalSerializedMetadata() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "try-omarchy-space-estimate-noncanonical-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let disks = root.appendingPathComponent("state/disks", isDirectory: true)
        try fileManager.createDirectory(at: disks, withIntermediateDirectories: true)

        let identity = String(repeating: "a", count: 64)
        let sourceSHA = String(repeating: "d", count: 64)
        _ = try makeWorkspace(
            in: disks,
            name: "current",
            identity: identity,
            payloadBytes: 8_192,
            metadataContents: """
            { "kind": "omarchy-qemu-persistent-disk", "bundleIdentity": "\(identity)", "sourceRootfs": { "sha256": "\(sourceSHA)", "bytes": 1 }, "schemaVersion": 2 }
            """
        )

        let environment = ["OMARCHY_QEMU_GPU_STATE_ROOT": root.appendingPathComponent("state").path]
        #expect(QEMUGPUStorageSpaceEstimate.reclaimableBytes(
            environment: environment,
            bundleIdentity: identity,
            fileManager: fileManager
        ) == nil)
    }

    @Test("ignores fractional schema and source byte values")
    func ignoresFractionalMetadataNumbers() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "try-omarchy-space-estimate-fractional-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let disks = root.appendingPathComponent("state/disks", isDirectory: true)
        try fileManager.createDirectory(at: disks, withIntermediateDirectories: true)

        let identity = String(repeating: "b", count: 64)
        let sourceSHA = String(repeating: "d", count: 64)
        _ = try makeWorkspace(
            in: disks,
            name: identity,
            identity: identity,
            payloadBytes: 8_192,
            metadataContents: "{\"bundleIdentity\":\"\(identity)\",\"kind\":\"omarchy-qemu-persistent-disk\",\"schemaVersion\":2.5,\"sourceRootfs\":{\"bytes\":1.5,\"sha256\":\"\(sourceSHA)\"}}\n"
        )

        let environment = ["OMARCHY_QEMU_GPU_STATE_ROOT": root.appendingPathComponent("state").path]
        #expect(QEMUGPUStorageSpaceEstimate.reclaimableBytes(
            environment: environment,
            bundleIdentity: identity,
            fileManager: fileManager
        ) == nil)
    }

    private func makeWorkspace(
        in disks: URL,
        name: String,
        identity: String,
        payloadBytes: Int,
        addUnknownFile: Bool = false,
        metadataContents: String? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let directory = disks.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(Darwin.chmod(directory.path, 0o700) == 0)

        let metadata = directory.appendingPathComponent("metadata.json")
        let sourceSHA = String(repeating: "d", count: 64)
        try Data(
            (metadataContents ?? "{\"bundleIdentity\":\"\(identity)\",\"kind\":\"omarchy-qemu-persistent-disk\",\"schemaVersion\":2,\"sourceRootfs\":{\"bytes\":1,\"sha256\":\"\(sourceSHA)\"}}\n").utf8
        ).write(to: metadata)
        #expect(Darwin.chmod(metadata.path, 0o600) == 0)

        let disk = directory.appendingPathComponent("rootfs.ext4")
        try Data(repeating: 0x5a, count: payloadBytes).write(to: disk)
        #expect(Darwin.chmod(disk.path, 0o600) == 0)
        if addUnknownFile {
            let unknown = directory.appendingPathComponent("unknown.txt")
            try Data("preserve".utf8).write(to: unknown)
            #expect(Darwin.chmod(unknown.path, 0o600) == 0)
        }
        return disk
    }

    private func allocatedSize(of disk: URL) -> Int64? {
        guard let values = try? disk.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]),
              let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        else { return nil }
        return Int64(bytes)
    }
}

@Suite("Bundled QEMU GPU launcher path")
struct QEMUGPULauncherPathTests {
    @Test("resolves only the executable inside the app resources")
    func resolvesExpectedLayout() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try QEMUGPULauncherPath.resolve(bundleURL: fixture.app) == fixture.launcher)
    }

    @Test("rejects a launcher symlink")
    func rejectsLauncherSymlink() throws {
        let fixture = try makeFixture(createLauncher: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let other = fixture.root.appendingPathComponent("other-launcher")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: other)
        #expect(Darwin.chmod(other.path, 0o755) == 0)
        try FileManager.default.createSymbolicLink(at: fixture.launcher, withDestinationURL: other)

        #expect(throws: HelperError.self) {
            try QEMUGPULauncherPath.resolve(bundleURL: fixture.app)
        }
    }

    @Test("rejects an app with the wrong bundle name")
    func rejectsWrongBundleName() throws {
        let fixture = try makeFixture(appName: "Other.app")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: HelperError.self) {
            try QEMUGPULauncherPath.resolve(bundleURL: fixture.app)
        }
    }

    private struct PathFixture {
        let root: URL
        let app: URL
        let launcher: URL
    }

    private func makeFixture(
        appName: String = QEMUGPULauncherPath.appName,
        createLauncher: Bool = true
    ) throws -> PathFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-qemu-path-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent(appName, isDirectory: true)
        let scripts = app
            .appendingPathComponent("Contents/Resources/scripts", isDirectory: true)
        let launcher = scripts.appendingPathComponent(QEMUGPULauncherPath.launcherName)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        if createLauncher {
            try Data("#!/bin/bash\nexit 0\n".utf8).write(to: launcher)
            #expect(Darwin.chmod(launcher.path, 0o755) == 0)
        }
        return PathFixture(
            root: root,
            app: app.resolvingSymlinksInPath(),
            launcher: launcher.resolvingSymlinksInPath()
        )
    }
}

@Suite("Microphone launch policy")
struct MicrophoneLaunchDecisionTests {
    @Test("denial keeps playback launchable and gives recovery instructions")
    func deniedStillLaunches() {
        let decision = MicrophoneLaunchDecision.make(for: .denied)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("Audio playback will continue") == true)
        #expect(decision.warning?.contains("System Settings > Privacy & Security > Microphone") == true)
    }

    @Test("restriction keeps playback launchable with an administrator action")
    func restrictedStillLaunches() {
        let decision = MicrophoneLaunchDecision.make(for: .restricted)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("Mac administrator") == true)
    }

    @Test("authorization launches without a warning")
    func authorizedHasNoWarning() {
        let decision = MicrophoneLaunchDecision.make(for: .authorized)
        #expect(decision.allowsLaunch)
        #expect(decision.warning == nil)
    }

    @Test("an unrequested microphone remains optional")
    func notDeterminedStillLaunches() {
        let decision = MicrophoneLaunchDecision.make(for: .notDetermined)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("was not requested") == true)
    }
}

@Suite("Accessibility launch policy")
struct AccessibilityLaunchDecisionTests {
    @Test("an unavailable grant never blocks Omarchy startup")
    func unavailableStillLaunches() {
        let decision = AccessibilityLaunchDecision.make(for: .unavailable)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("start without Command-to-Super mapping") == true)
        #expect(decision.warning?.contains("later launch") == true)
    }

    @Test("authorization launches without a warning")
    func authorizedHasNoWarning() {
        let decision = AccessibilityLaunchDecision.make(for: .authorized)
        #expect(decision.allowsLaunch)
        #expect(decision.warning == nil)
    }
}
