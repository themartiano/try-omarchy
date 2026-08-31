import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum GuestMetaKey: String, Equatable {
    case left = "meta_l"
    case right = "meta_r"
}

struct GuestMetaTransition: Equatable {
    let key: GuestMetaKey
    let down: Bool
}

enum CommandBridgeEventKind: Equatable {
    case keyDown
    case keyUp
    case flagsChanged

    init?(_ type: CGEventType) {
        switch type {
        case .keyDown: self = .keyDown
        case .keyUp: self = .keyUp
        case .flagsChanged: self = .flagsChanged
        default: return nil
        }
    }

    var cgEventType: CGEventType {
        switch self {
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .flagsChanged: .flagsChanged
        }
    }
}

struct CommandBridgeEvent: Equatable {
    let kind: CommandBridgeEventKind
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let marker: Int64
}

struct CommandBridgeOutcome: Equatable {
    var suppress = false
    var forwarded: [CommandBridgeEvent] = []
    var guestMeta: [GuestMetaTransition] = []
}

/// Pure keyboard state used by the focused QEMU event tap.
///
/// Command itself is sent to QEMU through QMP as guest Meta. The rest of a
/// Command chord is reposted directly to QEMU with only the Command flag
/// removed. That avoids both macOS shortcuts and QEMU Cocoa's deliberate
/// refusal to forward ungrabbed Command chords. Physical Option is untouched.
struct FocusedCommandCaptureState {
    static let recursionMarker: Int64 = 0x004F_4D41_5243_4859
    static let leftCommand: CGKeyCode = 55
    static let rightCommand: CGKeyCode = 54

    private var commandKeys = Set<CGKeyCode>()
    private var forwardedKeys = Set<CGKeyCode>()
    private var forwardedModifiers = Set<CGKeyCode>()

    var isCapturing: Bool {
        !commandKeys.isEmpty || !forwardedKeys.isEmpty || !forwardedModifiers.isEmpty
    }

    mutating func process(_ event: CommandBridgeEvent, focused: Bool) -> CommandBridgeOutcome {
        guard event.marker != Self.recursionMarker else { return CommandBridgeOutcome() }
        guard focused else {
            var outcome = releaseAll()
            outcome.suppress = false
            return outcome
        }

        if let meta = Self.metaKey(for: event.keyCode) {
            return processCommand(event, meta: meta)
        }

        let commandFlagPresent = event.flags.contains(.maskCommand)
        let belongsToForwardedChord = forwardedKeys.contains(event.keyCode)
            || forwardedModifiers.contains(event.keyCode)
        guard !commandKeys.isEmpty || commandFlagPresent || belongsToForwardedChord else {
            return CommandBridgeOutcome()
        }

        var outcome = CommandBridgeOutcome(suppress: true)
        if commandKeys.isEmpty && commandFlagPresent {
            // The bridge may be enabled or regain focus while Command is
            // already held. Recover a balanced left-Meta pair.
            commandKeys.insert(Self.leftCommand)
            outcome.guestMeta.append(.init(key: .left, down: true))
        }

        switch event.kind {
        case .keyDown:
            forwardedKeys.insert(event.keyCode)
        case .keyUp:
            forwardedKeys.remove(event.keyCode)
        case .flagsChanged:
            if forwardedModifiers.contains(event.keyCode) {
                forwardedModifiers.remove(event.keyCode)
            } else {
                forwardedModifiers.insert(event.keyCode)
            }
        }
        outcome.forwarded.append(translated(event))
        return outcome
    }

    mutating func releaseAll() -> CommandBridgeOutcome {
        var outcome = CommandBridgeOutcome()
        let metaIsDown = !commandKeys.isEmpty
        var flags: CGEventFlags = metaIsDown ? [.maskCommand] : []

        for key in forwardedKeys.sorted() {
            outcome.forwarded.append(CommandBridgeEvent(
                kind: .keyUp,
                keyCode: key,
                flags: flags.subtracting(.maskCommand),
                marker: Self.recursionMarker
            ))
        }
        forwardedKeys.removeAll()

        for key in forwardedModifiers.sorted() {
            outcome.forwarded.append(CommandBridgeEvent(
                kind: .flagsChanged,
                keyCode: key,
                flags: flags.subtracting(.maskCommand),
                marker: Self.recursionMarker
            ))
        }
        forwardedModifiers.removeAll()

        for key in commandKeys.sorted() {
            commandKeys.remove(key)
            flags = commandKeys.isEmpty ? [] : [.maskCommand]
            if let meta = Self.metaKey(for: key) {
                outcome.guestMeta.append(.init(key: meta, down: false))
            }
        }
        return outcome
    }

