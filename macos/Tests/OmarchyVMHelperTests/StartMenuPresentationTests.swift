import Testing
@testable import OmarchyVMHelper

@Suite("Start menu presentation")
struct StartMenuPresentationTests {
    @Test("the reset notice describes actual compatibility failures, not app updates")
    func incompatibleWorkspaceNotice() {
        let detail = StartMenuPresentation.incompatibleWorkspaceDetail
        #expect(detail.contains("storage or boot format"))
        #expect(detail.contains("multiple saved VMs"))
        #expect(detail.contains("permanently erases"))
        #expect(!detail.contains("different Try Omarchy build"))
    }

    @Test("boot recovery notice promises preservation and no automatic upgrade")
    func bootRecoveryNotice() {
        let detail = StartMenuPresentation.bootRecoveryConfirmationDetail
        #expect(detail.contains("one-time, read-only"))
        #expect(detail.contains("saved disk"))
        #expect(detail.contains("data remain intact"))
        #expect(detail.contains("factory image"))
        #expect(detail.contains("does not reset"))
        #expect(detail.contains("upgrade Omarchy"))
    }

    @Test("continuing the one-time prompt grants consent for only that launch")
    func bootRecoveryContinue() {
        var promptCount = 0
        let decision = BootRecoveryLaunchGate.decide(
            preflight: .requiresConfirmation,
            confirm: {
                promptCount += 1
                return true
            }
        )
        #expect(promptCount == 1)
        #expect(decision == .launch(allowBootRecovery: true))
    }

    @Test("cancelling the one-time prompt aborts launch")
    func bootRecoveryCancel() {
        var promptCount = 0
        let decision = BootRecoveryLaunchGate.decide(
            preflight: .requiresConfirmation,
            confirm: {
                promptCount += 1
                return false
            }
        )
        #expect(promptCount == 1)
        #expect(decision == .cancel)
    }

    @Test("a paired VM suppresses the prompt and launches without consent")
    func pairedVMSuppressesRecoveryPrompt() {
        var promptCount = 0
        let decision = BootRecoveryLaunchGate.decide(
            preflight: .notRequired,
            confirm: {
                promptCount += 1
                return true
            }
        )
        #expect(promptCount == 0)
        #expect(decision == .launch(allowBootRecovery: false))
    }

