import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu layout")
@MainActor
struct StartMenuWindowTests {
    @Test("missing-permission actions share one aligned column and launch text is centered")
    func permissionActionsAndLaunchTitleStayAligned() throws {
        _ = NSApplication.shared
        let menu = StartMenuWindow(
            accessibilityStatus: { false },
            microphoneStatus: { .notDetermined },
            requestAccessibility: {},
            requestMicrophone: { completion in completion(false) },
            canResetStorage: false,
            storageLocation: nil,
            storageLocationURL: nil,
            storageSpaceEstimate: { nil },
            resetStorage: {},
            launch: {}
        )
        menu.show()
        defer { menu.dismiss() }

        let content = try #require(
            NSApp.windows.first(where: { $0.isVisible && $0.title == "Try Omarchy" })?.contentView
        )
        content.layoutSubtreeIfNeeded()

        let accessibilityAction = try #require(
            descendant(withIdentifier: "permission-action-accessibility", in: content)
        )
        let microphoneAction = try #require(
            descendant(withIdentifier: "permission-action-mic", in: content)
        )
        let accessibilityFrame = accessibilityAction.convert(accessibilityAction.bounds, to: content)
        let microphoneFrame = microphoneAction.convert(microphoneAction.bounds, to: content)
        #expect(abs(accessibilityFrame.minX - microphoneFrame.minX) < 0.5)
        #expect(abs(accessibilityFrame.width - microphoneFrame.width) < 0.5)

        let launchButton = try #require(
            descendant(withIdentifier: "launch-button", in: content)
        )
        let launchLabel = try #require(
            descendant(withIdentifier: "launch-button-label", in: launchButton)
        )
        let labelFrame = launchLabel.convert(launchLabel.bounds, to: launchButton)
        #expect(abs(labelFrame.midX - launchButton.bounds.midX) <= 0.5)
        #expect(abs(labelFrame.midY - launchButton.bounds.midY) <= 0.5)
    }

    @Test("an initial update requirement updates first, then launches automatically")
    func updateActionTransitionsToLaunch() throws {
        _ = NSApplication.shared
        var updateCount = 0
        var launchCount = 0
        let menu = StartMenuWindow(
            accessibilityStatus: { true },
            microphoneStatus: { .authorized },
            requestAccessibility: {},
            requestMicrophone: { completion in completion(true) },
            canResetStorage: true,
            storageLocation: nil,
            storageLocationURL: nil,
            storageSpaceEstimate: { nil },
            resetStorage: {},
            primaryAction: .update,
            update: { updateCount += 1 },
            launch: { launchCount += 1 }
        )
        menu.show()
        defer { menu.dismiss() }

        let content = try #require(
            NSApp.windows.first(where: { $0.isVisible && $0.title == "Try Omarchy" })?.contentView
        )
        let initialButton = try #require(
            descendant(withIdentifier: "launch-button", in: content) as? NSButton
        )
        let initialLabel = try #require(
            descendant(withIdentifier: "launch-button-label", in: initialButton) as? NSTextField
        )
        #expect(initialLabel.stringValue == "Update Omarchy")
        #expect(initialButton.accessibilityLabel() == "Update Omarchy")

        initialButton.performClick(nil)
        #expect(updateCount == 1)
        #expect(launchCount == 0)
        let updatingLabel = try #require(
            descendant(withIdentifier: "launch-button-label", in: content) as? NSTextField
        )
        #expect(updatingLabel.stringValue == "Updating Omarchy…")

        menu.updateDidFinish(errorMessage: nil)
        #expect(launchCount == 1)
        let launchingLabel = try #require(
            descendant(withIdentifier: "launch-button-label", in: content) as? NSTextField
        )
        #expect(launchingLabel.stringValue == "Launching Omarchy…")
    }

    @Test("the start-menu state keeps update and reset as separate operations")
    func updateAndResetStateStaySeparate() {
        var state = VMStartMenuState(primaryAction: .update)
        #expect(state.primaryButtonTitle == "Update Omarchy")
        let didBeginReset = state.beginReset()
        #expect(didBeginReset)
        #expect(state.operation == .resetting)
        let didFinishReset = state.resetDidFinish(succeeded: false)
        #expect(didFinishReset)
        #expect(state.primaryButtonTitle == "Update Omarchy")

        let primaryAction = state.beginPrimaryAction()
        #expect(primaryAction == .update)
        #expect(state.primaryButtonTitle == "Updating Omarchy…")
        let didFinishUpdate = state.updateDidSucceed()
        #expect(didFinishUpdate)
        #expect(state.primaryButtonTitle == "Launching Omarchy…")
    }

    private func descendant(withIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = descendant(withIdentifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }
}