    mutating func discardAll() {
        commandKeys.removeAll()
        forwardedKeys.removeAll()
        forwardedModifiers.removeAll()
    }

    private mutating func processCommand(
        _ event: CommandBridgeEvent,
        meta: GuestMetaKey
    ) -> CommandBridgeOutcome {
        var outcome = CommandBridgeOutcome(suppress: true)
        let down: Bool
        switch event.kind {
        case .keyDown:
            down = true
        case .keyUp:
            down = false
        case .flagsChanged:
            if commandKeys.contains(event.keyCode) {
                down = false
            } else if event.flags.contains(.maskCommand) {
                down = true
            } else {
                // We recovered a different side after focus changed. Release
                // every synthetic Meta rather than inventing a new key-down.
                let released = releaseAll()
                outcome.forwarded.append(contentsOf: released.forwarded)
                outcome.guestMeta.append(contentsOf: released.guestMeta)
                return outcome
            }
        }

        if down {
            if commandKeys.insert(event.keyCode).inserted {
                outcome.guestMeta.append(.init(key: meta, down: true))
            }
        } else if commandKeys.remove(event.keyCode) != nil {
            outcome.guestMeta.append(.init(key: meta, down: false))
        }
        return outcome
    }

    private func translated(_ event: CommandBridgeEvent) -> CommandBridgeEvent {
        CommandBridgeEvent(
            kind: event.kind,
            keyCode: event.keyCode,
            flags: event.flags.subtracting(.maskCommand),
            marker: Self.recursionMarker
        )
    }

    private static func metaKey(for keyCode: CGKeyCode) -> GuestMetaKey? {
        switch keyCode {
        case leftCommand: .left
        case rightCommand: .right
        default: nil
        }
    }
}

private extension CGEventFlags {
    func subtracting(_ other: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: rawValue & ~other.rawValue)
    }
}

final class QMPMetaKeyClient: @unchecked Sendable {
    private let connection: QMPConnection

    init(socketPath: String) throws {
        connection = try QMPConnection(
            socketPath: socketPath,
            identifierPrefix: "omarchy-meta"
        )
    }

    func send(_ transition: GuestMetaTransition) throws {
        // Complete the local socket write before the following chord key is
        // reposted. Otherwise a very fast Command-key chord could reach QEMU
        // before its guest Meta-down command.
        try connection.send(
            "input-send-event",
            arguments: [
                "events": [[
                    "type": "key",
                    "data": [
                        "down": transition.down,
                        "key": ["type": "qcode", "data": transition.key.rawValue],
                    ],
                ]],
            ]
        )
    }

    func close() {
        connection.close()
    }

    static func writeJSON(_ object: [String: Any], to descriptor: Int32) throws {
        try QMPConnection.writeJSON(object, to: descriptor)
    }
}

/// Kernel-backed identity for a process that may not have registered with
/// AppKit yet. The start timestamp closes the PID-reuse hole that a repeated
/// `kill(pid, 0)` or path-only check would leave open.
struct KernelProcessIdentity: Equatable {
    let processIdentifier: pid_t
    let executablePath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    var isQEMUSystemProcess: Bool {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        if name == "Try Omarchy" {
            return true
        }
        guard name.hasPrefix("qemu-system-") else { return false }
        let architecture = name.dropFirst("qemu-system-".count)
        return !architecture.isEmpty
            && architecture.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_+-".contains($0)) }
    }

    var isStillRunning: Bool {
        Self.capture(processIdentifier: processIdentifier) == self
    }

    static func capture(processIdentifier: pid_t) -> KernelProcessIdentity? {
        guard processIdentifier > 1 else { return nil }

        // PROC_PIDPATHINFO_MAXSIZE is defined as 4 * MAXPATHLEN, but the
        // structure-valued C macro is not imported into Swift.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(
            processIdentifier,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard pathLength > 0 else { return nil }

        var information = proc_bsdinfo()
        let informationSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytes = withUnsafeMutablePointer(to: &information) {
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                $0,
                informationSize
            )
        }
        guard bytes == informationSize else { return nil }

        return KernelProcessIdentity(
            processIdentifier: processIdentifier,
            executablePath: String(cString: pathBuffer),
            startSeconds: information.pbi_start_tvsec,
            startMicroseconds: information.pbi_start_tvusec
        )
    }
}

final class FocusedCommandSuperBridge {
    typealias FocusProbe = () -> Bool
    typealias ProcessAlive = () -> Bool
    typealias EventPost = (CGEvent, pid_t) -> Void

