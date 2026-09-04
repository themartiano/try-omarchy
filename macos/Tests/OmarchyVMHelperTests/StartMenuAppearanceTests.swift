import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu appearance", .serialized)
@MainActor
struct StartMenuAppearanceTests {
    @Test("start menu keeps the Omarchy appearance across system themes")
    func brandedWindowAppearance() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        window.appearance = NSAppearance(named: .aqua)
        StartMenuWindowChrome.apply(to: window)

        #expect(window.appearance?.name == .darkAqua)
        #expect(window.backgroundColor == OmarchyStartMenuTheme.background)
        #expect(window.isOpaque)
    }

    @Test("Omarchy controls retain native keyboard and accessibility behavior")
    func brandedControlBehavior() {
        _ = NSApplication.shared
        let action = OmarchyActionButton(
            title: "Launch Omarchy",
            style: .primary,
            target: nil,
            action: nil
        )
        action.keyEquivalent = "\r"

        #expect(action.keyEquivalent == "\r")
        #expect(action.accessibilityLabel() == "Launch Omarchy")
        #expect(action.attributedTitle.string == "LAUNCH OMARCHY")
        #expect(action.focusRingType == .exterior)
        #expect(!action.isBordered)

        let toggle = OmarchyToggleButton(isOn: true, target: nil, action: nil)
        #expect(toggle.state == .on)
        #expect(toggle.accessibilityLabel() == "Immersive mode")
        #expect(toggle.accessibilityValue() as? String == "On")
        #expect(toggle.attributedTitle.string == "[ ON ]")

        toggle.state = .off
        #expect(toggle.accessibilityValue() as? String == "Off")
        #expect(toggle.attributedTitle.string == "[ OFF ]")
    }
}
