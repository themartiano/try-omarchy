import Darwin
import AppKit
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("VM host sleep lifecycle")
struct VMHostSleepCoordinatorTests {
    @Test("one successful pause owns exactly one matching resume")
    func idempotentSleepWakeCycle() throws {
        let controller = FakeHostSleepController(pauseResult: true)
        let coordinator = VMHostSleepCoordinator()
        coordinator.attach(controller)

        try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
        try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
        #expect(controller.pauseCalls == 1)
        #expect(coordinator.pausedForHostSleep)

        try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
        try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
        #expect(controller.resumeCalls == 1)
        #expect(!coordinator.pausedForHostSleep)
    }

    @Test("a VM paused by another cause is never resumed on host wake")
    func doesNotOwnExistingPause() throws {
        let controller = FakeHostSleepController(pauseResult: false)
        let coordinator = VMHostSleepCoordinator()
        coordinator.attach(controller)

        try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
        try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)

        #expect(controller.pauseCalls == 1)
        #expect(controller.resumeCalls == 0)
        #expect(!coordinator.pausedForHostSleep)
    }

    @Test("pause failure and inactive lifecycle states cannot create resume ownership")
    func failedAndInactivePausesDoNotResume() throws {
        let controller = FakeHostSleepController(pauseResult: true)
        let coordinator = VMHostSleepCoordinator()
        coordinator.attach(controller)

        try coordinator.prepareForHostSleep(vmIsRunning: false, isStopping: false)
        try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: true)
        #expect(controller.pauseCalls == 0)

        controller.pauseError = TestControlError.expected
        #expect(throws: TestControlError.self) {
            try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
        }
        #expect(!coordinator.pausedForHostSleep)
        try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
        #expect(controller.resumeCalls == 0)
    }

    @Test("an ambiguous stop acknowledgement is recovered on wake")
    func ambiguousPauseStillOwnsRecovery() throws {
        let controller = FakeHostSleepController(pauseResult: true)
        controller.pauseError = VMHostSleepControlError.pauseOutcomeUnknown("reply lost")
        let coordinator = VMHostSleepCoordinator()
        coordinator.attach(controller)

        #expect(throws: VMHostSleepControlError.self) {
            try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
        }
        #expect(coordinator.pausedForHostSleep)

        try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
        #expect(controller.resumeCalls == 1)
        #expect(!coordinator.pausedForHostSleep)
    }

    @Test("a failed wake retains ownership so a delayed retry can recover")
    func failedWakeCanRetry() throws {
        let controller = FakeHostSleepController(pauseResult: true)
        let coordinator = VMHostSleepCoordinator()
        coordinator.attach(controller)
        try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)

        controller.resumeError = TestControlError.expected
        #expect(throws: TestControlError.self) {
            try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
        }
        #expect(coordinator.pausedForHostSleep)

        controller.resumeError = nil
        try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
        #expect(controller.resumeCalls == 2)
        #expect(!coordinator.pausedForHostSleep)
    }

    @Test("an abnormal QEMU stop is left untouched and releases sleep ownership")
    func unsafeWakeRelinquishesOwnership() throws {
        let controller = FakeHostSleepController(pauseResult: true)
        let coordinator = VMHostSleepCoordinator()
        coordinator.attach(controller)
        try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)

        controller.resumeError = VMHostSleepControlError.unsafeResumeState("io-error")
        #expect(throws: VMHostSleepControlError.self) {
            try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)
        }
        #expect(!coordinator.pausedForHostSleep)
    }

    @Test("wake retry backoff is bounded and resettable")
    func boundedWakeRetryPolicy() {
        var policy = VMHostWakeRetryPolicy(delays: [0.25, 0.75])
        #expect(policy.nextDelay() == 0.25)
        #expect(policy.nextDelay() == 0.75)
        #expect(policy.nextDelay() == nil)
        policy.reset()
        #expect(policy.nextDelay() == 0.25)
    }

    @Test("child exit while asleep drops the control session without resuming it")
    func exitWhileAsleepClearsOwnership() throws {
        let controller = FakeHostSleepController(pauseResult: true)
        let coordinator = VMHostSleepCoordinator()
        coordinator.attach(controller)
        try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)

        coordinator.disconnect()
        try coordinator.resumeAfterHostWake(vmIsRunning: false, isStopping: false)

        #expect(controller.closeCalls == 1)
        #expect(controller.resumeCalls == 0)
        #expect(!coordinator.pausedForHostSleep)
    }
}

