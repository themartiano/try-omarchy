import Foundation
import Testing

@Suite("Immersive Full Screen native contract")
struct FullscreenNativeContractTests {
    @Test("Runner keeps both modes full screen and maps the grab policy")
    func runnerMapping() throws {
        let runner = try source(named: "run-qemu-gpu.sh")

        #expect(runner.contains("case ${OMARCHY_QEMU_GPU_IMMERSIVE:-1} in"))
        #expect(runner.contains("1) cocoa_full_grab=on ;;"))
        #expect(runner.contains("0) cocoa_full_grab=off ;;"))
        #expect(runner.contains("OMARCHY_QEMU_GPU_IMMERSIVE must be 0 or 1"))
        #expect(runner.contains(
            "full-screen=on,full-grab=$cocoa_full_grab,swap-opt-cmd=off"
        ))
    }

    @Test("Cocoa standard mode reveals host controls and keeps the exit action accurate")
    func cocoaBehavior() throws {
        let patch = try source(named: "patches/qemu-cocoa-immersive-mode.patch")

        #expect(patch.contains("if (!full_grab_enabled)"))
        #expect(patch.contains("return proposedOptions;"))
        #expect(patch.contains("(!isMouseGrabbed || !full_grab_enabled)"))
        #expect(patch.contains("[fullScreenMenuItem setTitle:@\"Exit Full Screen\"]"))
        #expect(patch.contains("[fullScreenMenuItem setTitle:@\"Enter Full Screen\"]"))

        #expect(patch.contains(
            " static bool swap_opt_cmd;\n" +
            "+static bool full_grab_enabled;\n" +
            "+static NSMenuItem *fullScreenMenuItem;\n" +
            " \n" +
            " static bool zoom_interpolation;"
        ))
        #expect(!patch.contains("+    NSMenuItem *fullScreenMenuItem;"))

        let configuration = try #require(
            patch.range(of: "full_grab_enabled = opts->u.cocoa.has_full_grab")
        )
        let fullScreenEntry = try #require(
            patch.range(of: "[[cocoaView window] toggleFullScreen: nil]")
        )
        #expect(configuration.lowerBound < fullScreenEntry.lowerBound)
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
