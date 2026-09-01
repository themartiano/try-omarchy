import Foundation
import Testing
@testable import OmarchyVMHelper

/// Runs the picker's marker check and the launcher's own `_qps_validate_root_marker`
/// over identical fixtures and requires the same verdict from both.
///
/// Grepping the shell source pins the constants but not the semantics, and the
/// semantics are where the two drifted: command substitution strips trailing
/// newlines only, so a marker starting with one was accepted here and refused
/// at launch. Executing both sides is the only check that catches that.
@Suite("Storage marker cross-language agreement")
struct StorageMarkerAgreementTests {
    private static let token = StorageLocationPolicy.rootMarkerContent

    /// Each case is (name, marker bytes, mode). `nil` bytes means "not a
    /// regular file" — the fixture builder makes a directory instead.
    private static let fixtures: [(name: String, contents: String?, mode: Int16)] = [
        ("canonical", "\(token)\n", 0o600),
        ("no trailing newline", token, 0o600),
        ("many trailing newlines", "\(token)\n\n\n", 0o600),
        ("leading newline", "\n\(token)\n", 0o600),
        ("leading and trailing", "\n\n\(token)\n\n", 0o600),
        ("interior newline", "\(token)\n\(token)\n", 0o600),
        ("empty", "", 0o600),
        ("whitespace padded", " \(token) \n", 0o600),
        ("trailing carriage return", "\(token)\r\n", 0o600),
        ("wrong token", "omarchy-qemu-storage-root-v2\n", 0o600),
        ("token prefix", "\(token)-extra\n", 0o600),
        ("group readable", "\(token)\n", 0o640),
        ("world readable", "\(token)\n", 0o644),
        ("owner read only", "\(token)\n", 0o400),
        ("executable", "\(token)\n", 0o700),
        ("setuid", "\(token)\n", 0o4600),
        ("setgid", "\(token)\n", 0o2600),
        ("sticky", "\(token)\n", 0o1600),
        ("directory", nil, 0o700),
    ]

    @Test("the picker and the launcher agree on every marker shape")
    func markersAgree() throws {
        let library = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("qemu-persistent-storage.sh")

        for fixture in Self.fixtures {
            let container = try temporaryContainer()
            defer { try? FileManager.default.removeItem(at: container) }
            let marker = container.appendingPathComponent(
                StorageLocationPolicy.rootMarkerName,
                isDirectory: false
            )

            if let contents = fixture.contents {
                try Data(contents.utf8).write(to: marker)
            } else {
                try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: fixture.mode)],
                ofItemAtPath: marker.path
            )

            let swiftAccepts = StorageLocationPolicy.hasValidRootMarker(in: container)
            let shellAccepts = try launcherAccepts(marker: marker, library: library)

            #expect(
                swiftAccepts == shellAccepts,
                """
                \(fixture.name): the picker says \(swiftAccepts ? "valid" : "invalid") \
                but the launcher says \(shellAccepts ? "valid" : "invalid"). \
                A folder the picker accepts must never fail once QEMU is starting.
                """
            )
        }
    }

    /// A symlink to a perfectly valid marker is still not a marker: the checks
    /// are on the entry itself, so a link cannot borrow another file's validity.
    @Test("a symlinked marker is refused by both sides")
    func symlinkedMarkerAgrees() throws {
        let library = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("qemu-persistent-storage.sh")

        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let real = container.appendingPathComponent("real-marker", isDirectory: false)
        try Data("\(Self.token)\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let marker = container.appendingPathComponent(
            StorageLocationPolicy.rootMarkerName,
            isDirectory: false
        )
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: real)

        #expect(StorageLocationPolicy.hasValidRootMarker(in: container) == false)
        #expect(try launcherAccepts(marker: marker, library: library) == false)
    }

    /// Sources the real library and asks it about this exact file.
    private func launcherAccepts(marker: URL, library: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            #"source "$1" >/dev/null 2>&1; _qps_validate_root_marker "$2" >/dev/null 2>&1"#,
            "bash",
            library.path,
            marker.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func temporaryContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
