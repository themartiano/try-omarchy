import AppKit

enum OmarchyControlStyle {
    case primary
    case secondary
    case danger
}

final class OmarchyActionButton: NSButton {
    private let omarchyStyle: OmarchyControlStyle
    private let displayTitle: String
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isPointerDown = false

    init(
        title: String,
        style: OmarchyControlStyle,
        target: AnyObject?,
        action: Selector?
    ) {
        displayTitle = title.uppercased()
        omarchyStyle = style
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setAccessibilityLabel(title)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isEnabled: Bool {
        didSet { refreshAppearance() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            super.mouseDown(with: event)
            return
        }
        isPointerDown = true
        refreshAppearance()
        super.mouseDown(with: event)
        isPointerDown = false
        refreshAppearance()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }

    private func configure() {
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        refreshAppearance()
    }

    private func refreshAppearance() {
        guard let layer else { return }

        let background: NSColor
        let foreground: NSColor
        let border: NSColor

        if !isEnabled {
            background = OmarchyStartMenuTheme.lighterBackground.withAlphaComponent(0.45)
            foreground = OmarchyStartMenuTheme.muted.withAlphaComponent(0.48)
            border = OmarchyStartMenuTheme.lighterBackground.withAlphaComponent(0.7)
        } else {
            switch omarchyStyle {
            case .primary:
                background = isPointerDown
                    ? OmarchyStartMenuTheme.cyan
                    : (isPointerInside ? OmarchyStartMenuTheme.hover : OmarchyStartMenuTheme.accent)
                foreground = OmarchyStartMenuTheme.background
                border = background
            case .secondary:
                background = isPointerDown
                    ? OmarchyStartMenuTheme.lighterBackground
                    : OmarchyStartMenuTheme.darkBackground
                foreground = isPointerInside
                    ? OmarchyStartMenuTheme.hover
                    : OmarchyStartMenuTheme.foreground
                border = isPointerInside
                    ? OmarchyStartMenuTheme.accent
                    : OmarchyStartMenuTheme.lighterBackground
            case .danger:
                background = isPointerDown || isPointerInside
                    ? OmarchyStartMenuTheme.danger
                    : OmarchyStartMenuTheme.darkBackground
                foreground = isPointerDown || isPointerInside
                    ? OmarchyStartMenuTheme.background
                    : OmarchyStartMenuTheme.danger
                border = OmarchyStartMenuTheme.danger
            }
        }

        layer.backgroundColor = background.cgColor
        layer.borderColor = border.cgColor
        layer.shadowOpacity = omarchyStyle == .primary && isEnabled ? 0.22 : 0
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = NSSize(width: 0, height: -2)
        layer.shadowRadius = 0
        attributedTitle = NSAttributedString(
            string: displayTitle,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: foreground,
                .kern: 0.35,
            ]
        )
    }
}

final class OmarchyToggleButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false

    init(isOn: Bool, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setButtonType(.toggle)
        state = isOn ? .on : .off
        setAccessibilityLabel("Immersive mode")
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var state: NSControl.StateValue {
        didSet { refreshAppearance() }
    }

    override var isEnabled: Bool {
        didSet { refreshAppearance() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        refreshAppearance()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }

    func refreshAppearance() {
        guard let layer else { return }
        let isOn = state == .on
        let background: NSColor
        let foreground: NSColor
        let border: NSColor

        if !isEnabled {
            background = OmarchyStartMenuTheme.lighterBackground.withAlphaComponent(0.4)
            foreground = OmarchyStartMenuTheme.muted.withAlphaComponent(0.48)
            border = OmarchyStartMenuTheme.lighterBackground
        } else if isOn {
            background = isPointerInside ? OmarchyStartMenuTheme.hover : OmarchyStartMenuTheme.accent
            foreground = OmarchyStartMenuTheme.background
            border = background
        } else {
            background = OmarchyStartMenuTheme.darkBackground
            foreground = isPointerInside ? OmarchyStartMenuTheme.hover : OmarchyStartMenuTheme.foreground
            border = isPointerInside ? OmarchyStartMenuTheme.accent : OmarchyStartMenuTheme.lighterBackground
        }

        layer.backgroundColor = background.cgColor
        layer.borderColor = border.cgColor
        attributedTitle = NSAttributedString(
            string: isOn ? "[ ON ]" : "[ OFF ]",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: foreground,
                .kern: 0.25,
            ]
        )
        setAccessibilityValue(isOn ? "On" : "Off")
    }

    private func configure() {
        isBordered = false
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 66),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        refreshAppearance()
    }
}
