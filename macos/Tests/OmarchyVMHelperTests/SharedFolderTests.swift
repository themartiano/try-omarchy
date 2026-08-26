import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Shared folder policy")
struct SharedFolderPolicyTests {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-share-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.standardizedFileURL
    }

    @Test("accepts an owned folder inside the home directory and canonicalizes it")
    func acceptsOwnedFolder() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let shared = home.appendingPathComponent("Public", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let messy = home.path + "/./Public/"

        let canonical = try SharedFolderPolicy.validate(messy, homeDirectory: home.path)
        #expect(canonical == shared.resolvingSymlinksInPath().path)
    }

    @Test("rejects the home folder, Library, system roots, symlinks, and missing paths")
    func rejectsUnsafeFolders() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let real = home.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(throws: SharedFolderPolicyError.homeDirectory) {
            try SharedFolderPolicy.validate(home.path, homeDirectory: home.path)
        }
        #expect(throws: SharedFolderPolicyError.libraryDirectory) {
            try SharedFolderPolicy.validate(library.path, homeDirectory: home.path)
        }
        #expect(throws: SharedFolderPolicyError.systemDirectory("/")) {
            try SharedFolderPolicy.validate("/", homeDirectory: home.path)
        }
        #expect(throws: SharedFolderPolicyError.notAbsolute) {
            try SharedFolderPolicy.validate("relative/folder", homeDirectory: home.path)
        }
        #expect(throws: SharedFolderPolicyError.unsupportedCharacter) {
            try SharedFolderPolicy.validate(real.path + ",id=evil", homeDirectory: home.path)
        }
        #expect(throws: SharedFolderPolicyError.symbolicLink(link.path)) {
            try SharedFolderPolicy.validate(link.path, homeDirectory: home.path)
        }
        #expect(throws: SharedFolderPolicyError.missing(home.path + "/Nope")) {
            try SharedFolderPolicy.validate(home.path + "/Nope", homeDirectory: home.path)
        }
    }

    @Test("launch environment publishes only a valid enabled folder and strips inherited values")
    func launchEnvironment() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let shared = home.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let base = [
            "KEEP_ME": "yes",
            SharedFolderPolicy.environmentKey: "/leaked",
        ]

        let enabled = SharedFolderLaunchConfiguration.make(
            baseEnvironment: base,
            preference: SharedFolderPreference(path: shared.path, isEnabled: true),
            homeDirectory: home.path
        )
        #expect(enabled.sharedFolder == shared.resolvingSymlinksInPath().path)
        #expect(enabled.environment[SharedFolderPolicy.environmentKey] == shared.resolvingSymlinksInPath().path)
        #expect(enabled.environment["KEEP_ME"] == "yes")

        let disabled = SharedFolderLaunchConfiguration.make(
            baseEnvironment: base,
            preference: SharedFolderPreference(path: shared.path, isEnabled: false),
            homeDirectory: home.path
        )
        #expect(disabled.sharedFolder == nil)
        #expect(disabled.environment == ["KEEP_ME": "yes"])

        let invalid = SharedFolderLaunchConfiguration.make(
            baseEnvironment: base,
            preference: SharedFolderPreference(path: home.path, isEnabled: true),
            homeDirectory: home.path
        )
        #expect(invalid.sharedFolder == nil)
        #expect(invalid.environment[SharedFolderPolicy.environmentKey] == nil)
    }

    @Test("menu state reports a remembered folder, its switch, and a stale-path problem")
    func menuState() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let shared = home.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        let on = SharedFolderMenuState.make(
            preference: SharedFolderPreference(path: shared.path, isEnabled: true),
            homeDirectory: home.path
        )
        #expect(on == SharedFolderMenuState(path: shared.path, displayPath: "~/Docs", isEnabled: true, problem: nil))

        let stale = SharedFolderMenuState.make(
            preference: SharedFolderPreference(path: home.path + "/Gone", isEnabled: true),
            homeDirectory: home.path
        )
        #expect(stale.isEnabled)
        #expect(stale.problem != nil)

        #expect(SharedFolderMenuState.make(preference: .disabled, homeDirectory: home.path) == .disabled)
    }
}

@Suite("Shared folder guest link name")
struct SharedFolderGuestLinkNameTests {
    @Test("the guest link takes the Mac folder's own name")
    func usesBasename() {
        #expect(SharedFolderPolicy.guestLinkName("/Users/someone/Work") == "Work")
        #expect(SharedFolderPolicy.guestLinkName("/Users/someone/Wörk Files/") == "Wörk Files")
        #expect(SharedFolderPolicy.guestLinkName("/") == "Mac")
    }
}

@Suite("Shared folder preferences")
struct SharedFolderPreferenceStoreTests {
    @Test("a chosen folder and its switch survive a relaunch")
    func persistsSelection() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }

        #expect(fixture.store.load() == .disabled)
        fixture.store.save(SharedFolderPreference(path: "/Users/me/Public", isEnabled: true))
        #expect(SharedFolderPreferenceStore(defaults: fixture.defaults).load()
            == SharedFolderPreference(path: "/Users/me/Public", isEnabled: true))
        fixture.store.save(SharedFolderPreference(path: "/Users/me/Public", isEnabled: false))
        #expect(fixture.store.load() == SharedFolderPreference(path: "/Users/me/Public", isEnabled: false))
        #expect(fixture.store.load().activePath == nil)
    }

    @Test("corrupt, relative, or future-schema values fall back to disabled")
    func rejectsCorruptValues() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }

        fixture.defaults.set(Data("junk".utf8), forKey: SharedFolderPreferenceStore.key)
        #expect(fixture.store.load() == .disabled)
        fixture.defaults.set(
            Data(#"{"schemaVersion":99,"path":"/x","isEnabled":true}"#.utf8),
            forKey: SharedFolderPreferenceStore.key
        )
        #expect(fixture.store.load() == .disabled)
        fixture.defaults.set(
            Data(#"{"schemaVersion":1,"path":"relative","isEnabled":true}"#.utf8),
            forKey: SharedFolderPreferenceStore.key
        )
        #expect(fixture.store.load() == .disabled)
        fixture.defaults.set(
            Data(#"{"schemaVersion":1,"path":null,"isEnabled":true}"#.utf8),
            forKey: SharedFolderPreferenceStore.key
        )
        #expect(fixture.store.load() == .disabled)
    }

    private final class DefaultsFixture {
        let suiteName = "dev.tryomarchy.native.tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: SharedFolderPreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = SharedFolderPreferenceStore(defaults: defaults)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
