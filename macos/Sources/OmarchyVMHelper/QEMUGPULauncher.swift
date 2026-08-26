import AVFoundation
import Darwin
import Foundation

enum QEMUGPUStorageOption: String, Equatable {
    case ephemeral = "--ephemeral"
    case resetStorage = "--reset-storage"
    case resetStorageOnly = "--reset-storage-only"
    case updateStorageOnly = "--update-storage-only"
}

enum QEMUGPUStorageSpaceEstimate {
    private static let stateRootEnvironmentKey = "OMARCHY_QEMU_GPU_STATE_ROOT"

    static func dataDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let configuredRoot = environment[stateRootEnvironmentKey], !configuredRoot.isEmpty {
            return validatedConfiguredRoot(configuredRoot)
        }
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return applicationSupport
            .appendingPathComponent("Try Omarchy", isDirectory: true)
            .standardizedFileURL
    }

    static func storageRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let configuredRoot = environment[stateRootEnvironmentKey], !configuredRoot.isEmpty {
            return validatedConfiguredRoot(configuredRoot)
        }
        return dataDirectoryURL(environment: environment, fileManager: fileManager)?
            .appendingPathComponent("VM/v1", isDirectory: true)
            .standardizedFileURL
    }

    static func dataDirectoryDisplayPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        guard let root = dataDirectoryURL(
            environment: environment,
            fileManager: fileManager
        ) else { return nil }
        let path = root.path
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func validatedConfiguredRoot(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r") else {
            return nil
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let unsafeRoots = ["/", "/Users", "/private", "/private/tmp", "/tmp"]
        guard !unsafeRoots.contains(root.path) else { return nil }
        return root
    }

    static func formattedReclaimableSpace(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentity: String? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        guard let bytes = reclaimableBytes(
            environment: environment,
            bundleIdentity: bundleIdentity,
            fileManager: fileManager
        ) else { return nil }
        return format(bytes: bytes)
    }

    static func reclaimableBytes(
        environment: [String: String],
        bundleIdentity: String?,
        fileManager: FileManager = .default
    ) -> Int64? {
        guard let directories = resettableWorkspaceDirectories(
            environment: environment,
            bundleIdentity: bundleIdentity,
            fileManager: fileManager
        ) else { return nil }

        var total: Int64 = 0
        for directory in directories {
            guard let diskURL = recordedDiskURL(
                in: directory,
                fileManager: fileManager
            ),
                  let values = try? diskURL.resourceValues(forKeys: [
                    .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey,
                  ]),
                  let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize,
                  allocated > 0 else { continue }
            let (sum, overflow) = total.addingReportingOverflow(Int64(allocated))
            guard !overflow else { return nil }
            total = sum
        }
        return total > 0 ? total : nil
    }

    static func format(bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes < 0.1 {
            return "less than 0.1 GB"
        }
        return String(format: "%.1f GB", gigabytes)
    }

    static func bundledIdentity(bundle: Bundle = .main) -> String? {
        guard let resourceURL = bundle.resourceURL,
              let data = try? Data(
                contentsOf: resourceURL.appendingPathComponent("guest/launch.plist")
              ),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = propertyList as? [String: Any],
              let identity = dictionary["bundleIdentity"] as? String,
              isIdentity(identity) else { return nil }
        return identity
    }

    static func storageKey(
        environment: [String: String],
        bundleIdentity: String?
    ) -> String? {
        switch environment["OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK"] ?? "0" {
        case "0":
            return "current"
        case "1":
            guard let bundleIdentity, isIdentity(bundleIdentity) else { return nil }
            return bundleIdentity
        default:
            return nil
        }
    }

    private static func resettableWorkspaceDirectories(
        environment: [String: String],
        bundleIdentity: String?,
        fileManager: FileManager
    ) -> [URL]? {
        guard let storageKey = storageKey(
            environment: environment,
            bundleIdentity: bundleIdentity
        ) else { return nil }
        guard let root = storageRootURL(
            environment: environment,
            fileManager: fileManager
        ) else { return nil }
        let disks = root.appendingPathComponent("disks", isDirectory: true)
        if storageKey != "current" {
            return [disks.appendingPathComponent(storageKey, isDirectory: true)]
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: disks,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return [] }
        return contents.filter {
            $0.lastPathComponent == "current" || isIdentity($0.lastPathComponent)
        }
    }

    private static func recordedDiskURL(
        in directory: URL,
        fileManager: FileManager
    ) -> URL? {
        guard hasAttributes(
            directory,
            type: .typeDirectory,
            permissions: 0o700,
            fileManager: fileManager
        ),
              let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
              ),
              Set(entries.map(\.lastPathComponent)) == ["metadata.json", "rootfs.ext4"]
        else { return nil }

        let metadataURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
        let diskURL = directory.appendingPathComponent("rootfs.ext4", isDirectory: false)
        guard hasAttributes(
            metadataURL,
            type: .typeRegular,
            permissions: 0o600,
            fileManager: fileManager
        ),
              hasAttributes(
                diskURL,
                type: .typeRegular,
                permissions: 0o600,
                fileManager: fileManager
              ),
              let metadataData = try? Data(contentsOf: metadataURL),
              metadataData.count <= 16_384,
              var serializedMetadata = String(data: metadataData, encoding: .utf8),
              let rawMetadata = try? JSONSerialization.jsonObject(with: metadataData),
              let metadata = rawMetadata as? [String: Any],
              Set(metadata.keys) == ["bundleIdentity", "kind", "schemaVersion", "sourceRootfs"],
              metadata["kind"] as? String == "omarchy-qemu-persistent-disk",
              let identity = metadata["bundleIdentity"] as? String,
              isIdentity(identity),
              let schemaNumber = metadata["schemaVersion"] as? NSNumber,
              [1, 2].contains(schemaNumber.intValue),
              let source = metadata["sourceRootfs"] as? [String: Any],
              Set(source.keys) == ["bytes", "sha256"],
              let sourceBytesNumber = source["bytes"] as? NSNumber,
              sourceBytesNumber.int64Value > 0,
              let sourceSHA = source["sha256"] as? String,
              isIdentity(sourceSHA)
        else { return nil }

        while serializedMetadata.last == "\n" {
            serializedMetadata.removeLast()
        }
        let canonicalMetadata = "{\"bundleIdentity\":\"\(identity)\",\"kind\":\"omarchy-qemu-persistent-disk\",\"schemaVersion\":\(schemaNumber.intValue),\"sourceRootfs\":{\"bytes\":\(sourceBytesNumber.int64Value),\"sha256\":\"\(sourceSHA)\"}}"
        guard serializedMetadata == canonicalMetadata,
              directory.lastPathComponent == "current" || directory.lastPathComponent == identity,
              let diskSize = try? diskURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(diskSize) >= sourceBytesNumber.int64Value
        else { return nil }
        return diskURL
    }

    private static func hasAttributes(
        _ url: URL,
        type: FileAttributeType,
        permissions: Int,
        fileManager: FileManager
    ) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == permissions
        else { return false }
        return true
    }

    private static func isIdentity(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

enum QEMUGPUWorkspaceUpdateRequirement: Equatable {
    case notRequired
    case required
    case indeterminate
}

protocol QEMUGPUWorkspaceUpdateRequirementProviding {
    func requirement(
        environment: [String: String],
        targetBundleIdentity: String?
    ) -> QEMUGPUWorkspaceUpdateRequirement
}

/// Performs the small, read-only part of workspace compatibility detection that
/// is safe to show in the start menu. The launcher remains authoritative: an
/// unknown or malformed future format is deliberately reported as indeterminate
/// instead of being guessed to need either an update or a destructive reset.
struct QEMUGPUWorkspaceUpdatePreflight: QEMUGPUWorkspaceUpdateRequirementProviding {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func requirement(
        environment: [String: String],
        targetBundleIdentity: String?
    ) -> QEMUGPUWorkspaceUpdateRequirement {
        guard let targetBundleIdentity, Self.isIdentity(targetBundleIdentity),
              let storageRoot = QEMUGPUStorageSpaceEstimate.storageRootURL(
                environment: environment,
                fileManager: fileManager
              ) else {
            return .indeterminate
        }

        // VM/v1 supports persistent-disk metadata schemas 1 and 2. Keep the
        // layout dispatch isolated here so VM/v2 can gain its own decoder
        // without weakening validation of an existing workspace.
        return requirementForV1(
            storageRoot: storageRoot,
            targetBundleIdentity: targetBundleIdentity
        )
    }

    private func requirementForV1(
        storageRoot: URL,
        targetBundleIdentity: String
    ) -> QEMUGPUWorkspaceUpdateRequirement {
        let disks = storageRoot.appendingPathComponent("disks", isDirectory: true)
        let workspace = disks
            .appendingPathComponent("current", isDirectory: true)
        var workspaceInformation = stat()
        guard Darwin.lstat(workspace.path, &workspaceInformation) == 0 else {
            return errno == ENOENT
                ? requirementForLegacyV1(
                    disks: disks,
                    targetBundleIdentity: targetBundleIdentity
                )
                : .indeterminate
        }
        guard workspaceInformation.st_mode & S_IFMT == S_IFDIR,
              let metadata = metadataForV1Workspace(workspace)
        else { return .indeterminate }

        // Schema 1 predates the single-workspace compatibility contract. Even
        // when its identity happens to match, the authoritative storage layer
        // must migrate it before launch; surface that as Update immediately.
        return metadata.schemaVersion == 2
            && metadata.bundleIdentity == targetBundleIdentity
            ? .notRequired
            : .required
    }

    /// Older app releases keyed their sole workspace by bundle identity. Find
    /// exactly one fully valid legacy workspace so the initial button can say
    /// Update before the launcher atomically relocates it to `disks/current`.
    /// Ambiguous or malformed stores remain deferred to the authoritative
    /// storage implementation.
    private func requirementForLegacyV1(
        disks: URL,
        targetBundleIdentity: String
    ) -> QEMUGPUWorkspaceUpdateRequirement {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: disks,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            var information = stat()
            return Darwin.lstat(disks.path, &information) != 0 && errno == ENOENT
                ? .notRequired
                : .indeterminate
        }
        let candidates = entries.filter { Self.isIdentity($0.lastPathComponent) }
        guard !candidates.isEmpty else { return .notRequired }
        let valid = candidates.compactMap { candidate -> V1Metadata? in
            guard let metadata = metadataForV1Workspace(candidate),
                  metadata.bundleIdentity == candidate.lastPathComponent else { return nil }
            return metadata
        }
        guard valid.count == 1, valid.count == candidates.count,
              let metadata = valid.first else { return .indeterminate }
        return metadata.schemaVersion == 2
            && metadata.bundleIdentity == targetBundleIdentity
            ? .notRequired
            : .required
    }

    private func metadataForV1Workspace(_ workspace: URL) -> V1Metadata? {
        guard hasAttributes(workspace, type: .typeDirectory, permissions: 0o700),
              let entries = try? fileManager.contentsOfDirectory(
                at: workspace,
                includingPropertiesForKeys: nil,
                options: []
              ),
              Set(entries.map(\.lastPathComponent)) == ["metadata.json", "rootfs.ext4"]
        else { return nil }

        let metadataURL = workspace.appendingPathComponent("metadata.json", isDirectory: false)
        let diskURL = workspace.appendingPathComponent("rootfs.ext4", isDirectory: false)
        guard hasAttributes(metadataURL, type: .typeRegular, permissions: 0o600),
              hasAttributes(diskURL, type: .typeRegular, permissions: 0o600),
              let metadata = decodeV1Metadata(at: metadataURL),
              let diskSize = try? diskURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(diskSize) >= metadata.sourceBytes
        else { return nil }
        return metadata
    }

    private func decodeV1Metadata(at url: URL) -> V1Metadata? {
        guard let data = try? Data(contentsOf: url),
              data.count <= 16_384,
              var serialized = String(data: data, encoding: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let dictionary = raw as? [String: Any],
              Set(dictionary.keys) == ["bundleIdentity", "kind", "schemaVersion", "sourceRootfs"],
              dictionary["kind"] as? String == "omarchy-qemu-persistent-disk",
              let identity = dictionary["bundleIdentity"] as? String,
              Self.isIdentity(identity),
              let schema = dictionary["schemaVersion"] as? NSNumber,
              [1, 2].contains(schema.intValue),
              let source = dictionary["sourceRootfs"] as? [String: Any],
              Set(source.keys) == ["bytes", "sha256"],
              let sourceBytes = source["bytes"] as? NSNumber,
              sourceBytes.int64Value > 0,
              let sourceSHA = source["sha256"] as? String,
              Self.isIdentity(sourceSHA)
        else { return nil }

        while serialized.last == "\n" {
            serialized.removeLast()
        }
        let canonical = "{\"bundleIdentity\":\"\(identity)\",\"kind\":\"omarchy-qemu-persistent-disk\",\"schemaVersion\":\(schema.intValue),\"sourceRootfs\":{\"bytes\":\(sourceBytes.int64Value),\"sha256\":\"\(sourceSHA)\"}}"
        guard serialized == canonical else { return nil }
        return V1Metadata(
            bundleIdentity: identity,
            schemaVersion: schema.intValue,
            sourceBytes: sourceBytes.int64Value
        )
    }

    private func hasAttributes(
        _ url: URL,
        type: FileAttributeType,
        permissions: Int
    ) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == permissions
        else { return false }
        return true
    }

    private static func isIdentity(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private struct V1Metadata {
        let bundleIdentity: String
        let schemaVersion: Int
        let sourceBytes: Int64
    }
}

struct QEMUGPULaunchRequest: Equatable {
    let storageOption: QEMUGPUStorageOption?
    let guestDirectoryPath: String?

    init(
        storageOption: QEMUGPUStorageOption?,
        guestDirectoryPath: String?
    ) {
        self.storageOption = storageOption
        self.guestDirectoryPath = guestDirectoryPath
    }

    init?(arguments: [String]) {
        var remaining = arguments[...]
        var storageOption: QEMUGPUStorageOption?

        if let first = remaining.first,
           let parsedOption = QEMUGPUStorageOption(rawValue: first) {
            storageOption = parsedOption
            remaining = remaining.dropFirst()
        }

        guard remaining.count <= 1 else { return nil }
        let guestDirectoryPath = remaining.first
        if let guestDirectoryPath {
            guard guestDirectoryPath.hasPrefix("/"),
                  !guestDirectoryPath.hasPrefix("--"),
                  !guestDirectoryPath.contains("\n"),
                  !guestDirectoryPath.contains("\r") else { return nil }
        }

        self.storageOption = storageOption
        self.guestDirectoryPath = guestDirectoryPath
    }

    func validatedScriptArguments() throws -> [String] {
        var result = storageOption.map { [$0.rawValue] } ?? []
        guard let guestDirectoryPath else { return result }

        let guestDirectory = URL(
            fileURLWithPath: guestDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        var information = stat()
        guard Darwin.lstat(guestDirectory.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw HelperError.io("ARM guest directory is missing or unsafe: \(guestDirectory.path)")
        }

        let canonicalDirectory = guestDirectory.resolvingSymlinksInPath()
        result.append(canonicalDirectory.path)
        return result
    }

}

enum QEMUGPULauncherPath {
    static let appName = "Try Omarchy.app"
    static let launcherName = "run-qemu-gpu.sh"

    static func resolve(bundleURL: URL) throws -> URL {
        let standardizedBundle = bundleURL.standardizedFileURL
        var bundleInformation = stat()
        guard standardizedBundle.lastPathComponent == appName,
              Darwin.lstat(standardizedBundle.path, &bundleInformation) == 0,
              bundleInformation.st_mode & S_IFMT == S_IFDIR else {
            throw HelperError.io("QEMU launch is available only from the built Omarchy app")
        }

        let canonicalBundle = standardizedBundle.resolvingSymlinksInPath()
        let resources = canonicalBundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let scripts = resources.appendingPathComponent("scripts", isDirectory: true)
        let launcher = scripts.appendingPathComponent(launcherName, isDirectory: false)
        let canonicalLauncher = launcher.resolvingSymlinksInPath()
        var launcherInformation = stat()
        guard canonicalLauncher.deletingLastPathComponent() == scripts,
              Darwin.lstat(launcher.path, &launcherInformation) == 0,
              launcherInformation.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw HelperError.io("bundled QEMU launcher is missing or unsafe: \(launcher.path)")
        }
        return canonicalLauncher
    }
}

enum MicrophoneAuthorizationState: Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

enum AccessibilityAuthorizationState: Equatable {
    case authorized
    case unavailable
}

struct AccessibilityLaunchDecision: Equatable {
    let allowsLaunch: Bool
    let warning: String?

    static func make(for state: AccessibilityAuthorizationState) -> Self {
        switch state {
        case .authorized:
            Self(allowsLaunch: true, warning: nil)
        case .unavailable:
            Self(
                allowsLaunch: true,
                warning: "Accessibility is not active yet; Omarchy will start without Command-to-Super mapping. The mapping becomes available on a later launch after macOS recognizes the grant."
            )
        }
    }
}

struct MicrophoneLaunchDecision: Equatable {
    let allowsLaunch: Bool
    let warning: String?

    static func make(for state: MicrophoneAuthorizationState) -> Self {
        switch state {
        case .authorized:
            Self(allowsLaunch: true, warning: nil)
        case .denied:
            Self(
                allowsLaunch: true,
                warning: "Microphone access is denied. Audio playback will continue, but guest recording is unavailable. Enable Try Omarchy in System Settings > Privacy & Security > Microphone, then relaunch."
            )
        case .restricted:
            Self(
                allowsLaunch: true,
                warning: "Microphone access is restricted by macOS policy. Audio playback will continue, but guest recording is unavailable. Ask the Mac administrator to allow microphone access for Try Omarchy."
            )
        case .notDetermined:
            Self(
                allowsLaunch: true,
                warning: "Microphone access was not requested. Audio playback will continue, but guest recording is unavailable until access is enabled."
            )
        }
    }
}

enum MicrophonePreflight {
    static func authorizationState() -> MicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .restricted
        }
    }

    static func requestAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    static func decision() -> MicrophoneLaunchDecision {
        .make(for: authorizationState())
    }
}

