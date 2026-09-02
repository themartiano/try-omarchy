import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu appearance", .serialized)
@MainActor
struct StartMenuAppearanceTests {
    @Test("permission card border follows the effective appearance")
    func permissionCardBorder() throws {
        _ = NSApplication.shared
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))
        let card = PermissionCardView(frame: .zero)

        card.appearance = lightAppearance
        let lightBorder = try #require(card.layer?.borderColor)
        #expect(lightBorder == separatorColor(for: lightAppearance))

        card.appearance = darkAppearance
        let darkBorder = try #require(card.layer?.borderColor)
        #expect(darkBorder == separatorColor(for: darkAppearance))
        #expect(darkBorder != lightBorder)
    }

    private func separatorColor(for appearance: NSAppearance) -> CGColor {
        var color = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.separatorColor.cgColor
        }
        return color
    }
}
