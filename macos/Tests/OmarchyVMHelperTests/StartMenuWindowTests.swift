import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu layout", .serialized)
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
        #expect(accessibilityAction.frame.height >= 28)
        #expect(microphoneAction.frame.height >= 28)
        #expect((accessibilityAction as? NSButton)?.controlSize == .regular)
        #expect((microphoneAction as? NSButton)?.controlSize == .regular)

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

    @Test("shared folder paths keep separate compact lines and actions stay aligned")
    func sharedFolderDetailsStayVisible() throws {
        _ = NSApplication.shared
        let macPath = "~/Projects/a-very-long-folder-name-that-needs-middle-truncation"
        let guestPath = "~/a-very-long-folder-name-that-needs-middle-truncation"
        var sharedFolderEnabled = true
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
            sharedFolderStatus: {
                SharedFolderMenuState(
                    path: "/Users/test/Projects/a-very-long-folder-name-that-needs-middle-truncation",
                    displayPath: macPath,
                    isEnabled: sharedFolderEnabled,
                    problem: nil
                )
            },
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

        let macLine = try #require(
            descendant(withIdentifier: "permission-detail-folder-0", in: content) as? NSTextField
        )
        let guestLine = try #require(
            descendant(withIdentifier: "permission-detail-folder-1", in: content) as? NSTextField
        )
        #expect(macLine.stringValue == "Mac folder: \(macPath)")
        #expect(guestLine.stringValue == "In Omarchy: \(guestPath)")
        #expect(macLine.maximumNumberOfLines == 1)
        #expect(guestLine.maximumNumberOfLines == 1)
        #expect(macLine.lineBreakMode == .byTruncatingMiddle)
        #expect(guestLine.lineBreakMode == .byTruncatingMiddle)
        #expect(macLine.frame.height > 0)
        #expect(guestLine.frame.height > 0)

        let choose = try #require(
            descendant(withIdentifier: "permission-action-folder-0", in: content) as? NSButton
        )
        let turnOff = try #require(
            descendant(withIdentifier: "permission-action-folder-1", in: content) as? NSButton
        )
        #expect(choose.controlSize == .regular)
        #expect(turnOff.controlSize == .regular)
        #expect(choose.frame.height >= 28)
        #expect(turnOff.frame.height >= 28)
        #expect(abs(choose.frame.width - turnOff.frame.width) < 0.5)
        #expect(abs(choose.frame.width - 124) < 0.5)
        let chooseFrame = choose.convert(choose.bounds, to: content)
        let turnOffFrame = turnOff.convert(turnOff.bounds, to: content)
        #expect(abs(chooseFrame.minY - turnOffFrame.maxY - 2) < 0.5)

        try expectPermissionColumnsAligned(in: content)

        sharedFolderEnabled = false
        menu.refreshPermissionStatus()
        content.layoutSubtreeIfNeeded()
        try expectPermissionColumnsAligned(in: content)
    }

    private func expectPermissionColumnsAligned(in content: NSView) throws {
        let accessibilityRow = try #require(
            descendant(withIdentifier: "permission-row-accessibility", in: content)
        )
        let folderRow = try #require(
            descendant(withIdentifier: "permission-row-folder", in: content)
        )
        let accessibilitySymbol = try #require(
            descendant(withIdentifier: "permission-symbol-accessibility", in: content)
        )
        let folderSymbol = try #require(
            descendant(withIdentifier: "permission-symbol-folder", in: content)
        )
        let accessibilityTitle = try #require(
            descendant(withIdentifier: "permission-title-accessibility", in: content)
        )
        let folderTitle = try #require(
            descendant(withIdentifier: "permission-title-folder", in: content)
        )
        let folderStatus = try #require(
            descendant(withIdentifier: "permission-status-folder", in: content)
        )
        let accessibilityAction = try #require(
            descendant(withIdentifier: "permission-action-accessibility", in: content)
        )
        let folderChooseAction = try #require(
            descendant(withIdentifier: "permission-action-folder-0", in: content)
        )
        let folderToggleAction = try #require(
            descendant(withIdentifier: "permission-action-folder-1", in: content)
        )

        let accessibilityRowFrame = accessibilityRow.convert(accessibilityRow.bounds, to: content)
        let folderRowFrame = folderRow.convert(folderRow.bounds, to: content)
        let accessibilitySymbolFrame = accessibilitySymbol.convert(accessibilitySymbol.bounds, to: content)
        let folderSymbolFrame = folderSymbol.convert(folderSymbol.bounds, to: content)
        let accessibilityTitleFrame = accessibilityTitle.convert(accessibilityTitle.bounds, to: content)
        let folderTitleFrame = folderTitle.convert(folderTitle.bounds, to: content)
        let folderStatusFrame = folderStatus.convert(folderStatus.bounds, to: content)
        let accessibilityActionFrame = accessibilityAction.convert(accessibilityAction.bounds, to: content)
        let folderChooseActionFrame = folderChooseAction.convert(folderChooseAction.bounds, to: content)
        let folderToggleActionFrame = folderToggleAction.convert(folderToggleAction.bounds, to: content)

        #expect(abs(accessibilityRowFrame.minX - folderRowFrame.minX) < 0.5)
        #expect(abs(accessibilityRowFrame.width - folderRowFrame.width) < 0.5)
        #expect(abs(accessibilitySymbolFrame.minX - folderSymbolFrame.minX) < 0.5)
        #expect(abs(accessibilityTitleFrame.minX - folderTitleFrame.minX) < 0.5)
        #expect(abs(accessibilityActionFrame.maxX - folderChooseActionFrame.maxX) < 0.5)
        #expect(abs(accessibilityActionFrame.maxX - folderToggleActionFrame.maxX) < 0.5)
        #expect(folderRowFrame.height >= 100)
        #expect(folderRowFrame.maxY - folderStatusFrame.maxY >= 6)
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
