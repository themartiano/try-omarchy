import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Focused Command to guest Super")
struct FocusedCommandCaptureTests {
    private func event(
        _ kind: CommandBridgeEventKind,
        _ keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        marker: Int64 = 0
    ) -> CommandBridgeEvent {
        CommandBridgeEvent(kind: kind, keyCode: keyCode, flags: flags, marker: marker)
    }

    @Test("captures a focused Command chord without changing physical Option")
    func capturesFocusedChord() {
        var state = FocusedCommandCaptureState()
        let commandDown = state.process(event(
            .flagsChanged,
            FocusedCommandCaptureState.leftCommand,
            flags: [.maskCommand]
        ), focused: true)
        #expect(commandDown.suppress)
        #expect(commandDown.forwarded.isEmpty)
        #expect(commandDown.guestMeta == [.init(key: .left, down: true)])

        let keyDown = state.process(event(
            .keyDown,
            0,
            flags: [.maskCommand, .maskAlternate, .maskShift]
        ), focused: true)
        #expect(keyDown.suppress)
        #expect(keyDown.guestMeta.isEmpty)
        #expect(keyDown.forwarded.count == 1)
        #expect(!keyDown.forwarded[0].flags.contains(.maskCommand))
        #expect(keyDown.forwarded[0].flags.contains(.maskAlternate))
        #expect(keyDown.forwarded[0].flags.contains(.maskShift))
        #expect(keyDown.forwarded[0].marker == FocusedCommandCaptureState.recursionMarker)

        let keyUp = state.process(event(.keyUp, 0, flags: [.maskCommand]), focused: true)
        #expect(keyUp.suppress)
        #expect(keyUp.forwarded == [event(
            .keyUp,
            0,
            marker: FocusedCommandCaptureState.recursionMarker
        )])

        let commandUp = state.process(event(
            .flagsChanged,
            FocusedCommandCaptureState.leftCommand
        ), focused: true)
        #expect(commandUp.suppress)
        #expect(commandUp.guestMeta == [.init(key: .left, down: false)])
        #expect(!state.isCapturing)
    }

    @Test("translates Command-Space after capture")
    func translatesCommandSpace() {
        let space: CGKeyCode = 49
        var state = FocusedCommandCaptureState()

        _ = state.process(event(
            .flagsChanged,
            FocusedCommandCaptureState.leftCommand,
            flags: [.maskCommand]
        ), focused: true)
        let spaceDown = state.process(event(
            .keyDown,
            space,
            flags: [.maskCommand]
        ), focused: true)

        #expect(spaceDown.suppress)
        #expect(spaceDown.forwarded == [event(
            .keyDown,
            space,
            marker: FocusedCommandCaptureState.recursionMarker
        )])
    }

    @Test("does not capture Command outside the focused QEMU window")
    func ignoresUnfocusedCommand() {
        var state = FocusedCommandCaptureState()
        let outcome = state.process(event(
            .flagsChanged,
            FocusedCommandCaptureState.leftCommand,
            flags: [.maskCommand]
        ), focused: false)
        #expect(!outcome.suppress)
        #expect(outcome.forwarded.isEmpty)
        #expect(outcome.guestMeta.isEmpty)
        #expect(!state.isCapturing)
    }

    @Test("focus loss releases forwarded keys and both guest Meta keys")
    func releasesOnFocusLoss() {
        var state = FocusedCommandCaptureState()
        _ = state.process(event(
            .flagsChanged,
            FocusedCommandCaptureState.leftCommand,
            flags: [.maskCommand]
        ), focused: true)
        _ = state.process(event(
            .flagsChanged,
            FocusedCommandCaptureState.rightCommand,
            flags: [.maskCommand]
        ), focused: true)
        _ = state.process(event(.keyDown, 12, flags: [.maskCommand]), focused: true)

        let focusLoss = state.process(event(.keyDown, 1), focused: false)
        #expect(!focusLoss.suppress)
        #expect(focusLoss.forwarded.map(\.kind) == [.keyUp])
        #expect(focusLoss.forwarded.map(\.keyCode) == [12])
        #expect(focusLoss.guestMeta == [
            .init(key: .right, down: false),
            .init(key: .left, down: false),
        ])
        #expect(!state.isCapturing)
    }

    @Test("reposted events bypass capture using the private marker")
    func bypassesRepostedEvents() {
        var state = FocusedCommandCaptureState()
        let outcome = state.process(event(
            .keyDown,
            12,
            flags: [.maskCommand],
            marker: FocusedCommandCaptureState.recursionMarker
        ), focused: true)
        #expect(!outcome.suppress)
        #expect(outcome.forwarded.isEmpty)
        #expect(outcome.guestMeta.isEmpty)
    }

    @Test("recovers a balanced guest Meta pair when focus starts mid-chord")
    func recoversMidChord() {
        var state = FocusedCommandCaptureState()
        let keyDown = state.process(event(.keyDown, 13, flags: [.maskCommand]), focused: true)
        #expect(keyDown.guestMeta == [.init(key: .left, down: true)])
        #expect(keyDown.forwarded.count == 1)

        let released = state.releaseAll()
        #expect(released.forwarded.map(\.keyCode) == [13])
        #expect(released.guestMeta == [.init(key: .left, down: false)])
        #expect(!state.isCapturing)
    }

    @Test("fatal injection teardown discards state without retrying releases")
    func discardsWithoutRelease() {
        var state = FocusedCommandCaptureState()
        _ = state.process(event(
            .flagsChanged,
            FocusedCommandCaptureState.leftCommand,
            flags: [.maskCommand]
        ), focused: true)
        _ = state.process(event(.keyDown, 13, flags: [.maskCommand]), focused: true)
        #expect(state.isCapturing)

        state.discardAll()
        #expect(!state.isCapturing)
        #expect(state.releaseAll() == CommandBridgeOutcome())
    }
}

