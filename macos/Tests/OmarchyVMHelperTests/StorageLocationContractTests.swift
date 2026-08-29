import Foundation
import Testing
@testable import OmarchyVMHelper

/// The picker and the launcher must agree on what an Omarchy workspace looks
/// like. They are written in different languages and neither can import the
/// other's constants, so the agreement is pinned here: if one side's marker
/// name or token changes without the other, these fail rather than shipping a
/// picker that accepts folders the launcher then refuses.
@Suite("Storage location native contract")
struct StorageLocationContractTests {
    @Test("the marker filename matches the one the launcher writes")
    func markerFilename() throws {
        let library = try source(named: "qemu-persistent-storage.sh")
        #expect(library.contains("qps_marker=\"$qps_root/\(StorageLocationPolicy.rootMarkerName)\""))
    }

    @Test("the marker token matches the one the launcher validates")
    func markerToken() throws {
        let library = try source(named: "qemu-persistent-storage.sh")
        #expect(
            library.contains(
                "QEMU_PERSISTENT_STORAGE_ROOT_MARKER='\(StorageLocationPolicy.rootMarkerContent)'"
            )
        )
    }

    @Test("the launcher still enforces the marker rules the picker mirrors")
    func markerRules() throws {
        let library = try source(named: "qemu-persistent-storage.sh")

        // Content equality, checked against the token variable.
        #expect(library.contains("[[ $(<\"$qps_marker\") == \"$QEMU_PERSISTENT_STORAGE_ROOT_MARKER\" ]]"))
        // Type, ownership, and mode, via the shared file assertion.
        #expect(library.contains("_qps_assert_private_regular_file \"$qps_marker\" 'state-root marker'"))
        #expect(library.contains("[[ $(_qps_permissions \"$qps_file\") == 600 ]]"))
        #expect(library.contains("[[ $(_qps_owner \"$qps_file\") == $(id -u) ]]"))
    }

    @Test("the default state root the launcher falls back to is still the documented one")
    func defaultStateRoot() throws {
        let library = try source(named: "qemu-persistent-storage.sh")
        #expect(
            library.contains(
                "qps_configured_root=\"$HOME/Library/Application Support/Try Omarchy/VM/v1\""
            )
        )
        #expect(library.contains("if [[ -n ${\(StorageLocationPolicy.environmentKey):-} ]]; then"))
    }

    private func source(named relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let macosDirectory = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: macosDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