final class QEMUGPUProcessSupervisor: @unchecked Sendable {
    enum LaunchEvent: Equatable {
        case virtualMachineReady
    }

    private let lock = NSLock()
    private var child: Process?
    private var errorPipe: Pipe?
    private var errorBuffer = ""
    private var didReportVirtualMachineStart = false

    func start(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        launchEvent: @escaping @MainActor @Sendable (LaunchEvent) -> Void = { _ in },
        completion: @escaping @MainActor @Sendable (Int32) -> Void
    ) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            try? FileHandle.standardError.write(contentsOf: data)
            if self?.recordStandardError(data) == true {
                DispatchQueue.main.async {
                    launchEvent(.virtualMachineReady)
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.clear(process)
            let status = Self.status(for: process)
            // NSApplication owns a synchronous AppKit run loop. Dispatching a
            // main-queue block lets that run loop service child completion;
            // a MainActor Task could wait behind the still-running call.
            DispatchQueue.main.async {
                completion(status)
            }
        }

        lock.lock()
        guard child == nil else {
            lock.unlock()
            throw HelperError.io("QEMU launcher process is already running")
        }
        child = process
        errorPipe = pipe
        errorBuffer = ""
        didReportVirtualMachineStart = false
        lock.unlock()

        do {
            try process.run()
        } catch {
            clear(process)
            throw error
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return child?.isRunning == true
    }

    func forward(signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard let child, child.isRunning else { return }
        _ = Darwin.kill(child.processIdentifier, signal)
    }

    private func clear(_ process: Process) {
        lock.lock()
        if child === process {
            child = nil
            errorPipe?.fileHandleForReading.readabilityHandler = nil
            errorPipe = nil
        }
        lock.unlock()
    }

    private func recordStandardError(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        errorBuffer += String(decoding: data, as: UTF8.self)
        if errorBuffer.count > 4_096 {
            errorBuffer = String(errorBuffer.suffix(4_096))
        }
        guard !didReportVirtualMachineStart,
              errorBuffer.contains("[qemu-gpu] Ready") else { return false }
        didReportVirtualMachineStart = true
        return true
    }

    private static func status(for process: Process) -> Int32 {
        switch process.terminationReason {
        case .exit:
            return process.terminationStatus
        case .uncaughtSignal:
            return 128 + process.terminationStatus
        @unknown default:
            return 1
        }
    }
}
