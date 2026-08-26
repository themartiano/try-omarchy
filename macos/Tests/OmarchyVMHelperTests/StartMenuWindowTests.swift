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
            sharedFolderStatus: { .disabled },
            chooseSharedFolder: { _ in nil },
            setSharedFolderEnabled: { _ in },
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
