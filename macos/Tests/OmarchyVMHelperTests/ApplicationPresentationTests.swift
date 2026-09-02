import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Application presentation", .serialized)
@MainActor
struct ApplicationPresentationTests {
    @Test("the start menu behaves like a regular app before yielding to QEMU")
    func activationPolicies() {
        #expect(ApplicationPresentation.prelaunchActivationPolicy == .regular)
        #expect(ApplicationPresentation.runningActivationPolicy == .accessory)
    }

    @Test("the application menu exposes standard quit and window shortcuts")
    func standardApplicationMenu() throws {
        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        let previousWindowMenu = application.windowsMenu
        defer {
            application.mainMenu = previousMainMenu
            application.windowsMenu = previousWindowMenu
        }

        ApplicationPresentation.installMainMenu(
            in: application,
            applicationName: "Try Omarchy"
        )

        let appMenu = try #require(application.mainMenu?.items.first?.submenu)
        let quit = try #require(appMenu.items.first(where: {
            $0.title == "Quit Try Omarchy"
        }))
        #expect(quit.keyEquivalent == "q")
        #expect(quit.action == #selector(NSApplication.terminate(_:)))

        let windowMenu = try #require(application.windowsMenu)
        let close = try #require(windowMenu.items.first(where: {
            $0.title == "Close Window"
        }))
        #expect(close.keyEquivalent == "w")
        #expect(close.action == #selector(NSWindow.performClose(_:)))
    }
}
