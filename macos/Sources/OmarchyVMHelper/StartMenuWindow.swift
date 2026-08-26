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
    private let launch: () -> Void
    private let canResetStorage: Bool
    private let storageLocation: String?
    private let storageLocationURL: URL?

    private var microphoneRequestInFlight = false
    private var resetInProgress = false
    private var launchInProgress = false
    private var pendingResetSpaceEstimate: String?

    init(
        accessibilityStatus: @escaping () -> Bool,
        microphoneStatus: @escaping () -> MicrophoneAuthorizationState,
        requestAccessibility: @escaping () -> Void,
        requestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void,
        canResetStorage: Bool,
        storageLocation: String?,
        storageLocationURL: URL?,
        storageSpaceEstimate: @escaping () -> String?,
        resetStorage: @escaping () -> Void,
        sharedFolderStatus: @escaping () -> SharedFolderMenuState,
        chooseSharedFolder: @escaping (String) -> String?,
        setSharedFolderEnabled: @escaping (Bool) -> Void,
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
        self.resetStorage = resetStorage
        self.sharedFolderStatus = sharedFolderStatus
        self.chooseSharedFolder = chooseSharedFolder
        self.setSharedFolderEnabled = setSharedFolderEnabled
        self.launch = launch

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 590),
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    private func render() {
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
        headingStack.orientation = .vertical
        headingStack.alignment = .leading
        headingStack.spacing = 10

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
        var sharedFolderActions: [(String, Selector)] = [("Choose…", #selector(beginSharedFolderSelection))]
        if let problem = sharedFolder.problem {
            sharedFolderDetail = problem
        } else if let displayPath = sharedFolder.displayPath, sharedFolder.isEnabled {
            sharedFolderDetail = "Omarchy can read and write “\(displayPath)” as ~/\(SharedFolderPolicy.guestLinkName(sharedFolder.path ?? displayPath))."
        } else if let displayPath = sharedFolder.displayPath {
            sharedFolderDetail = "Off. “\(displayPath)” stays private to this Mac until turned on."
        } else {
            sharedFolderDetail = "Optional. Pick a Mac folder to use inside Omarchy under the same name."
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
            granted: sharedFolder.isEnabled && sharedFolder.problem == nil,
            statusLabels: ("●  On", "○  Off"),
            actions: sharedFolderActions
        )

        let permissionRows = NSStackView(
            views: [accessibilityRow, separator(), microphoneRow, separator(), sharedFolderRow]
        )
        permissionRows.orientation = .vertical
        permissionRows.alignment = .width
        permissionRows.spacing = 0
        permissionRows.translatesAutoresizingMaskIntoConstraints = false

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
        if let storageLocation {
            let dataLabel = NSTextField(labelWithString: "Data:")
            dataLabel.font = .systemFont(ofSize: 10)
            dataLabel.textColor = .secondaryLabelColor

            let storage: NSView
            if let storageLocationURL {
                let pathButton = PointingHandButton(
                    title: storageLocation,
                    target: self,
                    action: #selector(openStorageLocation)
                )
                pathButton.isBordered = false
                pathButton.setAccessibilityLabel("Open data folder in Finder")
                pathButton.setAccessibilityValue(storageLocation)
                pathButton.setAccessibilityHelp("Opens the Try Omarchy data folder in Finder")
                pathButton.attributedTitle = NSAttributedString(
                    string: storageLocation,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                )
                pathButton.alignment = .left
                pathButton.toolTip = storageLocationURL.path
                pathButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
                storage = pathButton
            } else {
                let pathLabel = NSTextField(labelWithString: storageLocation)
                pathLabel.font = .systemFont(ofSize: 10)
                pathLabel.textColor = .secondaryLabelColor
                storage = pathLabel
            }

            let storageRow = NSStackView(views: [dataLabel, storage])
            storageRow.orientation = .horizontal
            storageRow.alignment = .centerY
            storageRow.spacing = 3
            storage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            resetViews.append(storageRow)
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
        stack.setCustomSpacing(22, after: headingStack)
        stack.setCustomSpacing(12, after: permissionCard)
        stack.setCustomSpacing(20, after: resetSection)
        stack.setCustomSpacing(10, after: launchButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 42),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -42),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -30),
            permissionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resetSection.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            launchButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
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
        granted: Bool,
        statusLabels: (granted: String, denied: String),
        actions: [(String, Selector)]
    ) -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        symbol.contentTintColor = .controlAccentColor
        symbol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 26),
            symbol.heightAnchor.constraint(equalToConstant: 26),
        ])

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 14, weight: .semibold)

        let explanation = NSTextField(wrappingLabelWithString: detail)
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 2

        let labels = NSStackView(views: [name, explanation])
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
        status.setContentHuggingPriority(.required, for: .horizontal)

        var trailingViews: [NSView] = [status]
        for (actionTitle, action) in actions {
            let button = NSButton(title: actionTitle, target: self, action: action)
            button.controlSize = .small
            button.isEnabled = !microphoneRequestInFlight && !launchInProgress && !resetInProgress
            button.identifier = NSUserInterfaceItemIdentifier("permission-action-\(symbolName)")
            trailingViews.append(button)
        }
        let trailing = NSStackView(views: trailingViews)
        trailing.orientation = .vertical
        trailing.alignment = .trailing
        trailing.spacing = 6

        let row = NSStackView(views: [symbol, labels, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 76),
            trailing.widthAnchor.constraint(equalToConstant: 112),
        ])
        if let button = trailingViews.last as? NSButton {
            button.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true
        }
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
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
        guard let storageLocationURL else { return }
        do {
            if !FileManager.default.fileExists(atPath: storageLocationURL.path) {
                try FileManager.default.createDirectory(
                    at: storageLocationURL,
                    withIntermediateDirectories: true,
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

    private func confirmReset() {
        guard canResetStorage, !launchInProgress, !resetInProgress else { return }
        let estimate = storageSpaceEstimate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset Omarchy to factory settings?"
        var detail = "This permanently erases everything in this Omarchy virtual machine, including apps, files, accounts, and settings. This cannot be undone or recovered."
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