@Suite("QMP Meta injection")
struct QMPMetaKeyClientTests {
    @Test("a closed QMP connection makes command writes throw")
    func closedSocketThrows() throws {
        var descriptors: [Int32] = [-1, -1]
        let created = descriptors.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return Int32(-1) }
            return socketpair(AF_UNIX, SOCK_STREAM, 0, base)
        }
        #expect(created == 0)
        #expect(descriptors[0] >= 0 && descriptors[1] >= 0)
        defer {
            if descriptors[0] >= 0 { Darwin.close(descriptors[0]) }
            if descriptors[1] >= 0 { Darwin.close(descriptors[1]) }
        }

        var noSignal: Int32 = 1
        #expect(withUnsafePointer(to: &noSignal) {
            setsockopt(
                descriptors[0],
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        } == 0)

        // Half-close the peer so the next write must observe EPIPE even if a
        // tiny payload would otherwise sit in the local send buffer.
        #expect(Darwin.shutdown(descriptors[1], SHUT_RDWR) == 0)
        Darwin.close(descriptors[1])
        descriptors[1] = -1

        #expect(throws: HelperError.self) {
            // Keep writing until the kernel reports the broken pipe. A single
            // small write has been observed to succeed on CI before the peer
            // close is visible to the writer.
            for _ in 0..<4_096 {
                try QMPMetaKeyClient.writeJSON(
                    ["execute": "input-send-event"],
                    to: descriptors[0]
                )
            }
        }
    }
}

@Suite("Kernel QEMU process identity")
struct KernelProcessIdentityTests {
    @Test("accepts the branded app runtime and exact qemu-system basenames")
    func validatesExecutableName() {
        for path in [
            "/private/runtime/Try Omarchy",
            "/private/runtime/qemu-system-aarch64",
        ] {
            let valid = KernelProcessIdentity(
                processIdentifier: 42,
                executablePath: path,
                startSeconds: 100,
                startMicroseconds: 200
            )
            #expect(valid.isQEMUSystemProcess)
        }

        for path in [
            "/private/runtime/Try Omarchy.app",
            "/private/runtime/not Try Omarchy",
            "/private/runtime/qemu-system-",
            "/private/runtime/not-qemu-system-aarch64",
            "/private/runtime/qemu-system-aarch64.app",
            "/private/runtime/qemu-system-aarch64/other",
        ] {
            let invalid = KernelProcessIdentity(
                processIdentifier: 42,
                executablePath: path,
                startSeconds: 100,
                startMicroseconds: 200
            )
            #expect(!invalid.isQEMUSystemProcess)
        }
    }

    @Test("captures a stable kernel identity for the current process")
    func capturesCurrentProcess() {
        let identity = KernelProcessIdentity.capture(processIdentifier: getpid())
        #expect(identity != nil)
        #expect(identity?.processIdentifier == getpid())
        #expect(identity?.isStillRunning == true)
        #expect(identity?.isQEMUSystemProcess == false)
    }
}
