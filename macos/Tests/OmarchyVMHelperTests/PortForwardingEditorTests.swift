import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Port forwarding editor interactions", .serialized)
@MainActor
struct PortForwardingEditorTests {
    @Test("adds and saves an ordered TCP and UDP mapping list")
    func addsAndSavesMappings() throws {
        _ = NSApplication.shared
        var saved: [PortForwardMapping]?
        let editor = PortForwardingEditor(mappings: [], save: {
            saved = $0
            return nil
        })
        editor.show()
        defer { editor.dismiss() }

        let content = try #require(editor.window.contentView)
        let add = try button("port-forward-add", in: content)
        add.performClick(nil)
        try enter(host: "8080", guest: "3000", row: 0, in: content, editor: editor)

        add.performClick(nil)
        try enter(host: "5353", guest: "5353", row: 1, in: content, editor: editor)
        let protocolPicker = try #require(
            descendant(withIdentifier: "port-forward-protocol-1", in: content) as? NSPopUpButton
        )
        protocolPicker.selectItem(withTitle: "UDP")
        _ = protocolPicker.sendAction(protocolPicker.action, to: protocolPicker.target)

        let save = try button("port-forward-save", in: content)
        #expect(save.isEnabled)
        save.performClick(nil)

        #expect(saved == [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
        ])
    }

    @Test("removes one mapping without disturbing the surrounding rows")
    func removesMiddleMapping() throws {
        _ = NSApplication.shared
        let initial = [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 2222, guestPort: 22, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
        ]
        var saved: [PortForwardMapping]?
        let editor = PortForwardingEditor(mappings: initial, save: {
            saved = $0
            return nil
        })
        editor.show()
        defer { editor.dismiss() }

        let content = try #require(editor.window.contentView)
        try button("port-forward-remove-1", in: content).performClick(nil)
        #expect(descendant(withIdentifier: "port-forward-row-2", in: content) == nil)

        let newSecondHost = try #require(
            descendant(withIdentifier: "port-forward-host-1", in: content) as? NSTextField
        )
        #expect(newSecondHost.stringValue == "5353")
        #expect(newSecondHost.accessibilityLabel() == "Mac port for mapping 2")
        #expect(newSecondHost.currentEditor() === editor.window.firstResponder)
        try button("port-forward-save", in: content).performClick(nil)

        #expect(saved == [initial[0], initial[2]])
    }

    @Test("invalid and duplicate ports explain the problem and cannot be saved")
    func validatesDraftsLive() throws {
        _ = NSApplication.shared
        let editor = PortForwardingEditor(mappings: [], save: { _ in nil })
        editor.show()
        defer { editor.dismiss() }
        let content = try #require(editor.window.contentView)
        let add = try button("port-forward-add", in: content)

        add.performClick(nil)
        try enter(host: "70000", guest: "3000", row: 0, in: content, editor: editor)
        let save = try button("port-forward-save", in: content)
        let validation = try #require(
            descendant(withIdentifier: "port-forward-validation", in: content) as? NSTextField
        )
        #expect(!save.isEnabled)
        #expect(validation.stringValue.contains("1 to 65535"))
        #expect(validation.textColor == .systemRed)

        try enter(host: "8080", guest: "3000", row: 0, in: content, editor: editor)
        add.performClick(nil)
        try enter(host: "8080", guest: "4000", row: 1, in: content, editor: editor)
        #expect(!save.isEnabled)
        #expect(validation.stringValue == "Mac TCP port 8080 is already mapped.")

        let protocolPicker = try #require(
            descendant(withIdentifier: "port-forward-protocol-1", in: content) as? NSPopUpButton
        )
        protocolPicker.selectItem(withTitle: "UDP")
        _ = protocolPicker.sendAction(protocolPicker.action, to: protocolPicker.target)
        #expect(save.isEnabled)
        #expect(validation.stringValue.isEmpty)
        #expect(validation.isHidden)
    }

    @Test("many mappings stay inside a vertically scrollable list")
    func longListsScroll() throws {
        _ = NSApplication.shared
        let mappings = (0..<12).map {
            PortForwardMapping(hostPort: 8_000 + $0, guestPort: 3_000 + $0, protocol: .tcp)
        }
        let editor = PortForwardingEditor(mappings: mappings, save: { _ in nil })
        editor.show()
        defer { editor.dismiss() }

        let content = try #require(editor.window.contentView)
        content.layoutSubtreeIfNeeded()
        let scroll = try #require(
            descendant(withIdentifier: "port-forward-scroll", in: content) as? NSScrollView
        )
        let document = try #require(scroll.documentView)
        document.layoutSubtreeIfNeeded()
        #expect(document.frame.height > scroll.contentView.bounds.height)
        #expect(descendant(withIdentifier: "port-forward-row-11", in: document) != nil)

        let maximumOffset = document.frame.height - scroll.contentView.bounds.height
        #expect(maximumOffset > 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximumOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY > 0)
    }

    @Test("repeated adds focus and reveal the newest row up to the limit")
    func repeatedAddsReachLimit() throws {
        _ = NSApplication.shared
        let editor = PortForwardingEditor(mappings: [], save: { _ in nil })
        editor.show()
        defer { editor.dismiss() }

        let content = try #require(editor.window.contentView)
        let add = try button("port-forward-add", in: content)
        for _ in 0..<PortForwardPolicy.maximumMappings {
            add.performClick(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let lastIndex = PortForwardPolicy.maximumMappings - 1
        let lastHost = try #require(
            descendant(withIdentifier: "port-forward-host-\(lastIndex)", in: content)
                as? NSTextField
        )
        let scroll = try #require(
            descendant(withIdentifier: "port-forward-scroll", in: content) as? NSScrollView
        )
        #expect(lastHost.currentEditor() === editor.window.firstResponder)
        #expect(lastHost.accessibilityLabel() == "Mac port for mapping 32")
        #expect(!add.isEnabled)
        add.performClick(nil)
        #expect(descendant(withIdentifier: "port-forward-row-32", in: content) == nil)
        #expect(scroll.contentView.bounds.minY > 0)
    }

    @Test("empty state and unchanged content do not offer a meaningless save")
    func emptyState() throws {
        _ = NSApplication.shared
        let editor = PortForwardingEditor(mappings: [], save: { _ in nil })
        editor.show()
        defer { editor.dismiss() }

        let content = try #require(editor.window.contentView)
        #expect(descendant(withIdentifier: "port-forward-empty", in: content) != nil)
        #expect(!(try button("port-forward-save", in: content)).isEnabled)
        let explanation = try #require(
            descendant(withIdentifier: "port-forward-explanation", in: content) as? NSTextField
        )
        let validation = try #require(
            descendant(withIdentifier: "port-forward-validation", in: content) as? NSTextField
        )
        #expect(explanation.stringValue == "Mac → Omarchy mappings expose guest services on Mac localhost. For Omarchy → Mac, connect to 10.0.2.2.")
        #expect(validation.stringValue.isEmpty)
        #expect(validation.isHidden)
        let footer = try #require(validation.superview as? NSStackView)
        #expect(footer.orientation == .vertical)
        #expect(footer.arrangedSubviews == [try button("port-forward-add", in: content), validation])
        #expect(editor.window.frame.width == 540)
        #expect(editor.window.frame.height <= 470)
    }

    private func enter(
        host: String,
        guest: String,
        row: Int,
        in content: NSView,
        editor: PortForwardingEditor
    ) throws {
        let hostField = try #require(
            descendant(withIdentifier: "port-forward-host-\(row)", in: content) as? NSTextField
        )
        let guestField = try #require(
            descendant(withIdentifier: "port-forward-guest-\(row)", in: content) as? NSTextField
        )
        hostField.stringValue = host
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: hostField))
        guestField.stringValue = guest
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: guestField))
    }

    private func button(_ identifier: String, in root: NSView) throws -> NSButton {
        try #require(descendant(withIdentifier: identifier, in: root) as? NSButton)
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
