import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Host audio routing")
struct AudioDevicesTests {
    @Test("guest route requests use a strict direction-aware schema")
    func guestRouteRequestSchema() throws {
        let output = try #require(
            NativeAudioRouteRequest.decode(Data(
                #"{"deviceUID":"speaker","direction":"output","type":"select"}"#.utf8
            ))
        )
        let systemInput = try #require(
            NativeAudioRouteRequest.decode(Data(
                #"{"deviceUID":null,"direction":"input","type":"select"}"#.utf8
            ))
        )

        #expect(output == .init(direction: .output, deviceUID: "speaker"))
        #expect(systemInput == .init(direction: .input, deviceUID: nil))
        #expect(NativeAudioRouteRequest.decode(Data(
            #"{"deviceUID":"speaker","direction":"output","extra":true,"type":"select"}"#.utf8
        )) == nil)
    }

    @Test("route files publish canonical base64 and an unambiguous default sentinel")
    func routeControlFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-audio-route-tests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NativeAudioRouteFileStore(directoryPath: directory.path)

        try store.publish("Studio Display", for: .output)
        try store.publish(nil, for: .input)

        #expect(try String(contentsOf: directory.appendingPathComponent("output"), encoding: .utf8)
            == "U3R1ZGlvIERpc3BsYXk=\n")
        #expect(try String(contentsOf: directory.appendingPathComponent("input"), encoding: .utf8)
            == "default\n")
    }

    @Test("empty preferences use System Default for both directions")
    func emptyPreferencesUseSystemDefaults() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }

        #expect(fixture.store.load() == .systemDefaults)
    }

    @Test("speaker and microphone UIDs persist together across a relaunch")
    func preferencesRoundTrip() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let expected = AudioRoutingPreferences(
            output: .device(uid: "output-uid", lastKnownName: "Studio Display"),
            input: .device(uid: "input-uid", lastKnownName: "Desk Microphone")
        )

        fixture.store.save(expected)
        let reopened = AudioRoutingPreferenceStore(defaults: fixture.defaults)

        #expect(reopened.load() == expected)
        #expect(fixture.defaults.data(forKey: AudioRoutingPreferenceStore.key) != nil)
    }

    @Test("updating one direction preserves the other direction")
    func directionUpdatesAreAtomic() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        fixture.store.save(AudioRoutingPreferences(
            output: .device(uid: "speaker", lastKnownName: "Speaker"),
            input: .device(uid: "microphone", lastKnownName: "Microphone")
        ))

        fixture.store.set(.systemDefault, for: .input)

        #expect(fixture.store.load() == AudioRoutingPreferences(
            output: .device(uid: "speaker", lastKnownName: "Speaker"),
            input: .systemDefault
        ))
    }

    @Test("corrupt and future preference schemas fail safely without rewriting data")
    func invalidPreferencesFailSafely() throws {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let future = try #require(
            """
            {"schemaVersion":99,"output":{"kind":"systemDefault"},"input":{"kind":"systemDefault"}}
            """.data(using: .utf8)
        )
        fixture.defaults.set(future, forKey: AudioRoutingPreferenceStore.key)

        #expect(fixture.store.load() == .systemDefaults)
        #expect(fixture.defaults.data(forKey: AudioRoutingPreferenceStore.key) == future)

        let corrupt = Data("not-json".utf8)
        fixture.defaults.set(corrupt, forKey: AudioRoutingPreferenceStore.key)
        #expect(fixture.store.load() == .systemDefaults)
        #expect(fixture.defaults.data(forKey: AudioRoutingPreferenceStore.key) == corrupt)
    }

    @Test("SDL duplicate suffixes are recreated independently by direction")
    func recreatesSDLNames() {
        let catalog = HostAudioDeviceCatalog.make(from: [
            .init(uid: "a", outputName: "Display Audio", inputName: "Desk Mic"),
            .init(uid: "b", outputName: "Display Audio ", inputName: "Desk Mic"),
            .init(uid: "c", outputName: nil, inputName: "Camera Mic"),
        ])

        #expect(catalog.device(uid: "a", direction: .output)?.sdlName == "Display Audio")
        #expect(catalog.device(uid: "b", direction: .output)?.sdlName == "Display Audio (2)")
        #expect(catalog.device(uid: "a", direction: .input)?.sdlName == "Desk Mic")
        #expect(catalog.device(uid: "b", direction: .input)?.sdlName == "Desk Mic (2)")
        #expect(catalog.device(uid: "c", direction: .output) == nil)
        #expect(catalog.device(uid: "c", direction: .input)?.sdlName == "Camera Mic")
    }

    @Test("an unavailable saved UID uses effective default without losing the preference")
    func unavailableSelectionFallsBack() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanUp() }
        let preferences = AudioRoutingPreferences(
            output: .device(uid: "disconnected", lastKnownName: "Travel Headphones"),
            input: .systemDefault
        )
        fixture.store.save(preferences)

        let configuration = AudioLaunchConfiguration.make(
            baseEnvironment: [:],
            preferences: fixture.store.load(),
            catalog: .empty
        )

        #expect(configuration.routes.outputSDLName == nil)
        #expect(configuration.environment[AudioLaunchConfiguration.outputDeviceNameKey] == nil)
        #expect(fixture.store.load() == preferences)
    }

    @Test("launch environment selects input and output independently and removes SDL override")
    func createsSanitizedEnvironment() {
        let catalog = HostAudioDeviceCatalog.make(from: [
            .init(uid: "speaker", outputName: "External Speaker", inputName: nil),
            .init(uid: "microphone", outputName: nil, inputName: "USB Microphone"),
        ])
        let preferences = AudioRoutingPreferences(
            output: .device(uid: "speaker", lastKnownName: "External Speaker"),
            input: .device(uid: "microphone", lastKnownName: "USB Microphone")
        )
        let configuration = AudioLaunchConfiguration.make(
            baseEnvironment: [
                "KEEP_ME": "yes",
                AudioLaunchConfiguration.inheritedSDLDeviceNameKey: "global override",
                AudioLaunchConfiguration.outputDeviceNameKey: "stale output",
                AudioLaunchConfiguration.inputDeviceNameKey: "stale input",
            ],
            preferences: preferences,
            catalog: catalog
        )

        #expect(configuration.environment["KEEP_ME"] == "yes")
        #expect(configuration.environment[AudioLaunchConfiguration.inheritedSDLDeviceNameKey] == nil)
        #expect(configuration.environment[AudioLaunchConfiguration.outputDeviceNameKey] == "External Speaker")
        #expect(configuration.environment[AudioLaunchConfiguration.inputDeviceNameKey] == "USB Microphone")
    }

    @Test("System Default emits no explicit device variables")
    func systemDefaultEmitsNoDeviceNames() {
        let configuration = AudioLaunchConfiguration.make(
            baseEnvironment: [
                AudioLaunchConfiguration.inheritedSDLDeviceNameKey: "override",
                AudioLaunchConfiguration.outputDeviceNameKey: "old output",
                AudioLaunchConfiguration.inputDeviceNameKey: "old input",
            ],
            preferences: .systemDefaults,
            catalog: .empty
        )

        #expect(configuration.routes == ResolvedAudioRoutes(
            outputSDLName: nil,
            inputSDLName: nil
        ))
        #expect(configuration.environment.isEmpty)
    }

    private final class DefaultsFixture {
        let suiteName = "dev.tryomarchy.native.tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: AudioRoutingPreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = AudioRoutingPreferenceStore(defaults: defaults)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("VM run lifecycle")
struct VMRunLifecycleTests {
    @Test("quit drains the child exactly once")
    func quitDrainsChild() {
        var lifecycle = VMRunLifecycle()
        lifecycle.requestQuit()
        #expect(lifecycle.isStopping)
        lifecycle.childExited()
        #expect(!lifecycle.isStopping)
    }

    @Test("an external signal drains the child exactly once")
    func signalDrainsChild() {
        var lifecycle = VMRunLifecycle()
        lifecycle.requestTermination(signal: 15)
        #expect(lifecycle.isStopping)
        lifecycle.childExited()
        #expect(!lifecycle.isStopping)
    }

    @Test("a forced VM close after launch is not reported as a startup failure")
    func forcedCloseAfterLaunchDoesNotWarn() {
        let decision = VMExitPresentationDecision.make(
            status: 137,
            reachedVirtualMachineStart: true,
            wasStopping: false
        )
        #expect(!decision.showsStartupFailure)
    }

    @Test("an app termination during launch is not reported as a startup failure")
    func terminationDuringLaunchDoesNotWarn() {
        let decision = VMExitPresentationDecision.make(
            status: 143,
            reachedVirtualMachineStart: false,
            wasStopping: true
        )
        #expect(!decision.showsStartupFailure)
    }

    @Test("a genuine non-zero exit before launch still reports a startup failure")
    func genuineStartupFailureWarns() {
        let decision = VMExitPresentationDecision.make(
            status: 1,
            reachedVirtualMachineStart: false,
            wasStopping: false
        )
        #expect(decision.showsStartupFailure)
        #expect(!decision.requiresWorkspaceReset)
        #expect(!decision.requiresBootRecoveryConsent)
        #expect(!decision.reportsBootRecoveryFailure)
    }

    @Test("an incompatible saved VM stays on the start menu for reset")
    func incompatibleWorkspaceOffersReset() {
        let decision = VMExitPresentationDecision.make(
            status: VMExitPresentationDecision.incompatibleWorkspaceStatus,
            reachedVirtualMachineStart: false,
            wasStopping: false
        )
        #expect(!decision.showsStartupFailure)
        #expect(decision.requiresWorkspaceReset)
        #expect(!decision.requiresBootRecoveryConsent)
        #expect(!decision.reportsBootRecoveryFailure)
    }

    @Test("boot recovery consent is requested only before the VM starts")
    func bootRecoveryConsentIsAStartupDecision() {
        let required = VMExitPresentationDecision.make(
            status: VMExitPresentationDecision.bootRecoveryConsentRequiredStatus,
            reachedVirtualMachineStart: false,
            wasStopping: false
        )
        #expect(!required.showsStartupFailure)
        #expect(!required.requiresWorkspaceReset)
        #expect(required.requiresBootRecoveryConsent)

        let afterStart = VMExitPresentationDecision.make(
            status: VMExitPresentationDecision.bootRecoveryConsentRequiredStatus,
            reachedVirtualMachineStart: true,
            wasStopping: false
        )
        #expect(!afterStart.requiresBootRecoveryConsent)

        let whileStopping = VMExitPresentationDecision.make(
            status: VMExitPresentationDecision.bootRecoveryConsentRequiredStatus,
            reachedVirtualMachineStart: false,
            wasStopping: true
        )
        #expect(!whileStopping.requiresBootRecoveryConsent)
    }

    @Test("a failed boot recovery stays on the start menu with a specific error")
    func bootRecoveryFailureIsSpecific() {
        let failed = VMExitPresentationDecision.make(
            status: VMExitPresentationDecision.bootRecoveryFailedStatus,
            reachedVirtualMachineStart: false,
            wasStopping: false
        )
        #expect(!failed.showsStartupFailure)
        #expect(!failed.requiresWorkspaceReset)
        #expect(!failed.requiresBootRecoveryConsent)
        #expect(failed.reportsBootRecoveryFailure)

        let whileStopping = VMExitPresentationDecision.make(
            status: VMExitPresentationDecision.bootRecoveryFailedStatus,
            reachedVirtualMachineStart: false,
            wasStopping: true
        )
        #expect(!whileStopping.reportsBootRecoveryFailure)
    }
}
