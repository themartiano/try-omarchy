import Foundation
import Testing

@Suite("Immersive presentation native contract")
struct FullscreenNativeContractTests {
    @Test("Runner keeps focused keyboard capture independent of presentation")
    func runnerMapping() throws {
        let runner = try source(named: "run-qemu-gpu.sh")

        #expect(runner.contains("case ${OMARCHY_QEMU_GPU_IMMERSIVE:-1} in"))
        #expect(runner.contains("cocoa_full_screen=on\n    cocoa_immersive=on"))
        #expect(runner.contains("cocoa_full_screen=off\n    cocoa_immersive=off"))
        #expect(runner.contains("OMARCHY_QEMU_GPU_IMMERSIVE must be 0 or 1"))
        #expect(runner.contains(
            "full-screen=$cocoa_full_screen,full-grab=on,immersive=$cocoa_immersive,swap-opt-cmd=off"
        ))
        #expect(!runner.contains("cocoa_full_grab"))
    }

    @Test("Cocoa separates fullscreen presentation from focused keyboard capture")
    func cocoaBehavior() throws {
        let immersivePatch = try source(named: "patches/qemu-cocoa-immersive-mode.patch")
        let keyboardPatch = try source(named: "patches/qemu-cocoa-full-grab-focus.patch")

        #expect(immersivePatch.contains("'*immersive': 'bool'"))
        #expect(immersivePatch.contains("if (!immersive_mode_enabled)"))
        #expect(immersivePatch.contains("return proposedOptions;"))
        #expect(immersivePatch.contains("[fullScreenMenuItem setTitle:@\"Exit Full Screen\"]"))
        #expect(immersivePatch.contains("[fullScreenMenuItem setTitle:@\"Enter Full Screen\"]"))

        let fileScopeState = [
            " static bool swap_opt_cmd;",
            "+static bool full_grab_enabled;",
            "+static bool immersive_mode_enabled = true;",
            "+static NSMenuItem *fullScreenMenuItem;",
            " ",
            " static bool zoom_interpolation;",
        ].joined(separator: "\n")
        #expect(immersivePatch.contains(fileScopeState))
        #expect(!immersivePatch.contains("+    NSMenuItem *fullScreenMenuItem;"))

        #expect(keyboardPatch.contains(
            "return isMouseGrabbed ||\n" +
            "+           (full_grab_enabled && [[self window] isKeyWindow]);"
        ))
        #expect(keyboardPatch.contains("if ([view isKeyboardCaptured]"))
        #expect(keyboardPatch.contains("if (![self isKeyboardCaptured]"))

        let configuration = try #require(
            immersivePatch.range(of: "immersive_mode_enabled = !opts->u.cocoa.has_immersive")
        )
        let fullScreenEntry = try #require(
            immersivePatch.range(of: "[[cocoaView window] toggleFullScreen: nil]")
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