@Suite("Host power notifications")
@MainActor
struct HostPowerNotificationObserverTests {
    @Test("sleep is synchronous and wake uses the workspace notification names")
    func observesWorkspaceSleepAndWake() {
        let center = NotificationCenter()
        var events = ["before-sleep"]
        let observer = HostPowerNotificationObserver(
            center: center,
            onWillSleep: {
                events.append("pause-start")
                events.append("pause-finished")
            },
            onDidWake: {
                events.append("wake")
            }
        )
        defer { observer.stop() }

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        events.append("after-sleep")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(events == [
            "before-sleep",
            "pause-start",
            "pause-finished",
            "after-sleep",
            "wake",
        ])
    }
}

@Suite("QMP host sleep control")
struct QMPVMHostSleepControllerTests {
    @Test("bundled Cocoa controls cannot bypass QMP pause ownership")
    func cocoaPauseOwnershipContract() throws {
        let patch = try Self.source(
            named: "patches/qemu-cocoa-pause-ownership.patch"
        )
        let build = try Self.source(named: "build-qemu-gpu-runtime.sh")

        #expect(patch.contains(
            "-    [menu addItem: [[[NSMenuItem alloc] initWithTitle: @\"Pause\" " +
            "action: @selector(pauseQEMU:)"
        ))
        #expect(patch.contains(
            "-    menuItem = [[[NSMenuItem alloc] initWithTitle: @\"Resume\" " +
            "action: @selector(resumeQEMU:)"
        ))
        #expect(patch.contains(
            "[menu addItem: [[[NSMenuItem alloc] initWithTitle: @\"Reset\""
        ))
        #expect(build.contains(
            "pause_ownership_patch=\"$native_dir/patches/" +
            "qemu-cocoa-pause-ownership.patch\""
        ))
        #expect(build.contains(
            "patch -d \"$source_dir\" -p1 -f -i \"$pause_ownership_patch\""
        ))
    }

    @Test("negotiates capabilities and correlates stop and cont replies past events")
    func pauseAndResumeTranscript() throws {
        let transcript = LockedQMPTranscript()
        let sessions = try [
            Self.startServer(steps: [], transcript: transcript),
            Self.startServer(steps: [
                TestStep(
                    command: "query-status",
                    result: ["running": true, "status": "running"],
                    events: ["RTC_CHANGE"]
                ),
                TestStep(command: "stop", result: [:], events: ["STOP"]),
                TestStep(
                    command: "query-status",
                    result: ["running": false, "status": "paused"]
                ),
                TestStep(command: "cont", result: [:], events: ["RESUME"]),
            ], transcript: transcript),
        ]
        let descriptors = LockedDescriptorQueue(sessions.map(\.clientDescriptor))
        let controller = try QMPVMHostSleepController(connectionFactory: {
            guard let descriptor = descriptors.take() else {
                throw HelperError.io("unexpected extra QMP connection")
            }
            return try QMPConnection(
                connectedDescriptor: descriptor,
                identifierPrefix: "test-host-power"
            )
        })
        #expect(try controller.pauseIfRunning())
        try controller.resume()
        controller.close()

        for session in sessions {
            #expect(session.finished.wait(timeout: .now() + 2) == .success)
        }
        #expect(transcript.errorDescription == nil)
        #expect(transcript.commands == [
            "qmp_capabilities",
            "qmp_capabilities",
            "query-status",
            "stop",
            "query-status",
            "cont",
        ])
        #expect(descriptors.isEmpty)
    }

    @Test("retries a transient connection failure before sending stop")
    func retriesBeforeStop() throws {
        let transcript = LockedQMPTranscript()
        let sessions = try [
            Self.startServer(steps: [], transcript: transcript),
            Self.startServer(steps: [
                TestStep(
                    command: "query-status",
                    result: ["running": true, "status": "running"]
                ),
                TestStep(command: "stop", result: [:], events: ["STOP"]),
            ], transcript: transcript),
        ]
        let descriptors = LockedDescriptorQueue(sessions.map(\.clientDescriptor))
        let invocations = LockedInvocationCounter()
        let controller = try QMPVMHostSleepController(connectionFactory: {
            if invocations.next() == 2 {
                throw TestControlError.expected
            }
            guard let descriptor = descriptors.take() else {
                throw HelperError.io("unexpected extra QMP connection")
            }
            return try QMPConnection(
                connectedDescriptor: descriptor,
                identifierPrefix: "test-host-power"
            )
        })

        #expect(try controller.pauseIfRunning())

        for session in sessions {
            #expect(session.finished.wait(timeout: .now() + 2) == .success)
        }
        #expect(transcript.errorDescription == nil)
        #expect(transcript.commands == [
            "qmp_capabilities",
            "qmp_capabilities",
            "query-status",
            "stop",
        ])
        #expect(descriptors.isEmpty)
    }

    @Test("does not own a stop that produced no transition event")
    func noStopTransitionMeansNoWakeResume() throws {
        let transcript = LockedQMPTranscript()
        let sessions = try [
            Self.startServer(steps: [], transcript: transcript),
            Self.startServer(steps: [
                TestStep(
                    command: "query-status",
                    result: ["running": true, "status": "running"]
                ),
                TestStep(command: "stop", result: [:]),
            ], transcript: transcript),
        ]
        let descriptors = LockedDescriptorQueue(sessions.map(\.clientDescriptor))
        let controller = try QMPVMHostSleepController(connectionFactory: {
            guard let descriptor = descriptors.take() else {
                throw HelperError.io("unexpected extra QMP connection")
            }
            return try QMPConnection(
                connectedDescriptor: descriptor,
                identifierPrefix: "test-host-power"
            )
        })
        let coordinator = VMHostSleepCoordinator()
        coordinator.attach(controller)

        try coordinator.prepareForHostSleep(vmIsRunning: true, isStopping: false)
        #expect(!coordinator.pausedForHostSleep)
        try coordinator.resumeAfterHostWake(vmIsRunning: true, isStopping: false)

        for session in sessions {
            #expect(session.finished.wait(timeout: .now() + 2) == .success)
        }
        #expect(transcript.errorDescription == nil)
        #expect(transcript.commands == [
            "qmp_capabilities",
            "qmp_capabilities",
            "query-status",
            "stop",
        ])
        #expect(descriptors.isEmpty)
    }

    @Test("does not override a QEMU I/O-error stop on wake")
    func refusesUnsafeResumeState() throws {
        let transcript = LockedQMPTranscript()
        let sessions = try [
            Self.startServer(steps: [], transcript: transcript),
            Self.startServer(steps: [
                TestStep(
                    command: "query-status",
                    result: ["running": false, "status": "io-error"]
                ),
            ], transcript: transcript),
        ]
        let descriptors = LockedDescriptorQueue(sessions.map(\.clientDescriptor))
        let controller = try QMPVMHostSleepController(connectionFactory: {
            guard let descriptor = descriptors.take() else {
                throw HelperError.io("unexpected extra QMP connection")
            }
            return try QMPConnection(
                connectedDescriptor: descriptor,
                identifierPrefix: "test-host-power"
            )
        })

        #expect(throws: VMHostSleepControlError.self) {
            try controller.resume()
        }

        for session in sessions {
            #expect(session.finished.wait(timeout: .now() + 2) == .success)
        }
        #expect(transcript.errorDescription == nil)
        #expect(transcript.commands == [
            "qmp_capabilities",
            "qmp_capabilities",
            "query-status",
        ])
        #expect(descriptors.isEmpty)
    }

    private struct TestStep: @unchecked Sendable {
        let command: String
        let result: [String: Any]
        let events: [String]

        init(command: String, result: [String: Any], events: [String] = []) {
            self.command = command
            self.result = result
            self.events = events
        }
    }

    private struct TestSession {
        let clientDescriptor: Int32
        let finished: DispatchSemaphore
    }

    private static func startServer(
        steps: [TestStep],
        transcript: LockedQMPTranscript
    ) throws -> TestSession {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw HelperError.io("cannot create test QMP socket pair")
        }
        let serverDescriptor = descriptors[1]
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                Darwin.close(serverDescriptor)
                finished.signal()
            }
            do {
                try QMPConnection.writeJSON([
                    "QMP": [
                        "version": [
                            "qemu": ["major": 10, "minor": 2, "micro": 0],
                            "package": "",
                        ],
                        "capabilities": [],
                    ],
                ], to: serverDescriptor)
                let capabilities = try readJSON(from: serverDescriptor)
                let capabilitiesCommand = try string("execute", in: capabilities)
                guard capabilitiesCommand == "qmp_capabilities" else {
                    throw HelperError.io(
                        "expected qmp_capabilities, received \(capabilitiesCommand)"
                    )
                }
                transcript.append(capabilitiesCommand)
                try respond(
                    id: try string("id", in: capabilities),
                    result: [:],
                    to: serverDescriptor
                )

                for step in steps {
                    let request = try readJSON(from: serverDescriptor)
                    let command = try string("execute", in: request)
                    guard command == step.command else {
                        throw HelperError.io(
                            "expected QMP command \(step.command), received \(command)"
                        )
                    }
                    transcript.append(command)
                    for event in step.events {
                        try QMPConnection.writeJSON(["event": event], to: serverDescriptor)
                    }
                    try respond(
                        id: try string("id", in: request),
                        result: step.result,
                        to: serverDescriptor
                    )
                }
            } catch {
                transcript.record(error)
            }
        }
        return TestSession(clientDescriptor: descriptors[0], finished: finished)
    }

    private static func readJSON(from descriptor: Int32) throws -> [String: Any] {
        var data = Data()
        while data.count <= 1_048_576 {
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    guard let object = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else {
                        throw HelperError.io("test QMP request is not an object")
                    }
                    return object
                }
                if byte != 0x0D { data.append(byte) }
            } else if count == 0 {
                throw HelperError.io("test QMP client closed early")
            } else if errno != EINTR {
                throw HelperError.io("cannot read test QMP request")
            }
        }
        throw HelperError.io("test QMP request is too large")
    }

    private static func string(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String else {
            throw HelperError.io("test QMP request omitted \(key)")
        }
        return value
    }

    private static func respond(
        id: String,
        result: [String: Any],
        to descriptor: Int32
    ) throws {
        try QMPConnection.writeJSON([
            "return": result,
            "id": id,
        ], to: descriptor)
    }

    private static func source(named relativePath: String) throws -> String {
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

private enum TestControlError: Error {
    case expected
}

private final class FakeHostSleepController: VMHostSleepControlling {
    let pauseResult: Bool
    var pauseError: Error?
    var resumeError: Error?
    private(set) var pauseCalls = 0
    private(set) var resumeCalls = 0
    private(set) var closeCalls = 0

    init(pauseResult: Bool) {
        self.pauseResult = pauseResult
    }

    func pauseIfRunning() throws -> Bool {
        pauseCalls += 1
        if let pauseError { throw pauseError }
        return pauseResult
    }

    func resume() throws {
        resumeCalls += 1
        if let resumeError { throw resumeError }
    }

    func close() {
        closeCalls += 1
    }
}

private final class LockedQMPTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommands: [String] = []
    private var storedErrorDescription: String?

    var commands: [String] {
        lock.withLock { storedCommands }
    }

    var errorDescription: String? {
        lock.withLock { storedErrorDescription }
    }

    func append(_ command: String) {
        lock.withLock {
            storedCommands.append(command)
        }
    }

    func record(_ error: Error) {
        lock.withLock {
            storedErrorDescription = error.localizedDescription
        }
    }
}

private final class LockedDescriptorQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32]

    init(_ descriptors: [Int32]) {
        self.descriptors = descriptors
    }

    deinit {
        for descriptor in descriptors {
            Darwin.close(descriptor)
        }
    }

    var isEmpty: Bool {
        lock.withLock { descriptors.isEmpty }
    }

    func take() -> Int32? {
        lock.withLock {
            guard !descriptors.isEmpty else { return nil }
            return descriptors.removeFirst()
        }
    }
}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
