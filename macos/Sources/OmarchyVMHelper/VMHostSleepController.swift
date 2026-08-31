import Foundation

enum VMHostSleepControlError: LocalizedError, Equatable {
    case pauseOutcomeUnknown(String)
    case unsafeResumeState(String)

    var errorDescription: String? {
        switch self {
        case .pauseOutcomeUnknown(let detail):
            "QEMU may have paused before its acknowledgement was received: \(detail)"
        case .unsafeResumeState(let state):
            "QEMU is in the \(state) state; refusing to override that pause"
        }
    }
}

struct VMHostWakeRetryPolicy {
    private let delays: [TimeInterval]
    private var nextDelayIndex = 0

    init(delays: [TimeInterval] = [0.25, 0.75, 1.5, 3.0]) {
        self.delays = delays
    }

    mutating func nextDelay() -> TimeInterval? {
        guard nextDelayIndex < delays.count else { return nil }
        defer { nextDelayIndex += 1 }
        return delays[nextDelayIndex]
    }

    mutating func reset() {
        nextDelayIndex = 0
    }
}

protocol VMHostSleepControlling: AnyObject {
    /// Returns true only when STOP was observed while this call's stop command
    /// was pending for a VM that had just reported itself running.
    func pauseIfRunning() throws -> Bool
    func resume() throws
    func close()
}

final class QMPVMHostSleepController: VMHostSleepControlling {
    typealias ConnectionFactory = () throws -> QMPConnection

    private let makeConnection: ConnectionFactory
    /// Retaining the QMP session that performed `stop` keeps QEMU's
    /// single-client monitor occupied through wake. A second controller cannot
    /// insert an ordinary pause between our STOP transition and matching cont.
    private var sleepConnection: QMPConnection?

    init(socketPath: String) throws {
        let factory: ConnectionFactory = {
            try QMPConnection(
                socketPath: socketPath,
                identifierPrefix: "omarchy-host-power"
            )
        }
        makeConnection = factory
        let probe = try factory()
        probe.close()
    }

    init(connectionFactory: @escaping ConnectionFactory, validateImmediately: Bool = true) throws {
        makeConnection = connectionFactory
        if validateImmediately {
            let probe = try connectionFactory()
            probe.close()
        }
    }

    func pauseIfRunning() throws -> Bool {
        var lastError: Error?
        // A connection can briefly lag while macOS is entering sleep. Retry
        // only failures that happen before `stop`; once `stop` is sent, its
        // outcome must remain ambiguous rather than issuing it again.
        for _ in 0..<2 {
            do {
                return try pauseOnFreshConnection()
            } catch let error as VMHostSleepControlError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError ?? HelperError.io("QMP pause failed")
    }

    private func pauseOnFreshConnection() throws -> Bool {
        let connection = try makeConnection()
        var keepConnectionForWake = false
        defer {
            if !keepConnectionForWake {
                connection.close()
            }
        }
        let status = try connection.execute("query-status")
        guard let running = status["running"] as? Bool else {
            throw HelperError.io("QMP query-status response omitted the VM run state")
        }
        // A VM can already be paused for an I/O error or another control
        // client. Host wake must never resume a pause it did not create.
        guard running else { return false }
        do {
            let execution = try connection.executeCapturingEvents("stop")
            // QEMU emits STOP while executing `stop`, before its matching
            // response. Requiring an observed transition avoids claiming a
            // VM that was already paused when this command reached QEMU.
            let observedStop = execution.events.contains("STOP")
            if observedStop {
                sleepConnection?.close()
                sleepConnection = connection
                keepConnectionForWake = true
            }
            return observedStop
        } catch {
            // The write may have reached QEMU even if its acknowledgement did
            // not reach us. The coordinator records possible ownership so a
            // fresh connection will still attempt recovery after wake.
            throw VMHostSleepControlError.pauseOutcomeUnknown(
                error.localizedDescription
            )
        }
    }

    func resume() throws {
        var lastError: Error?
        // The clean path uses the session that owns the pause. If it broke
        // across sleep, retry on a fresh session. A retry also resolves the
        // case where `cont` succeeded but its response was lost: the second
        // query observes an already-running VM.
        for _ in 0..<2 {
            do {
                let connection: QMPConnection
                if let heldConnection = sleepConnection {
                    sleepConnection = nil
                    connection = heldConnection
                } else {
                    connection = try makeConnection()
                }
                defer { connection.close() }
                let status = try connection.execute("query-status")
                guard let running = status["running"] as? Bool else {
                    throw HelperError.io("QMP query-status response omitted the VM run state")
                }
                if !running {
                    guard let runState = status["status"] as? String else {
                        throw HelperError.io("QMP query-status response omitted the VM status")
                    }
                    // `cont` clears some QEMU error stops. Never turn an I/O,
                    // watchdog, migration, or internal-error stop back into a
                    // running VM merely because host sleep also paused it.
                    guard runState == "paused" else {
                        throw VMHostSleepControlError.unsafeResumeState(runState)
                    }
                    _ = try connection.execute("cont")
                }
                return
            } catch let error as VMHostSleepControlError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError ?? HelperError.io("QMP resume failed")
    }

    func close() {
        sleepConnection?.close()
        sleepConnection = nil
    }
}

/// Owns the pause across exactly one host sleep/wake cycle.
///
/// Keeping this policy outside AppKit makes duplicate notifications, process
/// exits, and pre-existing QEMU pauses deterministic and testable.
final class VMHostSleepCoordinator {
    private var controller: (any VMHostSleepControlling)?
    private(set) var pausedForHostSleep = false

    func connect(to socketPath: String) throws {
        attach(try QMPVMHostSleepController(socketPath: socketPath))
    }

    func attach(_ controller: any VMHostSleepControlling) {
        disconnect()
        self.controller = controller
    }

    func disconnect() {
        controller?.close()
        controller = nil
        pausedForHostSleep = false
    }

    func prepareForHostSleep(vmIsRunning: Bool, isStopping: Bool) throws {
        guard vmIsRunning,
              !isStopping,
              !pausedForHostSleep,
              let controller else { return }
        do {
            if try controller.pauseIfRunning() {
                pausedForHostSleep = true
            }
        } catch let error as VMHostSleepControlError {
            if case .pauseOutcomeUnknown = error {
                pausedForHostSleep = true
            }
            throw error
        }
    }

    func resumeAfterHostWake(vmIsRunning: Bool, isStopping: Bool) throws {
        guard pausedForHostSleep else { return }
        guard vmIsRunning, !isStopping, let controller else {
            pausedForHostSleep = false
            return
        }
        do {
            try controller.resume()
            pausedForHostSleep = false
        } catch let error as VMHostSleepControlError {
            // An abnormal QEMU stop supersedes this sleep cycle. Relinquish
            // ownership without issuing cont so a later healthy cycle can be
            // paused normally again.
            if case .unsafeResumeState = error {
                pausedForHostSleep = false
            }
            throw error
        }
    }
}
