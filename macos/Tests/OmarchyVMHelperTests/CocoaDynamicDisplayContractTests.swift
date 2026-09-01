import Foundation
import Testing

@Suite("Cocoa dynamic display native contract")
struct CocoaDynamicDisplayContractTests {
    @Test("Windowed mode starts at 75 percent of the usable screen")
    func initialWindowFrame() throws {
        let patch = try source(named: "patches/qemu-cocoa-dynamic-display.patch")

        #expect(patch.contains("NSRect available = [hostScreen visibleFrame]"))
        #expect(patch.contains("NSWidth(available) * 0.75 / 16.0"))
        #expect(patch.contains("NSHeight(available) * 0.75 / 9.0"))
        #expect(patch.contains("NSSize size = NSMakeSize(16.0 * unit, 9.0 * unit)"))
        #expect(patch.contains("NSMidX(available)"))
        #expect(patch.contains("NSMidY(available)"))
        #expect(!patch.contains("1920.0 / MAX(backingScale"))
        #expect(!patch.contains("1080.0 / MAX(backingScale"))
    }

    private func source(named relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let macosDirectory = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: macosDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
