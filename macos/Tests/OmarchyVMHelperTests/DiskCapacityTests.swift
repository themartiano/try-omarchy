import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("VM disk capacity preferences")
struct DiskCapacityPreferenceTests {
    @Test("defaults to the current 24 GB capacity")
    func defaultsToCurrentCapacity() {
        let fixture = DefaultsFixture()

        #expect(fixture.store.load() == .default)
        #expect(fixture.store.load().gigabytes == 24)
    }

    @Test("persists valid capacities")
    func savesCapacity() throws {
        let fixture = DefaultsFixture()
        try fixture.store.save(DiskCapacityPreference(gigabytes: 120))

        let reopened = DiskCapacityPreferenceStore(defaults: fixture.defaults)
        #expect(reopened.load() == DiskCapacityPreference(gigabytes: 120))
        #expect(reopened.load().bytes == 120 * 1_073_741_824)
    }

    @Test("rejects capacities below 10 GB and above the supported maximum")
    func rejectsInvalidCapacity() {
        let fixture = DefaultsFixture()

        #expect(throws: DiskCapacityError.self) {
            try fixture.store.save(DiskCapacityPreference(gigabytes: 9))
        }
        #expect(throws: DiskCapacityError.self) {
            try fixture.store.save(DiskCapacityPreference(gigabytes: 8_193))
        }
        #expect(fixture.store.load() == .default)
    }

    @Test("invalid or future preferences fail safely")
    func invalidPreferencesUseDefault() throws {
        let fixture = DefaultsFixture()
        fixture.defaults.set(Data("junk".utf8), forKey: DiskCapacityPreferenceStore.key)
        #expect(fixture.store.load() == .default)

        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": DiskCapacityPreferenceStore.schemaVersion + 1,
            "gigabytes": 120,
        ])
        fixture.defaults.set(future, forKey: DiskCapacityPreferenceStore.key)
        #expect(fixture.store.load() == .default)
    }

    private final class DefaultsFixture {
        let suiteName = "DiskCapacityPreferenceTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: DiskCapacityPreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = DiskCapacityPreferenceStore(defaults: defaults)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("VM disk capacity launch configuration")
struct DiskCapacityLaunchConfigurationTests {
    @Test("publishes the selected capacity and replaces inherited values")
    func publishesCapacity() {
        let configured = DiskCapacityLaunchConfiguration.make(
            baseEnvironment: [
                "KEEP_ME": "yes",
                DiskCapacityLaunchConfiguration.environmentKey: "999",
            ],
            preference: DiskCapacityPreference(gigabytes: 80)
        )

        #expect(configured.environment == [
            "KEEP_ME": "yes",
            DiskCapacityLaunchConfiguration.environmentKey: "80",
        ])
    }
}
