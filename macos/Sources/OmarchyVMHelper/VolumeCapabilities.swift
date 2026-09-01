import Foundation

/// The volume facts the persistent-disk layer depends on.
///
/// `qemu-persistent-storage.sh` clones the factory image with `cp -c`, expands
/// the working disk sparsely with `truncate`, and serializes launches with a
/// `lockf` advisory lock.
///
/// Sparse files are the requirement that cannot be relaxed: on exFAT the same
/// `truncate` allocates the whole working size up front, so a 24 GiB disk costs
/// 24 GiB immediately instead of growing with use. Locking is why network
/// volumes are refused. Only local APFS provides both, so the start menu turns
/// anything else away before QEMU is ever started.
struct VolumeCapabilities: Equatable {
    var typeName: String
    var volumeName: String?
    var supportsCloning: Bool
    var supportsSparseFiles: Bool
    var isLocal: Bool
    var isInternal: Bool
    var availableBytes: Int64

    static let apfsTypeName = "apfs"

    /// APFS reports its type name already lowercased; normalize anyway so a
    /// future macOS spelling cannot silently reject a supported volume.
    var isAPFS: Bool {
        typeName.lowercased() == Self.apfsTypeName
    }

    /// The filesystem behaviors the storage library assumes it can rely on.
    var supportsPersistentDisk: Bool {
        isAPFS && supportsCloning && supportsSparseFiles
    }
}

enum VolumeProbeError: LocalizedError, Equatable {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            "Try Omarchy could not read the disk that holds \(path)."
        }
    }
}

protocol VolumeProbing {
    func capabilities(at url: URL) throws -> VolumeCapabilities
}

/// Reads the live volume through `URLResourceValues`. The URL must exist:
/// callers probe the folder the user picked, never the workspace that has yet
/// to be created inside it.
struct URLVolumeProbe: VolumeProbing {
    private static let keys: Set<URLResourceKey> = [
        .volumeTypeNameKey,
        .volumeNameKey,
        .volumeSupportsFileCloningKey,
        .volumeSupportsSparseFilesKey,
        .volumeIsLocalKey,
        .volumeIsInternalKey,
        .volumeAvailableCapacityKey,
    ]

    init() {}

    func capabilities(at url: URL) throws -> VolumeCapabilities {
        guard let values = try? url.resourceValues(forKeys: Self.keys),
              let typeName = values.volumeTypeName,
              let available = values.volumeAvailableCapacity else {
            throw VolumeProbeError.unreadable(url.path)
        }
        return VolumeCapabilities(
            typeName: typeName,
            volumeName: values.volumeName,
            supportsCloning: values.volumeSupportsFileCloning ?? false,
            supportsSparseFiles: values.volumeSupportsSparseFiles ?? false,
            isLocal: values.volumeIsLocal ?? false,
            isInternal: values.volumeIsInternal ?? false,
            availableBytes: Int64(available)
        )
    }
}

/// Whether a path is the root directory of its own mounted volume — the one
/// case a chosen storage folder is refused even when empty, since writing
/// `disks/`, `images/`, and `locks/` directly onto a drive's top level would
/// mean chmod-ing (or otherwise restructuring) the volume's mount point
/// itself rather than a folder the user chose to dedicate to Omarchy.
protocol VolumeRootDetecting {
    func isVolumeRoot(_ url: URL) -> Bool
}

struct FileManagerVolumeRootDetector: VolumeRootDetecting {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func isVolumeRoot(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let mounts = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return mounts.contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == target }
    }
}
