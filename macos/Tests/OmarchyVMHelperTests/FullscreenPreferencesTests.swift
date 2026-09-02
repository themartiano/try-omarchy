import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Full Screen preferences")
struct FullscreenPreferenceStoreTests {
    @Test("Immersive mode is on until the user changes it")
    func defaultsToImmersive() {
        let fixture = DefaultsFixture()

        #expect(fixture.store.load() == .defaults)
        #expect(fixture.store.load().isImmersive)
    }

    @Test("Immersive choice persists")
    func savesChoice() {
        let fixture = DefaultsFixture()
        fixture.store.save(FullscreenPreferences(isImmersive: false))

        let reopened = FullscreenPreferenceStore(defaults: fixture.defaults)
        #expect(reopened.load() == FullscreenPreferences(isImmersive: false))
    }

    @Test("Invalid or future preferences fail safely")
    func invalidPreferencesUseDefault() throws {
        let fixture = DefaultsFixture()
        fixture.defaults.set(Data("junk".utf8), forKey: FullscreenPreferenceStore.key)
        #expect(fixture.store.load() == .defaults)

        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": FullscreenPreferenceStore.schemaVersion + 1,
            "isImmersive": false,
        ])
        fixture.defaults.set(future, forKey: FullscreenPreferenceStore.key)
        #expect(fixture.store.load() == .defaults)
    }

    private final class DefaultsFixture {
        let suiteName = "FullscreenPreferenceStoreTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: FullscreenPreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = FullscreenPreferenceStore(defaults: defaults)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("Full Screen launch configuration")
struct FullscreenLaunchConfigurationTests {
    @Test("Publishes immersive mode and replaces inherited values")
    func publishesChoice() {
        let inherited = [
            "KEEP_ME": "yes",
            FullscreenLaunchConfiguration.immersiveEnvironmentKey: "invalid",
        ]

        let immersive = FullscreenLaunchConfiguration.make(
            baseEnvironment: inherited,
            preferences: FullscreenPreferences(isImmersive: true)
        )
        #expect(immersive.environment["KEEP_ME"] == "yes")
        #expect(immersive.environment[FullscreenLaunchConfiguration.immersiveEnvironmentKey] == "1")

        let windowed = FullscreenLaunchConfiguration.make(
            baseEnvironment: inherited,
            preferences: FullscreenPreferences(isImmersive: false)
        )
        #expect(windowed.environment["KEEP_ME"] == "yes")
        #expect(windowed.environment[FullscreenLaunchConfiguration.immersiveEnvironmentKey] == "0")
    }
}
