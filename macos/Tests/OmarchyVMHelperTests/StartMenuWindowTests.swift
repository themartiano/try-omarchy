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

        let menuScroll = try #require(
            descendant(withIdentifier: "start-menu-scroll", in: content) as? NSScrollView
        )
        let menuDocument = try #require(menuScroll.documentView)
        menuDocument.layoutSubtreeIfNeeded()
        #expect(menuScroll.hasVerticalScroller)
        #expect(menuDocument.frame.height >= menuScroll.contentView.bounds.height)

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

    @Test("a reduced-height menu preserves its scroll position across refresh")
    func reducedHeightPreservesScrollPosition() throws {
        _ = NSApplication.shared
        var microphoneState = MicrophoneAuthorizationState.notDetermined
        let menu = StartMenuWindow(
            accessibilityStatus: { false },
            microphoneStatus: { microphoneState },
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

        let window = try #require(
            NSApp.windows.first(where: { $0.isVisible && $0.title == "Try Omarchy" })
        )
        window.setContentSize(NSSize(width: 600, height: 480))
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()

        let originalScroll = try #require(
            descendant(withIdentifier: "start-menu-scroll", in: content) as? NSScrollView
        )
        let originalDocument = try #require(originalScroll.documentView)
        originalDocument.layoutSubtreeIfNeeded()
        let maximumOffset = originalDocument.frame.height
            - originalScroll.contentView.bounds.height
        #expect(maximumOffset > 100)
        let expectedOffset = min(140, maximumOffset)
        originalScroll.contentView.scroll(to: NSPoint(x: 0, y: expectedOffset))
        originalScroll.reflectScrolledClipView(originalScroll.contentView)
        #expect(abs(originalScroll.contentView.bounds.minY - expectedOffset) < 0.5)

        microphoneState = .denied
        menu.refreshPermissionStatus()
        content.layoutSubtreeIfNeeded()

        let refreshedScroll = try #require(
            descendant(withIdentifier: "start-menu-scroll", in: content) as? NSScrollView
        )
        refreshedScroll.documentView?.layoutSubtreeIfNeeded()
        #expect(refreshedScroll !== originalScroll)
        #expect(abs(refreshedScroll.contentView.bounds.minY - expectedOffset) < 0.5)
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

    @Test("port forwarding stays summarized while add, save, reopen, and remove happen in a sheet")
    func portForwardingUsesFocusedEditor() throws {
        _ = NSApplication.shared
        var mappings: [PortForwardMapping] = []
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
            portForwardingStatus: { mappings },
            savePortForwarding: {
                mappings = $0
                return nil
            },
            launch: {}
        )
        menu.show()
        defer { menu.dismiss() }

        let mainWindow = try #require(
            NSApp.windows.first(where: { $0.isVisible && $0.title == "Try Omarchy" })
        )
        let content = try #require(mainWindow.contentView)
        content.layoutSubtreeIfNeeded()
        let initialStatus = try #require(
            descendant(withIdentifier: "permission-status-network", in: content) as? NSTextField
        )
        #expect(initialStatus.stringValue == "○  Off")

        let configure = try #require(
            descendant(withIdentifier: "permission-action-network", in: content) as? NSButton
        )
        configure.performClick(nil)
        let editorContent = try #require(menu.portForwardingEditor?.window.contentView)
        let add = try #require(
            descendant(withIdentifier: "port-forward-add", in: editorContent) as? NSButton
        )
        add.performClick(nil)

        let host = try #require(
            descendant(withIdentifier: "port-forward-host-0", in: editorContent) as? NSTextField
        )
        let guest = try #require(
            descendant(withIdentifier: "port-forward-guest-0", in: editorContent) as? NSTextField
        )
        let editor = try #require(host.delegate as? PortForwardingEditor)
        host.stringValue = "8080"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: host))
        guest.stringValue = "3000"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: guest))
        let save = try #require(
            descendant(withIdentifier: "port-forward-save", in: editorContent) as? NSButton
        )
        #expect(save.isEnabled)
        save.performClick(nil)

        #expect(mappings == [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
        ])
        settleUI()
        menu.refreshPermissionStatus()
        content.layoutSubtreeIfNeeded()
        let macLine = try #require(
            descendant(withIdentifier: "permission-detail-network-0", in: content) as? NSTextField
        )
        let guestLine = try #require(
            descendant(withIdentifier: "permission-detail-network-1", in: content) as? NSTextField
        )
        let activeStatus = try #require(
            descendant(withIdentifier: "permission-status-network", in: content) as? NSTextField
        )
        #expect(macLine.stringValue == "Mac: localhost:8080")
        #expect(guestLine.stringValue == "Omarchy: port 3000 · TCP")
        #expect(activeStatus.stringValue == "●  1 Port")

        let reopenedConfigure = try #require(
            descendant(withIdentifier: "permission-action-network", in: content) as? NSButton
        )
        reopenedConfigure.performClick(nil)
        let reopenedContent = try #require(menu.portForwardingEditor?.window.contentView)
        let remove = try #require(
            descendant(withIdentifier: "port-forward-remove-0", in: reopenedContent) as? NSButton
        )
        remove.performClick(nil)
        let saveRemoval = try #require(
            descendant(withIdentifier: "port-forward-save", in: reopenedContent) as? NSButton
        )
        #expect(saveRemoval.isEnabled)
        saveRemoval.performClick(nil)

        #expect(mappings.isEmpty)
        settleUI()
        menu.refreshPermissionStatus()
        let finalStatus = try #require(
            descendant(withIdentifier: "permission-status-network", in: content) as? NSTextField
        )
        #expect(finalStatus.stringValue == "○  Off")
    }

    @Test("a launch failure restores the menu and permits a second attempt")
    func launchFailureIsRecoverable() throws {
        _ = NSApplication.shared
        let mappings = [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
        ]
        var launchCount = 0
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
            portForwardingStatus: { mappings },
            savePortForwarding: { _ in nil },
            launch: { launchCount += 1 }
        )
        menu.show()
        defer { menu.dismiss() }

        let window = try #require(
            NSApp.windows.first(where: { $0.isVisible && $0.title == "Try Omarchy" })
        )
        let content = try #require(window.contentView)
        let firstLaunch = try #require(
            descendant(withIdentifier: "launch-button", in: content) as? NSButton
        )
        firstLaunch.performClick(nil)
        #expect(launchCount == 1)
        #expect(!(try #require(
            descendant(withIdentifier: "permission-action-network", in: content) as? NSButton
        )).isEnabled)
        #expect((try #require(
            descendant(withIdentifier: "launch-button-label", in: content) as? NSTextField
        )).stringValue == "Launching Omarchy…")

        menu.launchDidFail(errorMessage: "Mac TCP port 8080 isn’t available.")
        settleUI()
        if let errorSheet = window.attachedSheet {
            window.endSheet(errorSheet)
            errorSheet.orderOut(nil)
        }

        let configure = try #require(
            descendant(withIdentifier: "permission-action-network", in: content) as? NSButton
        )
        let restoredLaunch = try #require(
            descendant(withIdentifier: "launch-button", in: content) as? NSButton
        )
        #expect(configure.isEnabled)
        #expect(restoredLaunch.isEnabled)
        #expect((try #require(
            descendant(withIdentifier: "launch-button-label", in: content) as? NSTextField
        )).stringValue == "Launch Omarchy")
        #expect((try #require(
            descendant(withIdentifier: "permission-status-network", in: content) as? NSTextField
        )).stringValue == "●  1 Port")

        configure.performClick(nil)
        let editorContent = try #require(menu.portForwardingEditor?.window.contentView)
        #expect((try #require(
            descendant(withIdentifier: "port-forward-host-0", in: editorContent) as? NSTextField
        )).stringValue == "8080")
        menu.portForwardingEditor?.dismiss()

        let retry = try #require(
            descendant(withIdentifier: "launch-button", in: content) as? NSButton
        )
        retry.performClick(nil)
        #expect(launchCount == 2)
        menu.launchDidFail(errorMessage: "Retry failed for this test.")
        settleUI()
        if let retrySheet = window.attachedSheet {
            window.endSheet(retrySheet)
            retrySheet.orderOut(nil)
        }
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

    private func settleUI() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    }
}
