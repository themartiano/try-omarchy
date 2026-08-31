import AppKit

private final class MouseIgnoringTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PointingHandButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class PermissionActionButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

private final class LinkCursorTextField: NSTextField {
    override func resetCursorRects() {
        super.resetCursorRects()
        let textRect = cell?.drawingRect(forBounds: bounds) ?? bounds
        let fullRange = NSRange(location: 0, length: attributedStringValue.length)
        attributedStringValue.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            let prefixRange = NSRange(location: 0, length: range.location)
            let prefixWidth = attributedStringValue
                .attributedSubstring(from: prefixRange)
                .size().width
            let linkWidth = attributedStringValue
                .attributedSubstring(from: range)
                .size().width
            addCursorRect(
                NSRect(
                    x: textRect.minX + prefixWidth,
                    y: textRect.minY,
                    width: linkWidth,
                    height: textRect.height
                ),
                cursor: .pointingHand
            )
        }
    }
}

@MainActor
final class StartMenuWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let content = NSView()
    private let accessibilityStatus: () -> Bool
    private let microphoneStatus: () -> MicrophoneAuthorizationState
    private let cameraStatus: () -> CameraAuthorizationState
    private let requestAccessibility: () -> Void
    private let requestMicrophone: (@escaping (Bool) -> Void) -> Void
    private let requestCamera: (@escaping (Bool) -> Void) -> Void
    private let storageSpaceEstimate: () -> String?
    private let resetStorage: () -> Void
    private let sharedFolderStatus: () -> SharedFolderMenuState
    private let chooseSharedFolder: (String) -> String?
    private let setSharedFolderEnabled: (Bool) -> Void
    private let portForwardingStatus: () -> [PortForwardMapping]
    private let savePortForwarding: ([PortForwardMapping]) -> String?
    private let immersiveMode: () -> Bool
    private let setImmersiveMode: (Bool) -> Void
    private let launch: () -> Void
    private let canResetStorage: Bool
    private let storageLocation: () -> String?
    private let storageLocationURL: () -> URL?
    private let storageLocationStatus: () -> StorageLocationMenuState
    private let validateStorageLocation: (String) -> String?
    private let chooseStorageLocation: (String) -> String?
    private let useDefaultStorageLocation: () -> Void

    private var microphoneRequestInFlight = false
    private var cameraRequestInFlight = false
    private var resetInProgress = false
    private var launchInProgress = false
    private var pendingResetSpaceEstimate: String?
    private weak var startMenuScrollView: NSScrollView?
    private(set) var portForwardingEditor: PortForwardingEditor?
    private weak var immersiveCaption: NSTextField?

    init(
        accessibilityStatus: @escaping () -> Bool,
        microphoneStatus: @escaping () -> MicrophoneAuthorizationState,
        cameraStatus: @escaping () -> CameraAuthorizationState = { .authorized },
        requestAccessibility: @escaping () -> Void,
        requestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void,
        requestCamera: @escaping (@escaping (Bool) -> Void) -> Void = { completion in
            completion(true)
        },
        canResetStorage: Bool,
        storageLocation: @escaping () -> String?,
        storageLocationURL: @escaping () -> URL?,
        storageSpaceEstimate: @escaping () -> String?,
        storageLocationStatus: @escaping () -> StorageLocationMenuState,
        validateStorageLocation: @escaping (String) -> String?,
        chooseStorageLocation: @escaping (String) -> String?,
        useDefaultStorageLocation: @escaping () -> Void,
        resetStorage: @escaping () -> Void,
        sharedFolderStatus: @escaping () -> SharedFolderMenuState,
        chooseSharedFolder: @escaping (String) -> String?,
        setSharedFolderEnabled: @escaping (Bool) -> Void,
        portForwardingStatus: @escaping () -> [PortForwardMapping] = { [] },
        savePortForwarding: @escaping ([PortForwardMapping]) -> String? = { _ in nil },
        immersiveMode: @escaping () -> Bool = { true },
        setImmersiveMode: @escaping (Bool) -> Void = { _ in },
        launch: @escaping () -> Void
    ) {
        self.accessibilityStatus = accessibilityStatus
        self.microphoneStatus = microphoneStatus
        self.cameraStatus = cameraStatus
        self.requestAccessibility = requestAccessibility
        self.requestMicrophone = requestMicrophone
        self.requestCamera = requestCamera
        self.canResetStorage = canResetStorage
        self.storageLocation = storageLocation
        self.storageLocationURL = storageLocationURL
        self.storageSpaceEstimate = storageSpaceEstimate
        self.storageLocationStatus = storageLocationStatus
        self.validateStorageLocation = validateStorageLocation
        self.chooseStorageLocation = chooseStorageLocation
        self.useDefaultStorageLocation = useDefaultStorageLocation
        self.resetStorage = resetStorage
        self.sharedFolderStatus = sharedFolderStatus
        self.chooseSharedFolder = chooseSharedFolder
        self.setSharedFolderEnabled = setSharedFolderEnabled
        self.portForwardingStatus = portForwardingStatus
        self.savePortForwarding = savePortForwarding
        self.immersiveMode = immersiveMode
        self.setImmersiveMode = setImmersiveMode
        self.launch = launch

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Try Omarchy"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = content
    }

    func show() {
        render()
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            // The menu carries six rows once a resettable VM can choose where it
            // lives. At 690 the launch button cleared the bottom edge by 15pt,
            // which any difference in system font metrics turned into a button
            // clipped off the window.
            let availableHeight = max(480, visibleFrame.height - 32)
            window.setContentSize(NSSize(width: 600, height: min(760, availableHeight)))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshPermissionStatus() {
        guard window.isVisible, !launchInProgress, !resetInProgress else { return }
        render()
    }

    func promptForReset() {
        guard canResetStorage else { return }
        window.makeKeyAndOrderFront(nil)
        confirmReset()
    }

    func dismiss() {
        portForwardingEditor?.dismiss()
        portForwardingEditor = nil
        window.orderOut(nil)
    }

    func resetDidFinish(errorMessage: String?) {
        guard resetInProgress else { return }
        resetInProgress = false
        render()

        let alert = NSAlert()
        if let errorMessage {
            alert.alertStyle = .critical
            alert.messageText = "Omarchy couldn’t be reset"
            alert.informativeText = errorMessage
        } else {
            alert.alertStyle = .informational
            alert.messageText = "Omarchy has been reset"
            if let estimate = pendingResetSpaceEstimate {
                alert.informativeText = "The VM is back to factory settings. Up to \(estimate) of disk space was reclaimed. You can launch whenever you’re ready."
            } else {
                alert.informativeText = "The VM is back to factory settings. You can launch whenever you’re ready."
            }
        }
        pendingResetSpaceEstimate = nil
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Clears the launching state when the controller stopped before the
    /// launcher was ever started. The controller presents its own explanation.
    func launchDidAbort() {
        guard launchInProgress else { return }
        launchInProgress = false
        render()
    }

    /// Clears the resetting state when the controller refused to start the
    /// reset at all. Deliberately silent, and deliberately not
    /// `resetDidFinish(errorMessage: nil)` — nothing was erased, so claiming
    /// "Omarchy has been reset" would be a lie about a destructive action.
    func resetDidAbort() {
        guard resetInProgress else { return }
        resetInProgress = false
        render()
    }

    func launchRequiresReset() {
        guard launchInProgress else { return }
        launchInProgress = false
        render()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Omarchy to continue"
        alert.informativeText = "This VM was created by a different Try Omarchy build. Reset Omarchy to use this version. Resetting permanently erases everything in the VM."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    func launchDidFail(errorMessage: String) {
        guard launchInProgress else { return }
        launchInProgress = false
        render()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Try Omarchy couldn’t start"
        alert.informativeText = errorMessage
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    private func render() {
        let preservedScrollOffset = startMenuScrollView?.contentView.bounds.minY ?? 0
        startMenuScrollView = nil
        content.subviews.forEach { $0.removeFromSuperview() }

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 62),
            icon.heightAnchor.constraint(equalToConstant: 62),
        ])

        let title = NSTextField(labelWithString: "Try Omarchy")
        title.font = .systemFont(ofSize: 27, weight: .bold)

        let headingStack = NSStackView(views: [icon, title])
        headingStack.orientation = .horizontal
        headingStack.alignment = .centerY
        headingStack.spacing = 14

        let accessibilityGranted = accessibilityStatus()
        let accessibilityRow = permissionRow(
            symbolName: "accessibility",
            title: "Accessibility",
            detail: "Needed for the native keyboard experience with Super shortcuts.",
            granted: accessibilityGranted,
            actionTitle: accessibilityGranted ? nil : "Open Settings",
            action: #selector(beginAccessibilityRequest)
        )

        let microphonePresentation = StartMenuPresentation.microphone(
            state: microphoneStatus(),
            requestInFlight: microphoneRequestInFlight
        )
        let microphoneRow = permissionRow(
            symbolName: "mic",
            title: "Microphone access",
            detail: microphonePresentation.detail,
            granted: microphonePresentation.isGranted,
            actionTitle: microphonePresentation.actionTitle,
            action: microphonePresentation.action == .openSettings
                ? #selector(openMicrophoneSettings)
                : #selector(beginMicrophoneRequest)
        )

        let cameraPresentation = StartMenuPresentation.camera(
            state: cameraStatus(),
            requestInFlight: cameraRequestInFlight
        )
        let cameraRow = permissionRow(
            symbolName: "camera",
            title: "Camera access",
            detail: cameraPresentation.detail,
            granted: cameraPresentation.isGranted,
            actionTitle: cameraPresentation.actionTitle,
            action: cameraPresentation.action == .openSettings
                ? #selector(openCameraSettings)
                : #selector(beginCameraRequest)
        )

        let sharedFolder = sharedFolderStatus()
        let sharedFolderPresentation = StartMenuPresentation.sharedFolder(state: sharedFolder)
        var sharedFolderActions: [(String, Selector)] = [("Choose…", #selector(beginSharedFolderSelection))]
        if let toggleTitle = sharedFolderPresentation.toggleActionTitle {
            sharedFolderActions.append(
                sharedFolder.isEnabled
                    ? (toggleTitle, #selector(disableSharedFolder))
                    : (toggleTitle, #selector(enableSharedFolder))
            )
        }
        let sharedFolderRow = permissionRow(
            symbolName: "folder",
            title: "Shared folder",
            detail: sharedFolderPresentation.detail,
            compactDetailLines: sharedFolderPresentation.compactDetailLines,
            granted: sharedFolderPresentation.isGranted,
            statusLabels: ("●  On", "○  Off"),
            actions: sharedFolderActions,
            minimumHeight: 100
        )

        let portMappings = portForwardingStatus()
        let portForwardingPresentation = StartMenuPresentation.portForwarding(
            mappings: portMappings
        )
        let portForwardingRow = permissionRow(
            symbolName: "network",
            title: "Port forwarding",
            detail: portForwardingPresentation.detail,
            compactDetailLines: portForwardingPresentation.compactDetailLines,
            granted: portForwardingPresentation.isGranted,
            statusLabels: (
                portForwardingPresentation.grantedStatusLabel,
                "○  Off"
            ),
            actions: [("Configure…", #selector(beginPortForwardingConfiguration))],
            minimumHeight: 90
        )
        let immersiveRow = immersiveSettingRow(isEnabled: immersiveMode())

        let storageStatus = storageLocationStatus()
        var storageRow: NSView?
        if let storagePath = storageLocation() {
            let storageDetail: String
            let storageDetailLines: [String]?
            if let problem = storageStatus.problem {
                storageDetail = problem
                storageDetailLines = nil
            } else if !storageStatus.isDefault {
                let volumeInfo = [storageStatus.volumeName, storageStatus.isExternal ? "External drive" : nil]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                // Say so when the environment picked this workspace, otherwise
                // the row reads as the user's own choice while the buttons that
                // would change it quietly do nothing.
                let secondLine = storageStatus.isEnvironmentOverride
                    ? "Set by \(StorageLocationPolicy.environmentKey)"
                    : storageStatus.warning ?? (volumeInfo.isEmpty ? nil : volumeInfo)
                if let secondLine {
                    storageDetail = "\(storagePath) · \(secondLine)"
                    storageDetailLines = [storagePath, secondLine]
                } else {
                    storageDetail = storagePath
                    storageDetailLines = nil
                }
            } else {
                storageDetail = storagePath
                storageDetailLines = nil
            }

            var storageActions: [(String, Selector)] = [("Change\u{2026}", #selector(beginStorageLocationSelection))]
            if !storageStatus.isDefault {
                storageActions.append(("Use Default", #selector(useDefaultStorageLocationAction)))
            }

            storageRow = permissionRow(
                symbolName: "externaldrive",
                title: "VM Location",
                detail: storageDetail,
                compactDetailLines: storageDetailLines,
                detailAction: storageStatus.problem == nil && storageLocationURL() != nil
                    ? #selector(openStorageLocation)
                    : nil,
                granted: !storageStatus.isDefault && storageStatus.problem == nil,
                statusLabels: ("\u{25cf}  Custom", "\u{25cb}  Default"),
                actions: storageActions,
                actionsEnabled: canResetStorage && !storageStatus.isEnvironmentOverride,
                minimumHeight: storageDetailLines != nil || storageActions.count > 1 ? 90 : 68
            )
        }

        var permissionRowViews = [accessibilityRow, microphoneRow, cameraRow, sharedFolderRow]
        if let storageRow {
            permissionRowViews.append(storageRow)
        }
        permissionRowViews.append(contentsOf: [portForwardingRow, immersiveRow])

        var permissionRowsAndSeparators: [NSView] = []
        for (index, row) in permissionRowViews.enumerated() {
            if index > 0 {
                permissionRowsAndSeparators.append(separator())
            }
            permissionRowsAndSeparators.append(row)
        }

        let permissionRows = NSStackView(views: permissionRowsAndSeparators)
        permissionRows.orientation = .vertical
        permissionRows.alignment = .leading
        permissionRows.spacing = 0
        permissionRows.translatesAutoresizingMaskIntoConstraints = false
        for row in permissionRowViews {
            row.widthAnchor.constraint(equalTo: permissionRows.widthAnchor).isActive = true
        }

        let permissionCard = NSView()
        permissionCard.wantsLayer = true
        permissionCard.layer?.cornerRadius = 12
        permissionCard.layer?.borderWidth = 1
        permissionCard.layer?.borderColor = NSColor.separatorColor.cgColor
        permissionCard.addSubview(permissionRows)
        NSLayoutConstraint.activate([
            permissionRows.leadingAnchor.constraint(equalTo: permissionCard.leadingAnchor, constant: 20),
            permissionRows.trailingAnchor.constraint(equalTo: permissionCard.trailingAnchor, constant: -20),
            permissionRows.topAnchor.constraint(equalTo: permissionCard.topAnchor, constant: 5),
            permissionRows.bottomAnchor.constraint(equalTo: permissionCard.bottomAnchor, constant: -5),
        ])

        let reset = NSButton(
            title: resetInProgress ? "Resetting Omarchy…" : "Reset Omarchy",
            target: self,
            action: #selector(resetOmarchy)
        )
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.contentTintColor = .systemRed
        reset.isEnabled = canResetStorage
            && !launchInProgress
            && !resetInProgress
            && !microphoneRequestInFlight
            && !cameraRequestInFlight
        reset.toolTip = canResetStorage
            ? "Erase this VM and return it to factory settings"
            : "Reset is unavailable for a disposable VM"

        let resetViews: [NSView] = [reset]
        let resetSection = NSStackView(views: resetViews)
        resetSection.orientation = .vertical
        resetSection.alignment = .leading
        resetSection.spacing = 4

        let launchButtonTitle = launchInProgress ? "Launching Omarchy…" : "Launch Omarchy"
        let launchButtonFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let launchButton = NSButton(
            title: launchButtonTitle,
            target: self,
            action: #selector(launchOmarchy)
        )
        launchButton.keyEquivalent = launchInProgress ? "" : "\r"
        launchButton.bezelStyle = .rounded
        launchButton.controlSize = .large
        launchButton.font = launchButtonFont
        launchButton.isEnabled = !launchInProgress
            && !resetInProgress
            && !microphoneRequestInFlight
            && !cameraRequestInFlight
        launchButton.title = ""
        launchButton.identifier = NSUserInterfaceItemIdentifier("launch-button")
        let launchButtonLabel = MouseIgnoringTextField(labelWithString: launchButtonTitle)
        launchButtonLabel.font = launchButtonFont
        launchButtonLabel.textColor = launchButton.isEnabled
            ? .alternateSelectedControlTextColor
            : .controlTextColor
        launchButtonLabel.alignment = .center
        launchButtonLabel.setAccessibilityElement(false)
        launchButtonLabel.identifier = NSUserInterfaceItemIdentifier("launch-button-label")
        launchButtonLabel.translatesAutoresizingMaskIntoConstraints = false
        launchButton.addSubview(launchButtonLabel)
        NSLayoutConstraint.activate([
            launchButtonLabel.centerXAnchor.constraint(equalTo: launchButton.centerXAnchor),
            launchButtonLabel.centerYAnchor.constraint(equalTo: launchButton.centerYAnchor),
        ])
        launchButton.translatesAutoresizingMaskIntoConstraints = false
        launchButton.setAccessibilityLabel(launchInProgress ? "Launching Omarchy" : "Launch Omarchy")
        if launchInProgress {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimation(nil)
            launchButton.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerYAnchor.constraint(equalTo: launchButton.centerYAnchor),
                spinner.trailingAnchor.constraint(equalTo: launchButton.trailingAnchor, constant: -16),
            ])
        }
        NSLayoutConstraint.activate([
            launchButton.heightAnchor.constraint(equalToConstant: 48),
            launchButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
        ])

        let footerText = "by @martiano  •  Not affiliated with Omarchy."
        let footerTitle = NSMutableAttributedString(
            string: footerText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let footerNSString = footerText as NSString
        footerTitle.addAttributes(
            [
                .link: URL(string: "https://x.com/martiano")!,
                .foregroundColor: NSColor.linkColor,
            ],
            range: footerNSString.range(of: "@martiano")
        )
        footerTitle.addAttributes(
            [
                .link: URL(string: "https://omarchy.org")!,
                .foregroundColor: NSColor.linkColor,
            ],
            range: footerNSString.range(of: "Omarchy")
        )

        let footer = LinkCursorTextField(labelWithAttributedString: footerTitle)
        footer.isSelectable = true
        footer.allowsEditingTextAttributes = true
        footer.translatesAutoresizingMaskIntoConstraints = false

        let footerContainer = NSView()
        footerContainer.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.centerXAnchor.constraint(equalTo: footerContainer.centerXAnchor),
            footer.topAnchor.constraint(equalTo: footerContainer.topAnchor),
            footer.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor),
        ])

        let stack = NSStackView(
            views: [headingStack, permissionCard, resetSection, launchButton, footerContainer]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(14, after: headingStack)
        stack.setCustomSpacing(12, after: permissionCard)
        stack.setCustomSpacing(12, after: resetSection)
        stack.setCustomSpacing(8, after: launchButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = StartMenuDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .none
        scrollView.identifier = NSUserInterfaceItemIdentifier("start-menu-scroll")
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        startMenuScrollView = scrollView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 42),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -42),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            permissionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resetSection.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            launchButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        content.layoutSubtreeIfNeeded()
        document.layoutSubtreeIfNeeded()
        let maximumOffset = max(
            0,
            document.frame.height - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(
            to: NSPoint(
                x: 0,
                y: min(max(0, preservedScrollOffset), maximumOffset)
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func permissionRow(
        symbolName: String,
        title: String,
        detail: String,
        granted: Bool,
        actionTitle: String?,
        action: Selector
    ) -> NSView {
        permissionRow(
            symbolName: symbolName,
            title: title,
            detail: detail,
            granted: granted,
            statusLabels: ("●  Yes", "○  No"),
            actions: actionTitle.map { [($0, action)] } ?? []
        )
    }

    private func permissionRow(
        symbolName: String,
        title: String,
        detail: String,
        compactDetailLines: [String]? = nil,
        detailAction: Selector? = nil,
        granted: Bool,
        statusLabels: (granted: String, denied: String),
        actions: [(String, Selector)],
        actionsEnabled: Bool = true,
        minimumHeight: CGFloat = 68
    ) -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        symbol.contentTintColor = .controlAccentColor
        symbol.identifier = NSUserInterfaceItemIdentifier("permission-symbol-\(symbolName)")
        symbol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 26),
            symbol.heightAnchor.constraint(equalToConstant: 26),
        ])

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.identifier = NSUserInterfaceItemIdentifier("permission-title-\(symbolName)")

        var explanations: [NSView] = []
        if let compactDetailLines {
            for (index, line) in compactDetailLines.enumerated() {
                let identifier = "permission-detail-\(symbolName)-\(index)"
                if index == 0, let detailAction {
                    explanations.append(
                        clickableDetailField(line, action: detailAction, identifier: identifier)
                    )
                } else {
                    let explanation = NSTextField(labelWithString: line)
                    explanation.font = .systemFont(ofSize: 12)
                    explanation.textColor = .secondaryLabelColor
                    explanation.maximumNumberOfLines = 1
                    explanation.lineBreakMode = .byTruncatingMiddle
                    explanation.toolTip = line
                    explanation.identifier = NSUserInterfaceItemIdentifier(identifier)
                    explanations.append(explanation)
                }
            }
        } else if let detailAction {
            explanations = [
                clickableDetailField(
                    detail,
                    action: detailAction,
                    identifier: "permission-detail-\(symbolName)"
                ),
            ]
        } else {
            let explanation = NSTextField(wrappingLabelWithString: detail)
            explanation.font = .systemFont(ofSize: 12)
            explanation.textColor = .secondaryLabelColor
            explanation.maximumNumberOfLines = 2
            explanations = [explanation]
        }

        let labels = NSStackView(views: [name] + explanations)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        let statusText = granted ? statusLabels.granted : statusLabels.denied
        let statusFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let status = NSTextField(labelWithString: statusText)
        status.font = statusFont
        if granted {
            let attributedStatus = NSMutableAttributedString(
                string: statusText,
                attributes: [
                    .font: statusFont,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            attributedStatus.addAttribute(
                .foregroundColor,
                value: NSColor.systemGreen,
                range: NSRange(location: 0, length: 1)
            )
            status.attributedStringValue = attributedStatus
        } else {
            status.textColor = .secondaryLabelColor
        }
        status.alignment = .right
        status.identifier = NSUserInterfaceItemIdentifier("permission-status-\(symbolName)")
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.translatesAutoresizingMaskIntoConstraints = false

        var trailingViews: [NSView] = [status]
        for (index, actionDescription) in actions.enumerated() {
            let (actionTitle, action) = actionDescription
            let button = PermissionActionButton(title: actionTitle, target: self, action: action)
            button.controlSize = .regular
            button.isEnabled = actionsEnabled
                && !microphoneRequestInFlight
                && !cameraRequestInFlight
                && !launchInProgress
                && !resetInProgress
            let identifier = actions.count == 1
                ? "permission-action-\(symbolName)"
                : "permission-action-\(symbolName)-\(index)"
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
            trailingViews.append(button)
        }

        let trailing = NSView()
        trailing.translatesAutoresizingMaskIntoConstraints = false
        for trailingView in trailingViews {
            trailing.addSubview(trailingView)
        }
        var trailingConstraints = [
            status.topAnchor.constraint(equalTo: trailing.topAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: trailing.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
        ]
        var previousTrailingView: NSView = status
        for (index, actionView) in trailingViews.dropFirst().enumerated() {
            trailingConstraints.append(contentsOf: [
                actionView.leadingAnchor.constraint(equalTo: trailing.leadingAnchor),
                actionView.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
                actionView.topAnchor.constraint(
                    equalTo: previousTrailingView.bottomAnchor,
                    constant: index == 0 ? 7 : 2
                ),
            ])
            previousTrailingView = actionView
        }
        trailingConstraints.append(
            previousTrailingView.bottomAnchor.constraint(equalTo: trailing.bottomAnchor)
        )
        NSLayoutConstraint.activate(trailingConstraints)

        labels.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.identifier = NSUserInterfaceItemIdentifier("permission-row-\(symbolName)")
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(symbol)
        row.addSubview(labels)
        row.addSubview(trailing)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight),
            symbol.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            symbol.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.widthAnchor.constraint(equalToConstant: 124),
        ])
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func clickableDetailField(
        _ text: String,
        action: Selector,
        identifier: String
    ) -> NSView {
        let button = PointingHandButton(title: text, target: self, action: action)
        button.isBordered = false
        button.alignment = .left
        button.setAccessibilityLabel("Open in Finder")
        button.setAccessibilityValue(text)
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        button.toolTip = text
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
        return button
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    private func immersiveSettingRow(isEnabled: Bool) -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: nil
        )
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        symbol.contentTintColor = .controlAccentColor
        symbol.identifier = NSUserInterfaceItemIdentifier("immersive-symbol")
        symbol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 26),
            symbol.heightAnchor.constraint(equalToConstant: 26),
        ])

        let title = NSTextField(labelWithString: "Immersive")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.identifier = NSUserInterfaceItemIdentifier("immersive-title")

        let detailText = StartMenuPresentation.immersiveDetail(isEnabled: isEnabled)
        let detail = NSTextField(wrappingLabelWithString: detailText)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.identifier = NSUserInterfaceItemIdentifier("immersive-caption")
        immersiveCaption = detail

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        let toggle = NSSwitch()
        toggle.state = isEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(changeImmersiveMode(_:))
        toggle.isEnabled = !microphoneRequestInFlight && !launchInProgress && !resetInProgress
        toggle.identifier = NSUserInterfaceItemIdentifier("immersive-toggle")
        toggle.setAccessibilityLabel("Immersive mode")
        toggle.setAccessibilityTitleUIElement(title)
        toggle.setAccessibilityHelp(detailText)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.identifier = NSUserInterfaceItemIdentifier("immersive-row")
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(symbol)
        row.addSubview(labels)
        row.addSubview(toggle)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            symbol.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            symbol.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    @objc private func beginAccessibilityRequest() {
        requestAccessibility()
        render()
    }

    @objc private func beginMicrophoneRequest() {
        guard microphoneStatus() == .notDetermined, !microphoneRequestInFlight else { return }
        microphoneRequestInFlight = true
        render()
        requestMicrophone { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.microphoneRequestInFlight = false
                self.render()
                self.window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func beginCameraRequest() {
        guard cameraStatus() == .notDetermined, !cameraRequestInFlight else { return }
        cameraRequestInFlight = true
        render()
        requestCamera { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cameraRequestInFlight = false
                self.render()
                self.window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func openCameraSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openStorageLocation() {
        guard let storageLocationURL = storageLocationURL() else { return }
        do {
            if !FileManager.default.fileExists(atPath: storageLocationURL.path) {
                // Only the default folder is ever created from here. A chosen
                // folder that has gone missing means its drive is not mounted,
                // and "the parent exists" is not proof otherwise: a leftover
                // /Volumes/<name> directory on the boot volume satisfies that
                // test, so creating the folder would silently rebuild the
                // workspace on the internal disk and the next launch would
                // initialize a brand-new VM there.
                guard storageLocationStatus().isDefault else {
                    throw NSError(
                        domain: "TryOmarchy.StorageLocation",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The drive that holds this folder is not connected. Reconnect it, or switch back to the default folder.",
                        ]
                    )
                }
                try FileManager.default.createDirectory(
                    at: storageLocationURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            guard NSWorkspace.shared.open(storageLocationURL) else {
                throw NSError(
                    domain: "TryOmarchy.StorageLocation",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Finder could not open the data directory."]
                )
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t open the data directory"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
    }

    @objc private func resetOmarchy() {
        confirmReset()
    }

    @objc private func beginStorageLocationSelection() {
        guard canResetStorage, !launchInProgress, !resetInProgress else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where to keep the Omarchy VM"
        panel.message = "Omarchy puts its VM files straight into the folder you choose \u{2014} it does not create a folder inside it. Pick an empty folder, or one Omarchy already uses. The drive must be APFS."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let current = storageLocationStatus().containerPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Reject before confirming: nobody should agree to a move that is about
        // to be refused because the drive is the wrong format or too full.
        if let problem = validateStorageLocation(url.path) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That folder can\u{2019}t hold the Omarchy VM"
            alert.informativeText = problem
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
            return
        }

        let destination = StorageLocationPolicy.stateRoot(forContainer: url.path)
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Keep the Omarchy VM here?"
        confirmation.informativeText = """
            Omarchy will use \(destination) from the next launch.

            Your current VM is not moved. It stays where it is, and you can \
            reach it again by switching this setting back.
            """
        confirmation.addButton(withTitle: "Cancel")
        confirmation.addButton(withTitle: "Use This Folder")
        guard confirmation.runModal() == .alertSecondButtonReturn else { return }

        if let problem = chooseStorageLocation(url.path) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That folder can\u{2019}t hold the Omarchy VM"
            alert.informativeText = problem
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
        render()
    }

    @objc private func useDefaultStorageLocationAction() {
        guard canResetStorage, !launchInProgress, !resetInProgress else { return }
        useDefaultStorageLocation()
        render()
    }

    @objc private func beginSharedFolderSelection() {
        guard !launchInProgress,
              !resetInProgress,
              !microphoneRequestInFlight,
              !cameraRequestInFlight else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to share with Omarchy"
        panel.message = "Omarchy will be able to read and change everything inside this folder, linked as ~/<folder name>."
        panel.prompt = "Share"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let current = sharedFolderStatus().path {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = chooseSharedFolder(url.path) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That folder can’t be shared"
            alert.informativeText = problem
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
        render()
    }

    @objc private func enableSharedFolder() {
        setSharedFolderEnabled(true)
        render()
    }

    @objc private func disableSharedFolder() {
        setSharedFolderEnabled(false)
        render()
    }

    @objc private func beginPortForwardingConfiguration() {
        guard !launchInProgress, !resetInProgress, portForwardingEditor == nil else { return }
        let editor = PortForwardingEditor(
            mappings: portForwardingStatus(),
            save: { [weak self] mappings in
                guard let self else {
                    return "Port forwarding could not be saved because the start menu is unavailable."
                }
                return self.savePortForwarding(mappings)
            },
            didClose: { [weak self] in
                guard let self else { return }
                self.portForwardingEditor = nil
                self.render()
            }
        )
        portForwardingEditor = editor
        editor.beginSheet(for: window)
    }

    @objc private func changeImmersiveMode(_ sender: NSSwitch) {
        guard !launchInProgress, !resetInProgress else { return }
        let isEnabled = sender.state == .on
        setImmersiveMode(isEnabled)
        let detailText = StartMenuPresentation.immersiveDetail(isEnabled: isEnabled)
        immersiveCaption?.stringValue = detailText
        sender.setAccessibilityHelp(detailText)
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: detailText,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func confirmReset() {
        guard canResetStorage,
              !launchInProgress,
              !resetInProgress,
              !microphoneRequestInFlight,
              !cameraRequestInFlight else { return }
        let estimate = storageSpaceEstimate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset Omarchy to factory settings?"
        var detail = "This permanently erases everything in this Omarchy virtual machine, including apps, files, accounts, and settings. This cannot be undone or recovered."
        // With a chosen data folder there can be more than one workspace on the
        // Mac, so say which one is about to be erased.
        let location = storageLocationStatus()
        if !location.isDefault, location.problem != nil {
            // The chosen folder cannot be reached, so which VM a reset would
            // erase is exactly what is in doubt. Hand straight to the
            // controller, which owns the preference and can explain and offer
            // to switch, rather than asking the user to confirm erasing a
            // workspace we would only be guessing the identity of.
            resetInProgress = true
            render()
            resetStorage()
            return
        }
        if !location.isDefault, let displayPath = location.displayPath {
            let volume = location.volumeName.map { "\($0), " } ?? ""
            detail += " The VM being erased is the one stored at \(volume)\(displayPath)."
        }
        if let estimate {
            detail += " Resetting may free up to \(estimate) of disk space."
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        let resetButton = alert.addButton(withTitle: "Reset")
        resetButton.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        pendingResetSpaceEstimate = estimate
        resetInProgress = true
        render()
        resetStorage()
    }

    @objc private func launchOmarchy() {
        guard !launchInProgress,
              !resetInProgress,
              !microphoneRequestInFlight,
              !cameraRequestInFlight else { return }
        launchInProgress = true
        render()
        launch()
    }
}

private final class StartMenuDocumentView: NSView {
    override var isFlipped: Bool { true }
}
