import AppKit
import Darwin
import Foundation

private var terminationSignalSources: [DispatchSourceSignal] = []

private func usage() -> Never {
    fputs("Usage: omarchy-vm-helper --run-qemu [--ephemeral | --reset-storage | --reset-storage-only] [GUEST_DIR] | --bridge-command-super QEMU_PID QMP_SOCKET | --bridge-native-audio QEMU_PID SOCKET ROUTE_DIRECTORY | --bridge-native-camera QEMU_PID SOCKET | --bridge-native-clipboard QEMU_PID SOCKET\n", stderr)
    exit(64)
}

private func effectiveArguments() -> [String] {
    let supplied = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
    if !supplied.isEmpty {
        return Array(supplied)
    }
    return Bundle.main.bundleURL.pathExtension == "app" ? ["--run-qemu"] : []
}

let arguments = effectiveArguments()
do {
    if arguments.first == "--bridge-native-audio" {
        guard arguments.count == 4,
              let processIdentifier = Int32(arguments[1]),
              processIdentifier > 1 else { usage() }
        let bridge = try NativeAudioBridge(
            targetPID: processIdentifier,
            socketPath: arguments[2],
            routeDirectoryPath: arguments[3]
        )
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            // `run()` blocks while reading the virtio channel, so signal
            // delivery must not depend on the main queue being serviced.
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler { bridge.stop() }
            source.resume()
            terminationSignalSources.append(source)
        }
        fputs("[audio-bridge] Host audio devices are available inside Omarchy.\n", stderr)
        try bridge.run()
        exit(0)
    }

    if arguments.first == "--bridge-native-clipboard" {
        guard arguments.count == 3,
              let processIdentifier = Int32(arguments[1]),
              processIdentifier > 1 else { usage() }
        let bridge = try NativeClipboardBridge(
            targetPID: processIdentifier,
            socketPath: arguments[2]
        )
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler { bridge.stop() }
            source.resume()
            terminationSignalSources.append(source)
        }
        fputs("[clipboard-bridge] The Mac clipboard is shared with Omarchy.\n", stderr)
        try bridge.run()
        exit(0)
    }

    if arguments.first == "--bridge-native-camera" {
        guard arguments.count == 3,
              let processIdentifier = Int32(arguments[1]),
              processIdentifier > 1 else { usage() }
        let bridge = try NativeCameraBridge(
            targetPID: processIdentifier,
            socketPath: arguments[2]
        )
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler { bridge.stop() }
            source.resume()
            terminationSignalSources.append(source)
        }
        fputs("[camera-bridge] The Mac camera is available to Omarchy on demand.\n", stderr)
        try bridge.run()
        exit(0)
    }

    if arguments.first == "--bridge-command-super" {
        guard arguments.count == 3,
              let processIdentifier = Int32(arguments[1]),
              processIdentifier > 1 else { usage() }
        guard AXIsProcessTrusted() else {
            throw HelperError.io(
                "Accessibility permission is required for focused Command-key capture; grant it in System Settings, then retry"
            )
        }
        let bridge = try FocusedCommandSuperBridge(
            targetPID: processIdentifier,
            qmpSocketPath: arguments[2]
        )
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { bridge.stop() }
            source.resume()
            terminationSignalSources.append(source)
        }
        fputs("[input-bridge] Command is captured as guest Super only while QEMU pid \(processIdentifier) is focused.\n", stderr)
        try bridge.run()
        exit(0)
    }

    if arguments.first == "--run-qemu" {
        guard let request = QEMUGPULaunchRequest(arguments: Array(arguments.dropFirst())) else {
            usage()
        }
        let launcher = try QEMUGPULauncherPath.resolve(bundleURL: Bundle.main.bundleURL)
        let launcherArguments = try request.validatedScriptArguments()

        // The executable's top level starts on the process main thread. Make
        // that invariant explicit so the AppKit lifecycle stays MainActor
        // isolated while `NSApplication.run()` services its event loop.
        let status = MainActor.assumeIsolated { () -> Int32 in
            let application = NSApplication.shared
            application.setActivationPolicy(ApplicationPresentation.prelaunchActivationPolicy)
            ApplicationPresentation.installMainMenu(
                in: application,
                applicationName: "Try Omarchy"
            )
            let controller = VMApplicationController(
                launcherURL: launcher,
                initialArguments: launcherArguments
            )
            application.delegate = controller
            for signalNumber in [SIGHUP, SIGINT, SIGTERM] {
                Darwin.signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(
                    signal: signalNumber,
                    queue: .main
                )
                source.setEventHandler {
                    MainActor.assumeIsolated {
                        controller.handleTerminationSignal(signalNumber)
                    }
                }
                source.resume()
                terminationSignalSources.append(source)
            }
            application.run()
            return controller.exitStatus
        }
        exit(status)
    }

    usage()
} catch {
    fputs("omarchy-vm-helper: \(error.localizedDescription)\n", stderr)
    exit(1)
}
