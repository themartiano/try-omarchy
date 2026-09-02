import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu width", .serialized)
@MainActor
struct StartMenuWindowWidthTests {
    @Test("reset confirmation requires the exact application name")
    func resetConfirmationIsTypedAndExact() {
        let prompt = ResetConfirmationPrompt(detail: "This cannot be undone.")
        #expect(prompt.confirmationField.identifier?.rawValue == "reset-confirmation-field")
        #expect(!prompt.resetButton.isEnabled)

        for invalidValue in [
            "try omarchy",
            "TRY OMARCHY",
            "Try Omarchy ",
            " Try Omarchy",
        ] {
            prompt.confirmationField.stringValue = invalidValue
            NotificationCenter.default.post(
                name: NSControl.textDidChangeNotification,
                object: prompt.confirmationField
            )
            #expect(!prompt.resetButton.isEnabled)
        }

        prompt.confirmationField.stringValue = "Try Omarchy"
        NotificationCenter.default.post(
            name: NSControl.textDidChangeNotification,
            object: prompt.confirmationField
        )
        #expect(prompt.resetButton.isEnabled)
    }

    @Test("dynamic storage details cannot widen or escape the start menu")
    func storageDetailsStayWithinMenuWidth() throws {
        _ = NSApplication.shared
        let pathSuffix = String(repeating: "a-very-long-folder-name/", count: 12)
        let path = "/Users/test/Downloads/\(pathSuffix)"
        let displayPath = "~/Downloads/\(pathSuffix)"
        let warning = "Macintosh HD has 18.3 GB free. The VM disk grows as you use it "
            + "and can need up to 25.8 GB."
        var storageState = StorageLocationMenuState(
            containerPath: path,
            stateRoot: path,
            displayPath: displayPath,
            volumeName: "Macintosh HD",
            isDefault: false,
            isExternal: false,
            problem: nil,
            warning: warning,
            isEnvironmentOverride: false
        )
        let menu = makeMenu(storageState: { storageState })
        menu.prepareForPresentation(
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        defer { menu.dismiss() }

        try expectDetailsFit(
            ["permission-detail-externaldrive-0", "permission-detail-externaldrive-1"],
            in: menu
        )
        let content = try #require(menu.window.contentView)
        let pathButton = try #require(
            descendant(
                withIdentifier: "permission-detail-externaldrive-0",
                in: content
            ) as? NSButton
        )
        #expect(pathButton.cell?.lineBreakMode == .byTruncatingMiddle)

        storageState = StorageLocationMenuState(
            containerPath: path,
            stateRoot: nil,
            displayPath: displayPath,
            volumeName: nil,
            isDefault: false,
            isExternal: false,
            problem: "This folder cannot be used because its workspace metadata is damaged: "
                + path,
            warning: nil,
            isEnvironmentOverride: false
        )
        menu.prepareForPresentation(
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )
        try expectDetailsFit(["permission-detail-externaldrive"], in: menu)
    }

    private func makeMenu(
        storageState: @escaping () -> StorageLocationMenuState
    ) -> StartMenuWindow {
        StartMenuWindow(
            accessibilityStatus: { true },
            microphoneStatus: { .authorized },
            cameraStatus: { .authorized },
            requestAccessibility: {},
            requestMicrophone: { completion in completion(true) },
            requestCamera: { completion in completion(true) },
            canResetStorage: true,
            storageLocation: { storageState().displayPath },
            storageLocationURL: {
                storageState().containerPath.map { URL(fileURLWithPath: $0) }
            },
            storageSpaceEstimate: { nil },
            storageLocationStatus: storageState,
            validateStorageLocation: { _ in nil },
            chooseStorageLocation: { _ in nil },
            useDefaultStorageLocation: {},
            resetStorage: {},
            sharedFolderStatus: { .disabled },
            chooseSharedFolder: { _ in nil },
            setSharedFolderEnabled: { _ in },
            portForwardingStatus: { [] },
            immersiveMode: { true },
            setImmersiveMode: { _ in },
            launch: {}
        )
    }

    private func expectDetailsFit(
        _ identifiers: [String],
        in menu: StartMenuWindow
    ) throws {
        let content = try #require(menu.window.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(!menu.window.isVisible)
        #expect(menu.window.frame.width == 600)
        #expect(content.bounds.width == 600)

        let row = try #require(
            descendant(withIdentifier: "permission-row-externaldrive", in: content)
        )
        for identifier in identifiers {
            let detail = try #require(descendant(withIdentifier: identifier, in: row))
            let alignmentFrame = detail.alignmentRect(forFrame: detail.frame)
            let frame = try #require(detail.superview).convert(alignmentFrame, to: row)
            #expect(frame.minX >= row.bounds.minX)
            #expect(frame.maxX <= row.bounds.maxX - 124 - 12 + 0.5)
        }
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
