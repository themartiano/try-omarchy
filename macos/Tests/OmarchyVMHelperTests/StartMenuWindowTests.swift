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
            storageLocation: "~/Library/Application Support/Try Omarchy",
            storageLocationURL: URL(
                fileURLWithPath: "/Users/test/Library/Application Support/Try Omarchy"
            ),
            storageSpaceEstimate: { nil },
            resetStorage: {},
            sharedFolderStatus: { .disabled },
            chooseSharedFolder: { _ in nil },
            setSharedFolderEnabled: { _ in },
            immersiveMode: { true },
            setImmersiveMode: { _ in },
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
        let launchFrame = launchButton.convert(launchButton.bounds, to: content)
        #expect(launchFrame.minY >= content.bounds.minY)
        #expect(launchFrame.maxY <= content.bounds.maxY)
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
            immersiveMode: { true },
            setImmersiveMode: { _ in },
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

    @Test("Immersive toggle explains how to leave both Full Screen modes")
    func immersiveToggleUpdatesItsGuidance() throws {
        _ = NSApplication.shared
        var isImmersive = true
        var savedChoices: [Bool] = []
        let menu = StartMenuWindow(
            accessibilityStatus: { true },
            microphoneStatus: { .authorized },
            requestAccessibility: {},
            requestMicrophone: { completion in completion(true) },
            canResetStorage: false,
            storageLocation: nil,
            storageLocationURL: nil,
            storageSpaceEstimate: { nil },
            resetStorage: {},
            sharedFolderStatus: { .disabled },
            chooseSharedFolder: { _ in nil },
            setSharedFolderEnabled: { _ in },
            immersiveMode: { isImmersive },
            setImmersiveMode: { choice in
                isImmersive = choice
                savedChoices.append(choice)
            },
            launch: {}
        )
        menu.show()
        defer { menu.dismiss() }

        let content = try #require(
            NSApp.windows.first(where: { $0.isVisible && $0.title == "Try Omarchy" })?.contentView
        )
        content.layoutSubtreeIfNeeded()

        let immersiveToggle = try #require(
            descendant(withIdentifier: "immersive-toggle", in: content) as? NSSwitch
        )
        let immersiveCaption = try #require(
            descendant(withIdentifier: "immersive-caption", in: content) as? NSTextField
        )
        let immersiveRow = try #require(
            descendant(withIdentifier: "immersive-row", in: content)
        )
        let launchButton = try #require(
            descendant(withIdentifier: "launch-button", in: content)
        )
        #expect(immersiveToggle.state == .on)
        #expect(immersiveCaption.stringValue.contains("Control-Option-G, then Command-F"))
        #expect(immersiveToggle.accessibilityLabel() == "Immersive mode")
        #expect(immersiveToggle.accessibilityHelp() == immersiveCaption.stringValue)
        #expect(immersiveToggle.frame.height >= 24)
        #expect(immersiveCaption.frame.height > 0)
        let immersiveRowFrame = immersiveRow.convert(immersiveRow.bounds, to: content)
        #expect(immersiveRowFrame.minY >= content.bounds.minY)
        #expect(immersiveRowFrame.maxY <= content.bounds.maxY)
        let launchButtonFrame = launchButton.convert(launchButton.bounds, to: content)
        #expect(launchButtonFrame.minY >= content.bounds.minY)
        #expect(launchButtonFrame.maxY <= content.bounds.maxY)

        content.window?.makeFirstResponder(immersiveToggle)
        immersiveToggle.performClick(nil)
        content.layoutSubtreeIfNeeded()

        #expect(savedChoices == [false])
        #expect(content.window?.firstResponder === immersiveToggle)
        let standardToggle = try #require(
            descendant(withIdentifier: "immersive-toggle", in: content) as? NSSwitch
        )
        let standardCaption = try #require(
            descendant(withIdentifier: "immersive-caption", in: content) as? NSTextField
        )
        #expect(standardToggle.state == .off)
        #expect(standardCaption.stringValue ==
            "Move the pointer to the top of the screen, then choose View › Exit Full Screen or press Command-F.")
        #expect(standardToggle.accessibilityHelp() == standardCaption.stringValue)

        menu.refreshPermissionStatus()
        content.layoutSubtreeIfNeeded()
        let refreshedToggle = try #require(
            descendant(withIdentifier: "immersive-toggle", in: content) as? NSSwitch
        )
        let refreshedCaption = try #require(
            descendant(withIdentifier: "immersive-caption", in: content) as? NSTextField
        )
        #expect(refreshedToggle.state == .off)
        #expect(refreshedCaption.stringValue == standardCaption.stringValue)
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
