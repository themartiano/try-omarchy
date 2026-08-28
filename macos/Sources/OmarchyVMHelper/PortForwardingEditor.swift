import AppKit
import Foundation

/// A fixed-size editor keeps a growing forwarding list out of the launch menu.
/// Rows scroll independently once they no longer fit in the sheet.
@MainActor
final class PortForwardingEditor: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    typealias SaveHandler = ([PortForwardMapping]) -> String?

    private struct Draft {
        var hostPort: String
        var guestPort: String
        var `protocol`: PortForwardProtocol

        init(mapping: PortForwardMapping) {
            hostPort = String(mapping.hostPort)
            guestPort = String(mapping.guestPort)
            `protocol` = mapping.protocol
        }

        init() {
            hostPort = ""
            guestPort = ""
            `protocol` = .tcp
        }
    }

    private enum FieldKind: Int {
        case host = 0
        case guest = 1
    }

    private struct Validation {
        let mappings: [PortForwardMapping]?
        let message: String
        let isError: Bool
    }

    private let initialMappings: [PortForwardMapping]
    private let saveHandler: SaveHandler
    private let closeHandler: () -> Void
    private var drafts: [Draft]

    private(set) var window: NSWindow!
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let saveButton = NSButton()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private var announcedValidationError: String?

    init(
        mappings: [PortForwardMapping],
        save: @escaping SaveHandler,
        didClose: @escaping () -> Void = {}
    ) {
        initialMappings = mappings
        saveHandler = save
        closeHandler = didClose
        drafts = mappings.map(Draft.init(mapping:))
        super.init()
        buildWindow()
        rebuildRows()
    }

    func beginSheet(for parent: NSWindow) {
        parent.beginSheet(window)
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        closeWindow()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeWindow()
        return false
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Port Forwarding"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setAccessibilityLabel("Port Forwarding")

        let title = NSTextField(labelWithString: "Port forwarding")
        title.font = .systemFont(ofSize: 21, weight: .bold)

        let explanation = NSTextField(
            wrappingLabelWithString: "Mac → Omarchy mappings expose guest services on Mac localhost. For Omarchy → Mac, connect to \(PortForwardPolicy.guestToHostAddress)."
        )
        explanation.font = .systemFont(ofSize: 12.5)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 2
        explanation.identifier = NSUserInterfaceItemIdentifier("port-forward-explanation")

        let heading = NSStackView(views: [title, explanation])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 5

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.identifier = NSUserInterfaceItemIdentifier("port-forward-scroll")
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 224),
        ])

        addButton.title = "Add Port"
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .rounded
        addButton.controlSize = .regular
        addButton.target = self
        addButton.action = #selector(addPort)
        addButton.identifier = NSUserInterfaceItemIdentifier("port-forward-add")
        addButton.setAccessibilityHelp("Adds another localhost-to-Omarchy port mapping")

        validationLabel.font = .systemFont(ofSize: 11.5)
        validationLabel.maximumNumberOfLines = 2
        validationLabel.identifier = NSUserInterfaceItemIdentifier("port-forward-validation")
        validationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let listFooter = NSStackView(views: [addButton, validationLabel])
        listFooter.orientation = .vertical
        listFooter.alignment = .leading
        listFooter.spacing = 6

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.identifier = NSUserInterfaceItemIdentifier("port-forward-cancel")

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.identifier = NSUserInterfaceItemIdentifier("port-forward-save")

        let spacer = NSView()
        let actions = NSStackView(views: [spacer, cancelButton, saveButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let contentStack = NSStackView(views: [heading, scrollView, listFooter, actions])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.setCustomSpacing(18, after: heading)
        contentStack.setCustomSpacing(18, after: listFooter)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(contentStack)
        window.contentView = content
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            heading.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            listFooter.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
    }

    private func rebuildRows(
        focusRow: Int? = nil,
        focusAddButton: Bool = false,
        scrollToBottom: Bool = false
    ) {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if drafts.isEmpty {
            addFullWidthArrangedSubview(emptyState())
        } else {
            for index in drafts.indices {
                if index > drafts.startIndex {
                    addFullWidthArrangedSubview(separator())
                }
                addFullWidthArrangedSubview(mappingRow(at: index))
            }
        }

        updateValidation()
        rowsStack.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()

        if let index = focusRow,
           let field = descendant(
               withIdentifier: "port-forward-host-\(index)",
               in: rowsStack
            ) as? NSTextField {
            window.makeFirstResponder(field)
            reveal(field: field, atBottom: scrollToBottom)
            // Repeat after AppKit's next layout pass in case the document grew.
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, field.window === self.window else { return }
                self.reveal(field: field, atBottom: scrollToBottom)
            }
        } else if focusAddButton {
            window.makeFirstResponder(addButton)
        }
    }

    private func emptyState() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "No ports forwarded")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        let detail = NSTextField(
            wrappingLabelWithString: "Add a port for a guest service listening beyond guest localhost."
        )
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 2

        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("port-forward-empty")
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -30),
        ])
        return container
    }

    private func mappingRow(at index: Int) -> NSView {
        let draft = drafts[index]
        let localhost = secondaryLabel("localhost:")
        let hostField = portField(value: draft.hostPort, index: index, kind: .host)
        let arrow = secondaryLabel("→")
        arrow.alignment = .center
        let guest = secondaryLabel("Omarchy:")
        let guestField = portField(value: draft.guestPort, index: index, kind: .guest)

        let protocolPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        protocolPicker.addItems(withTitles: PortForwardProtocol.allCases.map(\.displayName))
        protocolPicker.selectItem(withTitle: draft.protocol.displayName)
        protocolPicker.controlSize = .regular
        protocolPicker.target = self
        protocolPicker.action = #selector(protocolChanged(_:))
        protocolPicker.tag = index
        protocolPicker.identifier = NSUserInterfaceItemIdentifier("port-forward-protocol-\(index)")
        protocolPicker.setAccessibilityLabel("Protocol for mapping \(index + 1)")
        protocolPicker.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let remove = NSButton(
            image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: #selector(removePort(_:))
        )
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.tag = index
        remove.identifier = NSUserInterfaceItemIdentifier("port-forward-remove-\(index)")
        remove.setAccessibilityLabel("Remove mapping \(index + 1)")
        remove.toolTip = "Remove this mapping"
        remove.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let rowStack = NSStackView(
            views: [localhost, hostField, arrow, guest, guestField, protocolPicker, remove]
        )
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 7
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.identifier = NSUserInterfaceItemIdentifier("port-forward-row-\(index)")
        row.addSubview(rowStack)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 48),
            rowStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            rowStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func portField(value: String, index: Int, kind: FieldKind) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = kind == .host ? "8080" : "3000"
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.controlSize = .regular
        field.delegate = self
        field.tag = (index * 2) + kind.rawValue
        field.identifier = NSUserInterfaceItemIdentifier(
            kind == .host ? "port-forward-host-\(index)" : "port-forward-guest-\(index)"
        )
        field.setAccessibilityLabel(
            kind == .host
                ? "Mac port for mapping \(index + 1)"
                : "Omarchy port for mapping \(index + 1)"
        )
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return field
    }

    private func secondaryLabel(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    private func separator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func addFullWidthArrangedSubview(_ view: NSView) {
        rowsStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let index = field.tag / 2
        guard drafts.indices.contains(index), let kind = FieldKind(rawValue: field.tag % 2) else {
            return
        }
        switch kind {
        case .host:
            drafts[index].hostPort = field.stringValue
        case .guest:
            drafts[index].guestPort = field.stringValue
        }
        updateValidation()
    }

    @objc private func protocolChanged(_ sender: NSPopUpButton) {
        guard drafts.indices.contains(sender.tag),
              let rawValue = sender.titleOfSelectedItem?.lowercased(),
              let protocolValue = PortForwardProtocol(rawValue: rawValue) else { return }
        drafts[sender.tag].protocol = protocolValue
        updateValidation()
    }

    @objc private func addPort() {
        guard drafts.count < PortForwardPolicy.maximumMappings else { return }
        drafts.append(Draft())
        rebuildRows(
            focusRow: drafts.index(before: drafts.endIndex),
            scrollToBottom: true
        )
    }

    @objc private func removePort(_ sender: NSButton) {
        guard drafts.indices.contains(sender.tag) else { return }
        let removedIndex = sender.tag
        drafts.remove(at: removedIndex)
        if drafts.isEmpty {
            rebuildRows(focusAddButton: true)
        } else {
            rebuildRows(focusRow: min(removedIndex, drafts.index(before: drafts.endIndex)))
        }
    }

    @objc private func cancel() {
        closeWindow()
    }

    @objc private func save() {
        let validation = validation()
        guard let mappings = validation.mappings else {
            updateValidation()
            return
        }
        if let problem = saveHandler(mappings) {
            validationLabel.stringValue = problem
            validationLabel.textColor = .systemRed
            saveButton.isEnabled = false
            return
        }
        closeWindow()
    }

    private func updateValidation() {
        let validation = validation()
        validationLabel.stringValue = validation.message
        validationLabel.isHidden = validation.message.isEmpty
        validationLabel.textColor = validation.isError ? .systemRed : .secondaryLabelColor
        if validation.isError, announcedValidationError != validation.message {
            announcedValidationError = validation.message
            NSAccessibility.post(
                element: validationLabel,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: validation.message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        } else if !validation.isError {
            announcedValidationError = nil
        }
        let hasChanges = validation.mappings.map { $0 != initialMappings } ?? false
        saveButton.isEnabled = validation.mappings != nil && hasChanges
        addButton.isEnabled = drafts.count < PortForwardPolicy.maximumMappings
        addButton.toolTip = addButton.isEnabled
            ? "Add a port mapping"
            : "Up to \(PortForwardPolicy.maximumMappings) mappings are supported"
    }

    private func validation() -> Validation {
        guard !drafts.isEmpty else {
            return Validation(mappings: [], message: "", isError: false)
        }

        var mappings: [PortForwardMapping] = []
        for (offset, draft) in drafts.enumerated() {
            let row = offset + 1
            let host = draft.hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
            let guest = draft.guestPort.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !guest.isEmpty else {
                return Validation(
                    mappings: nil,
                    message: "",
                    isError: false
                )
            }
            guard host.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let hostPort = Int(host),
                  PortForwardPolicy.validPortRange.contains(hostPort) else {
                return Validation(
                    mappings: nil,
                    message: "Mac port in mapping \(row) must be a number from 1 to 65535.",
                    isError: true
                )
            }
            guard guest.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let guestPort = Int(guest),
                  PortForwardPolicy.validPortRange.contains(guestPort) else {
                return Validation(
                    mappings: nil,
                    message: "Omarchy port in mapping \(row) must be a number from 1 to 65535.",
                    isError: true
                )
            }
            mappings.append(
                PortForwardMapping(
                    hostPort: hostPort,
                    guestPort: guestPort,
                    protocol: draft.protocol
                )
            )
        }

        do {
            try PortForwardPolicy.validate(mappings)
        } catch {
            return Validation(
                mappings: nil,
                message: error.localizedDescription,
                isError: true
            )
        }

        return Validation(
            mappings: mappings,
            message: "",
            isError: false
        )
    }

    private func closeWindow() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        }
        window.orderOut(nil)
        closeHandler()
    }

    private func reveal(field: NSTextField, atBottom: Bool) {
        window.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        if atBottom {
            let documentHeight = scrollView.documentView?.frame.height
                ?? rowsStack.frame.height
            scrollView.contentView.scroll(
                to: NSPoint(
                    x: 0,
                    y: max(0, documentHeight - scrollView.contentView.bounds.height)
                )
            )
        } else if let document = scrollView.documentView {
            document.scrollToVisible(field.convert(field.bounds, to: document))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func descendant(withIdentifier value: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == value { return root }
        for child in root.subviews {
            if let match = descendant(withIdentifier: value, in: child) {
                return match
            }
        }
        return nil
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
