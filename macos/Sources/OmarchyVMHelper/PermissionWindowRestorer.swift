import AppKit

/// Restores an accessory-app window after a system-owned permission prompt.
///
/// App activation is asynchronous. `makeKeyAndOrderFront` only orders a
/// window against windows in the same application, so calling it immediately
/// after requesting activation can still leave the window behind the app that
/// macOS made active while dismissing the prompt.
@MainActor
final class PermissionWindowRestorer {
    typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private let canRestore: () -> Bool
    private let isApplicationActive: () -> Bool
    private let orderFrontRegardless: (NSRect) -> Void
    private let activateApplication: () -> Void
    private let makeKeyAndOrderFront: (NSRect) -> Void
    private let retryDelays: [TimeInterval]
    private let schedule: Scheduler

    private var pendingFrame: NSRect?
    private var requestGeneration = 0
    private var finalRetryCompleted = false

    init(
        canRestore: @escaping () -> Bool,
        isApplicationActive: @escaping () -> Bool,
        orderFrontRegardless: @escaping (NSRect) -> Void,
        activateApplication: @escaping () -> Void,
        makeKeyAndOrderFront: @escaping (NSRect) -> Void,
        retryDelays: [TimeInterval],
        schedule: @escaping Scheduler
    ) {
        self.canRestore = canRestore
        self.isApplicationActive = isApplicationActive
        self.orderFrontRegardless = orderFrontRegardless
        self.activateApplication = activateApplication
        self.makeKeyAndOrderFront = makeKeyAndOrderFront
        self.retryDelays = retryDelays
        self.schedule = schedule
    }

    var isPending: Bool { pendingFrame != nil }

    func requestDidFinish(preserving frame: NSRect) {
        guard canRestore() else {
            cancel()
            return
        }

        requestGeneration &+= 1
        let generation = requestGeneration
        pendingFrame = frame
        finalRetryCompleted = false
        restore(frame: frame)

        // AVFoundation can invoke its completion handler before the system
        // permission host finishes dismissing and reordering its own window.
        // Reassert after that teardown instead of trusting the first ordering.
        for (index, delay) in retryDelays.enumerated() {
            let isFinalRetry = index == retryDelays.indices.last
            schedule(delay) { [weak self] in
                self?.retry(
                    generation: generation,
                    frame: frame,
                    isFinalRetry: isFinalRetry
                )
            }
        }
    }

    func applicationDidBecomeActive() {
        guard let frame = pendingFrame else { return }
        guard canRestore() else {
            cancel()
            return
        }
        makeKeyAndOrderFront(frame)
        if finalRetryCompleted {
            pendingFrame = nil
        }
    }

    func cancel() {
        requestGeneration &+= 1
        pendingFrame = nil
        finalRetryCompleted = false
    }

    private func retry(generation: Int, frame: NSRect, isFinalRetry: Bool) {
        guard generation == requestGeneration, pendingFrame != nil else { return }
        guard canRestore() else {
            cancel()
            return
        }
        restore(frame: frame)
        if isFinalRetry {
            finalRetryCompleted = true
            if isApplicationActive() {
                pendingFrame = nil
            }
        }
    }

    private func restore(frame: NSRect) {
        // This is the only NSWindow ordering operation that explicitly works
        // while another application is active. Restoring the frame here also
        // prevents prompt teardown from recascading the start menu.
        orderFrontRegardless(frame)
        if isApplicationActive() {
            makeKeyAndOrderFront(frame)
        } else {
            activateApplication()
        }
    }
}
