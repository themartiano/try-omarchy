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
    private let requestAccessibility: () -> Void
    private let requestMicrophone: (@escaping (Bool) -> Void) -> Void
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
    private var resetInProgress = false
    private var launchInProgress = false
    private var pendingResetSpaceEstimate: String?
    private weak var startMenuScrollView: NSScrollView?
    private(set) var portForwardingEditor: PortForwardingEditor?
    private weak var immersiveCaption: NSTextField?

    init(
        accessibilityStatus: @escaping () -> Bool,
        microphoneStatus: @escaping () -> MicrophoneAuthorizationState,
        requestAccessibility: @escaping () -> Void,
        requestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void,
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
        self.requestAccessibility = requestAccessibility
        self.requestMicrophone = requestMicrophone
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
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 690),
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
            let availableHeight = max(480, visibleFrame.height - 32)
            window.setContentSize(NSSize(width: 600, height: min(690, availableHeight)))
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

        let microphoneState = microphoneStatus()
        let microphoneGranted = microphoneState == .authorized
        let microphoneDetail: String
        let microphoneActionTitle: String?
        switch microphoneState {
        case .authorized:
            microphoneDetail = "Apps in Omarchy can record from your Mac microphone."
            microphoneActionTitle = nil
        case .notDetermined:
            microphoneDetail = "Optional. Speaker playback works without microphone access."
            microphoneActionTitle = microphoneRequestInFlight ? "Waiting…" : "Allow…"
        case .denied:
            microphoneDetail = "Recording is off. Speaker playback will still work."
            microphoneActionTitle = "Open Settings"
        case .restricted:
            microphoneDetail = "Recording is unavailable because of this Mac’s policy."
            microphoneActionTitle = nil
        }
        let microphoneRow = permissionRow(
            symbolName: "mic",
            title: "Microphone access",
            detail: microphoneDetail,
            granted: microphoneGranted,
            actionTitle: microphoneActionTitle,
            action: microphoneState == .denied
                ? #selector(openMicrophoneSettings)
                : #selector(beginMicrophoneRequest)
        )

        let sharedFolder = sharedFolderStatus()
        let sharedFolderDetail: String
        let sharedFolderDetailLines: [String]?
        var sharedFolderActions: [(String, Selector)] = [("Choose…", #selector(beginSharedFolderSelection))]
        if let problem = sharedFolder.problem {
            sharedFolderDetail = problem
            sharedFolderDetailLines = nil
        } else if let displayPath = sharedFolder.displayPath, sharedFolder.isEnabled {
            let guestPath = "~/\(SharedFolderPolicy.guestLinkName(sharedFolder.path ?? displayPath))"
            sharedFolderDetail = "Mac folder: \(displayPath). In Omarchy: \(guestPath)."
            sharedFolderDetailLines = [
                "Mac folder: \(displayPath)",
                "In Omarchy: \(guestPath)",
            ]
        } else if let displayPath = sharedFolder.displayPath {
            sharedFolderDetail = "Mac folder: \(displayPath). In Omarchy: Off."
            sharedFolderDetailLines = [
                "Mac folder: \(displayPath)",
                "In Omarchy: Off",
            ]
        } else {
            sharedFolderDetail = "Optional. Pick a Mac folder to use inside Omarchy under the same name."
            sharedFolderDetailLines = nil
        }
        if sharedFolder.path != nil {
            sharedFolderActions.append(
                sharedFolder.isEnabled
                    ? ("Turn Off", #selector(disableSharedFolder))
                    : ("Turn On", #selector(enableSharedFolder))
            )
        }
        let sharedFolderRow = permissionRow(
            symbolName: "folder",
            title: "Shared folder",
            detail: sharedFolderDetail,
            compactDetailLines: sharedFolderDetailLines,
            granted: sharedFolder.isEnabled && sharedFolder.problem == nil,
            statusLabels: ("●  On", "○  Off"),
            actions: sharedFolderActions,
            minimumHeight: 100
        )

        let portMappings = portForwardingStatus()
        let portForwardingDetail: String
        let portForwardingDetailLines: [String]?
        if portMappings.isEmpty {
            portForwardingDetail = "Optional. Reach services running in Omarchy at localhost on this Mac."
            portForwardingDetailLines = nil
        } else if portMappings.count == 1, let mapping = portMappings.first {
            portForwardingDetail = "localhost:\(mapping.hostPort) → Omarchy:\(mapping.guestPort) · \(mapping.protocol.displayName)"
            portForwardingDetailLines = [
                "Mac: localhost:\(mapping.hostPort)",
                "Omarchy: port \(mapping.guestPort) · \(mapping.protocol.displayName)",
            ]
        } else {
            portForwardingDetail = "\(portMappings.count) localhost mappings. Available only on this Mac."
            portForwardingDetailLines = [
                "\(portMappings.count) localhost mappings",
                "Available only on this Mac",
            ]
        }
        let portForwardingRow = permissionRow(
            symbolName: "network",
            title: "Port forwarding",
            detail: portForwardingDetail,
            compactDetailLines: portForwardingDetailLines,
            granted: !portMappings.isEmpty,
            statusLabels: (
                "●  \(portMappings.count) \(portMappings.count == 1 ? "Port" : "Ports")",
                "○  Off"
            ),
            actions: [("Configure…", #selector(beginPortForwardingConfiguration))],
            minimumHeight: 90
        )
        let immersiveRow = immersiveSettingRow(isEnabled: immersiveMode())

        let permissionRows = NSStackView(
            views: [
                accessibilityRow,
                separator(),
                microphoneRow,
                separator(),
                sharedFolderRow,
                separator(),
                portForwardingRow,
                separator(),
                immersiveRow,
            ]
        )
        permissionRows.orientation = .vertical
        permissionRows.alignment = .leading
        permissionRows.spacing = 0
        permissionRows.translatesAutoresizingMaskIntoConstraints = false
        for row in [accessibilityRow, microphoneRow, sharedFolderRow, portForwardingRow, immersiveRow] {
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
        reset.isEnabled = canResetStorage && !launchInProgress && !resetInProgress
        reset.toolTip = canResetStorage
            ? "Erase this VM and return it to factory settings"
            : "Reset is unavailable for a disposable VM"

        var resetViews: [NSView] = [reset]
        let storageStatus = storageLocationStatus()
        if let storagePath = storageLocation() {
            let dataLabel = NSTextField(labelWithString: "Data:")
            dataLabel.font = .systemFont(ofSize: 10)
            dataLabel.textColor = .secondaryLabelColor

            let storage: NSView
            if let locationURL = storageLocationURL() {
                let pathButton = PointingHandButton(
                    title: storagePath,
                    target: self,
                    action: #selector(openStorageLocation)
                )
                pathButton.isBordered = false
                pathButton.setAccessibilityLabel("Open data folder in Finder")
                pathButton.setAccessibilityValue(storagePath)
                pathButton.setAccessibilityHelp("Opens the Try Omarchy data folder in Finder")
                pathButton.attributedTitle = NSAttributedString(
                    string: storagePath,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                )
                pathButton.alignment = .left
                pathButton.toolTip = locationURL.path
                pathButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
                storage = pathButton
            } else {
                let pathLabel = NSTextField(labelWithString: storagePath)
                pathLabel.font = .systemFont(ofSize: 10)
                pathLabel.textColor = .secondaryLabelColor
                storage = pathLabel
            }

            var rowViews: [NSView] = [dataLabel, storage]
            rowViews.append(
                storageActionButton(
                    title: "Change\u{2026}",
                    action: #selector(beginStorageLocationSelection),
                    identifier: "storage-location-change"
                )
            )
            if !storageStatus.isDefault {
                rowViews.append(
                    storageActionButton(
                        title: "Use Default",
                        action: #selector(useDefaultStorageLocationAction),
                        identifier: "storage-location-default"
                    )
                )
            }

            let storageRow = NSStackView(views: rowViews)
            storageRow.orientation = .horizontal
            storageRow.alignment = .centerY
            storageRow.spacing = 6
            storageRow.identifier = NSUserInterfaceItemIdentifier("storage-location-row")
            storage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            resetViews.append(storageRow)

            if let note = storageStatus.problem ?? storageStatus.warning {
                let noteLabel = NSTextField(wrappingLabelWithString: note)
                noteLabel.font = .systemFont(ofSize: 10)
                noteLabel.textColor = storageStatus.problem == nil ? .secondaryLabelColor : .systemRed
                noteLabel.identifier = NSUserInterfaceItemIdentifier("storage-location-note")
                resetViews.append(noteLabel)
            }
        }
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
        launchButton.isEnabled = !launchInProgress && !resetInProgress && !microphoneRequestInFlight
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
        granted: Bool,
        statusLabels: (granted: String, denied: String),
        actions: [(String, Selector)],
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

        let explanations: [NSTextField]
        if let compactDetailLines {
            explanations = compactDetailLines.enumerated().map { index, line in
                let explanation = NSTextField(labelWithString: line)
                explanation.font = .systemFont(ofSize: 12)
                explanation.textColor = .secondaryLabelColor
                explanation.maximumNumberOfLines = 1
                explanation.lineBreakMode = .byTruncatingMiddle
                explanation.toolTip = line
                explanation.identifier = NSUserInterfaceItemIdentifier(
                    "permission-detail-\(symbolName)-\(index)"
                )
                return explanation
            }
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
            button.isEnabled = !microphoneRequestInFlight && !launchInProgress && !resetInProgress
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

        let detailText = Self.immersiveDetailText(isEnabled: isEnabled)
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

    @objc private func openStorageLocation() {
        guard let storageLocationURL = storageLocationURL() else { return }
        do {
            if !FileManager.default.fileExists(atPath: storageLocationURL.path) {
                // Never create intermediate directories. With a chosen data
                // folder the path can sit on a drive that is not mounted, and
                // creating it would leave a shadow folder at the mount point on
                // the boot volume that then hides the real drive.
                let parent = storageLocationURL.deletingLastPathComponent()
                guard FileManager.default.fileExists(atPath: parent.path) else {
                    throw NSError(
                        domain: "TryOmarchy.StorageLocation",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The drive that holds this folder is not connected.",
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

    private func storageActionButton(
        title: String,
        action: Selector,
        identifier: String
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isEnabled = canResetStorage && !launchInProgress && !resetInProgress
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        return button
    }

    @objc private func beginStorageLocationSelection() {
        guard canResetStorage, !launchInProgress, !resetInProgress else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where to keep the Omarchy VM"
        panel.message = "Omarchy keeps its virtual machine in a \u{201C}Try Omarchy\u{201D} folder inside the folder you choose. The drive must be APFS."
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
        guard !launchInProgress, !resetInProgress else { return }
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
        let detailText = Self.immersiveDetailText(isEnabled: isEnabled)
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

    private static func immersiveDetailText(isEnabled: Bool) -> String {
        isEnabled
            ? "Mac controls stay hidden. First press Control-Option-G, then Command-F to leave Full Screen."
            : "Move the pointer to the top of the screen, then choose View › Exit Full Screen or press Command-F."
    }

    private func confirmReset() {
        guard canResetStorage, !launchInProgress, !resetInProgress else { return }
        let estimate = storageSpaceEstimate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset Omarchy to factory settings?"
        var detail = "This permanently erases everything in this Omarchy virtual machine, including apps, files, accounts, and settings. This cannot be undone or recovered."
        // With a chosen data folder there can be more than one workspace on the
        // Mac, so say which one is about to be erased.
        let location = storageLocationStatus()
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
        guard !launchInProgress, !resetInProgress else { return }
        launchInProgress = true
        render()
        launch()
    }
}

private final class StartMenuDocumentView: NSView {
    override var isFlipped: Bool { true }
}
