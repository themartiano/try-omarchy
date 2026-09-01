import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Permission window restoration", .serialized)
@MainActor
struct PermissionWindowRestorerTests {
    @Test("an inactive callback orders globally before waiting for activation")
    func inactiveApplication() {
        let harness = Harness(isActive: false)
        let frame = NSRect(x: 90, y: 120, width: 600, height: 760)

        harness.restorer.requestDidFinish(preserving: frame)

        #expect(harness.events == [.orderRegardless(frame), .activate])
        #expect(harness.restorer.isPending)

        harness.isActive = true
        harness.restorer.applicationDidBecomeActive()

        #expect(harness.events == [
            .orderRegardless(frame),
            .activate,
            .makeKeyAndOrderFront(frame),
        ])
        #expect(harness.restorer.isPending)

        harness.runScheduledActions()
        #expect(!harness.restorer.isPending)
    }

    @Test("an activation that wins the callback race finishes immediately")
    func alreadyActiveApplication() {
        let harness = Harness(isActive: true)
        let frame = NSRect(x: 30, y: 40, width: 600, height: 760)

        harness.restorer.requestDidFinish(preserving: frame)

        #expect(harness.events == [
            .orderRegardless(frame),
            .makeKeyAndOrderFront(frame),
        ])
        #expect(harness.restorer.isPending)

        harness.runScheduledActions()
        #expect(!harness.restorer.isPending)
    }

    @Test("post-dismissal retries reassert ordering after an early activation")
    func postDismissalRetries() {
        let harness = Harness(isActive: false)
        let frame = NSRect(x: 10, y: 20, width: 600, height: 760)
        harness.restorer.requestDidFinish(preserving: frame)
        harness.isActive = true

        harness.restorer.applicationDidBecomeActive()
        harness.runScheduledActions()

        #expect(harness.events.filter {
            if case .orderRegardless = $0 { true } else { false }
        }.count == 3)
        #expect(harness.events.filter {
            if case .makeKeyAndOrderFront = $0 { true } else { false }
        }.count == 3)
        #expect(harness.events.filter { $0 == .activate }.count == 1)
        #expect(!harness.restorer.isPending)
    }

    @Test("a dismissed menu is never resurrected")
    func cancelledRestoration() {
        let harness = Harness(isActive: false)
        let frame = NSRect(x: 10, y: 20, width: 600, height: 760)
        harness.restorer.requestDidFinish(preserving: frame)

        harness.canRestore = false
        harness.restorer.cancel()
        harness.isActive = true
        harness.restorer.applicationDidBecomeActive()
        harness.runScheduledActions()

        #expect(harness.events == [.orderRegardless(frame), .activate])
        #expect(!harness.restorer.isPending)
    }

    @Test("a new permission request invalidates retries from the previous request")
    func newPermissionRequestCancelsStaleRetries() {
        let harness = Harness(isActive: false)
        let firstFrame = NSRect(x: 10, y: 20, width: 600, height: 760)
        let secondFrame = NSRect(x: 40, y: 50, width: 600, height: 760)
        harness.restorer.requestDidFinish(preserving: firstFrame)

        harness.restorer.cancel()
        harness.isActive = true
        harness.restorer.requestDidFinish(preserving: secondFrame)
        harness.runScheduledActions()

        #expect(harness.events.filter { $0 == .orderRegardless(firstFrame) }.count == 1)
        #expect(harness.events.filter { $0 == .orderRegardless(secondFrame) }.count == 3)
        #expect(harness.events.filter { $0 == .makeKeyAndOrderFront(firstFrame) }.isEmpty)
        #expect(harness.events.filter { $0 == .makeKeyAndOrderFront(secondFrame) }.count == 3)
        #expect(harness.events.filter { $0 == .activate }.count == 1)
        #expect(!harness.restorer.isPending)
    }

    @Test("activation cancels restoration when the menu can no longer be shown")
    func activationAfterMenuBecomesUnavailable() {
        let harness = Harness(isActive: false)
        let frame = NSRect(x: 10, y: 20, width: 600, height: 760)
        harness.restorer.requestDidFinish(preserving: frame)

        harness.canRestore = false
        harness.isActive = true
        harness.restorer.applicationDidBecomeActive()
        harness.runScheduledActions()

        #expect(harness.events == [.orderRegardless(frame), .activate])
        #expect(!harness.restorer.isPending)
    }

    @Test("failed activation remains pending after bounded retries")
    func activationNeverArrives() {
        let harness = Harness(isActive: false)
        let frame = NSRect(x: 10, y: 20, width: 600, height: 760)
        harness.restorer.requestDidFinish(preserving: frame)

        harness.runScheduledActions()

        #expect(harness.events.filter {
            if case .orderRegardless = $0 { true } else { false }
        }.count == 3)
        #expect(harness.events.filter { $0 == .activate }.count == 3)
        #expect(harness.restorer.isPending)

        harness.isActive = true
        harness.restorer.applicationDidBecomeActive()
        #expect(harness.events.last == .makeKeyAndOrderFront(frame))
        #expect(!harness.restorer.isPending)
    }

    @Test("the custom heading hides the duplicate native title")
    func windowChrome() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        StartMenuWindowChrome.apply(to: window)

        #expect(window.title == "Try Omarchy")
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.isMovableByWindowBackground)
        #expect(!window.isReleasedWhenClosed)
        window.close()

        let editor = PortForwardingEditor(mappings: [], save: { _ in nil })
        #expect(editor.window.title == "Port Forwarding")
        #expect(editor.window.titleVisibility == .hidden)
        editor.dismiss()
    }
}

@MainActor
private final class Harness {
    enum Event: Equatable {
        case orderRegardless(NSRect)
        case activate
        case makeKeyAndOrderFront(NSRect)
    }

    var canRestore = true
    var isActive: Bool
    var events: [Event] = []
    var scheduledActions: [(TimeInterval, @MainActor () -> Void)] = []
    lazy var restorer = PermissionWindowRestorer(
        canRestore: { [unowned self] in canRestore },
        isApplicationActive: { [unowned self] in isActive },
        orderFrontRegardless: { [unowned self] frame in
            events.append(.orderRegardless(frame))
        },
        activateApplication: { [unowned self] in
            events.append(.activate)
        },
        makeKeyAndOrderFront: { [unowned self] frame in
            events.append(.makeKeyAndOrderFront(frame))
        },
        retryDelays: [0.1, 0.3],
        schedule: { [unowned self] delay, action in
            scheduledActions.append((delay, action))
        }
    )

    init(isActive: Bool) {
        self.isActive = isActive
    }

    func runScheduledActions() {
        let actions = scheduledActions.sorted { $0.0 < $1.0 }
        scheduledActions.removeAll()
        for (_, action) in actions {
            action()
        }
    }
}