    private let targetPID: pid_t
    private let metaClient: QMPMetaKeyClient
    private let focusProbe: FocusProbe
    private let processAlive: ProcessAlive
    private let postEvent: EventPost
    private var state = FocusedCommandCaptureState()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var focusTimer: Timer?
    private var stopped = false
    private var terminalFailure: Error?

    init(
        targetPID: pid_t,
        qmpSocketPath: String,
        focusProbe: FocusProbe? = nil,
        processAlive: ProcessAlive? = nil,
        postEvent: @escaping EventPost = { event, processIdentifier in
            event.postToPid(processIdentifier)
        }
    ) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("input bridge target must be a running qemu-system process")
        }
        self.targetPID = targetPID
        metaClient = try QMPMetaKeyClient(socketPath: qmpSocketPath)
        self.focusProbe = focusProbe ?? {
            Self.isTargetFocused(processIdentifier: targetPID)
        }
        self.processAlive = processAlive ?? { processIdentity.isStillRunning }
        self.postEvent = postEvent
    }

    deinit {
        stop()
    }

    func run() throws {
        let eventMask = (UInt64(1) << CGEventType.keyDown.rawValue)
            | (UInt64(1) << CGEventType.keyUp.rawValue)
            | (UInt64(1) << CGEventType.flagsChanged.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let bridge = Unmanaged<FocusedCommandSuperBridge>
                    .fromOpaque(userInfo).takeUnretainedValue()
                return bridge.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HelperError.io("cannot create focused keyboard event tap; Accessibility permission is required")
        }
        tap = eventTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollTarget()
        }
        RunLoop.current.run()
        stop()
        if let terminalFailure { throw terminalFailure }
    }

    func stop() {
        finish(releasingGuestState: true)
    }

    private func finish(releasingGuestState: Bool, failure: Error? = nil) {
        guard !stopped else {
            if terminalFailure == nil { terminalFailure = failure }
            return
        }
        if terminalFailure == nil { terminalFailure = failure }
        if releasingGuestState {
            do {
                try apply(state.releaseAll())
            } catch {
                if terminalFailure == nil { terminalFailure = error }
            }
        } else {
            // Injection is already unusable. Retrying release through the same
            // dead QMP connection would recursively fail; the launcher will
            // terminate QEMU after this helper exits nonzero.
            state.discardAll()
        }
        stopped = true
        focusTimer?.invalidate()
        focusTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        tap = nil
        metaClient.close()
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            do {
                // A disabled tap may have missed physical key-up events. Clear
                // guest state before accepting any new host input.
                try apply(state.releaseAll())
            } catch {
                finish(releasingGuestState: false, failure: error)
                return nil
            }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let kind = CommandBridgeEventKind(type) else {
            return Unmanaged.passUnretained(event)
        }
        let input = CommandBridgeEvent(
            kind: kind,
            keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            marker: event.getIntegerValueField(.eventSourceUserData)
        )
        let outcome = state.process(input, focused: focusProbe())
        do {
            try apply(outcome, sourceEvent: event)
        } catch {
            finish(releasingGuestState: false, failure: error)
            return nil
        }
        return outcome.suppress ? nil : Unmanaged.passUnretained(event)
    }

    private func pollTarget() {
        guard processAlive() else {
            stop()
            return
        }
        if !focusProbe(), state.isCapturing {
            do {
                try apply(state.releaseAll())
            } catch {
                finish(releasingGuestState: false, failure: error)
            }
        }
    }

    private func apply(_ outcome: CommandBridgeOutcome, sourceEvent: CGEvent? = nil) throws {
        for transition in outcome.guestMeta { try metaClient.send(transition) }
        for forwarded in outcome.forwarded {
            let event: CGEvent?
            if let sourceEvent,
               forwarded.kind == CommandBridgeEventKind(sourceEvent.type),
               forwarded.keyCode == CGKeyCode(sourceEvent.getIntegerValueField(.keyboardEventKeycode)) {
                event = sourceEvent.copy()
            } else {
                event = CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: forwarded.keyCode,
                    keyDown: forwarded.kind != .keyUp
                )
                event?.type = forwarded.kind.cgEventType
            }
            guard let event else { continue }
            event.flags = forwarded.flags
            event.setIntegerValueField(.eventSourceUserData, value: forwarded.marker)
            postEvent(event, targetPID)
        }
    }

    private static func isTargetFocused(processIdentifier: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              application.isActive,
              !application.isTerminated else { return false }

        let accessibilityApplication = AXUIElementCreateApplication(processIdentifier)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            accessibilityApplication,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        return result == .success && focusedWindow != nil
    }
}