    @Test("the recovery handshake retries at most once per confirmation")
    func bootRecoveryHandshakeIsBounded() {
        let consentRequired = VMExitPresentationDecision.make(
            status: VMExitPresentationDecision.bootRecoveryConsentRequiredStatus,
            reachedVirtualMachineStart: false,
            wasStopping: false
        )
        #expect(BootRecoveryChildExitGate.decide(
            presentation: consentRequired,
            launchWasAuthorized: false
        ) == .requestConfirmation)

        let accepted = BootRecoveryLaunchGate.decide(
            preflight: .requiresConfirmation,
            confirm: { true }
        )
        #expect(accepted == .launch(allowBootRecovery: true))
        #expect(BootRecoveryChildExitGate.decide(
            presentation: consentRequired,
            launchWasAuthorized: true
        ) == .reportFailure)

        let recoveryFailed = VMExitPresentationDecision.make(
            status: VMExitPresentationDecision.bootRecoveryFailedStatus,
            reachedVirtualMachineStart: false,
            wasStopping: false
        )
        #expect(BootRecoveryChildExitGate.decide(
            presentation: recoveryFailed,
            launchWasAuthorized: true
        ) == .reportFailure)
        #expect(BootRecoveryLaunchGate.decide(
            preflight: .requiresConfirmation,
            confirm: { false }
        ) == .cancel)
    }

    @Test("microphone permission states offer only valid actions")
    func microphoneStates() {
        let authorized = StartMenuPresentation.microphone(
            state: .authorized,
            requestInFlight: false
        )
        #expect(authorized.isGranted)
        #expect(authorized.action == nil)
        #expect(authorized.actionTitle == nil)

        let undecided = StartMenuPresentation.microphone(
            state: .notDetermined,
            requestInFlight: false
        )
        #expect(!undecided.isGranted)
        #expect(undecided.action == .request)
        #expect(undecided.actionTitle == "Allow…")
        #expect(undecided.detail.contains("Optional"))

        let waiting = StartMenuPresentation.microphone(
            state: .notDetermined,
            requestInFlight: true
        )
        #expect(waiting.action == .request)
        #expect(waiting.actionTitle == "Waiting…")

        let denied = StartMenuPresentation.microphone(
            state: .denied,
            requestInFlight: false
        )
        #expect(denied.action == .openSettings)
        #expect(denied.actionTitle == "Open Settings")
        #expect(denied.detail.contains("Speaker playback will still work"))

        let restricted = StartMenuPresentation.microphone(
            state: .restricted,
            requestInFlight: false
        )
        #expect(!restricted.isGranted)
        #expect(restricted.action == nil)
        #expect(restricted.actionTitle == nil)
    }

    @Test("camera permission states keep camera access optional and recoverable")
    func cameraStates() {
        let authorized = StartMenuPresentation.camera(
            state: .authorized,
            requestInFlight: false
        )
        #expect(authorized.isGranted)
        #expect(authorized.action == nil)

        let undecided = StartMenuPresentation.camera(
            state: .notDetermined,
            requestInFlight: false
        )
        #expect(undecided.action == .request)
        #expect(undecided.actionTitle == "Allow…")
        #expect(undecided.detail.contains("Optional"))

        let waiting = StartMenuPresentation.camera(
            state: .notDetermined,
            requestInFlight: true
        )
        #expect(waiting.actionTitle == "Waiting…")

        let denied = StartMenuPresentation.camera(
            state: .denied,
            requestInFlight: false
        )
        #expect(denied.action == .openSettings)
        #expect(denied.actionTitle == "Open Settings")

        let restricted = StartMenuPresentation.camera(
            state: .restricted,
            requestInFlight: false
        )
        #expect(!restricted.isGranted)
        #expect(restricted.action == nil)
    }

    @Test("shared folder states distinguish absent, disabled, enabled, and broken shares")
    func sharedFolderStates() {
        let absent = StartMenuPresentation.sharedFolder(state: .disabled)
        #expect(!absent.isGranted)
        #expect(absent.compactDetailLines == nil)
        #expect(absent.toggleActionTitle == nil)

        let disabled = StartMenuPresentation.sharedFolder(
            state: SharedFolderMenuState(
                path: "/Users/test/Projects/demo",
                displayPath: "~/Projects/demo",
                isEnabled: false,
                problem: nil
            )
        )
        #expect(!disabled.isGranted)
        #expect(disabled.compactDetailLines == [
            "Mac folder: ~/Projects/demo",
            "In Omarchy: Off",
        ])
        #expect(disabled.toggleActionTitle == "Turn On")

        let enabled = StartMenuPresentation.sharedFolder(
            state: SharedFolderMenuState(
                path: "/Users/test/Projects/demo",
                displayPath: "~/Projects/demo",
                isEnabled: true,
                problem: nil
            )
        )
        #expect(enabled.isGranted)
        #expect(enabled.compactDetailLines == [
            "Mac folder: ~/Projects/demo",
            "In Omarchy: ~/demo",
        ])
        #expect(enabled.toggleActionTitle == "Turn Off")

        let broken = StartMenuPresentation.sharedFolder(
            state: SharedFolderMenuState(
                path: "/Volumes/Missing/demo",
                displayPath: "/Volumes/Missing/demo",
                isEnabled: true,
                problem: "The selected folder is unavailable."
            )
        )
        #expect(!broken.isGranted)
        #expect(broken.detail == "The selected folder is unavailable.")
        #expect(broken.compactDetailLines == nil)
        #expect(broken.toggleActionTitle == "Turn Off")
    }

    @Test("port summary covers empty, single, and multiple mappings")
    func portForwardingStates() {
        let empty = StartMenuPresentation.portForwarding(mappings: [])
        #expect(!empty.isGranted)
        #expect(empty.compactDetailLines == nil)

        let single = StartMenuPresentation.portForwarding(mappings: [
            PortForwardMapping(hostPort: 2222, guestPort: 22, protocol: .tcp),
        ])
        #expect(single.isGranted)
        #expect(single.grantedStatusLabel == "●  1 Port")
        #expect(single.compactDetailLines == [
            "Mac: localhost:2222",
            "Omarchy: port 22 · TCP",
        ])

        let multiple = StartMenuPresentation.portForwarding(mappings: [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
        ])
        #expect(multiple.isGranted)
        #expect(multiple.grantedStatusLabel == "●  2 Ports")
        #expect(multiple.compactDetailLines == [
            "2 localhost mappings",
            "Available only on this Mac",
        ])
    }

    @Test("immersive guidance describes fullscreen presentation only")
    func immersiveGuidance() {
        #expect(StartMenuPresentation.immersiveDetail(isEnabled: true)
            == "Mac menu bar and Dock stay hidden while Omarchy is Full Screen.")
        #expect(StartMenuPresentation.immersiveDetail(isEnabled: false)
            == "Mac menu bar and Dock remain available at the screen edges while Omarchy is Full Screen.")
    }
}
