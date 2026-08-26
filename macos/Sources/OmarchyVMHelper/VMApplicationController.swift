import AppKit
import ApplicationServices
import Darwin
import Foundation

@MainActor
final class VMApplicationController: NSObject, NSApplicationDelegate {
    private let launcherURL: URL
    private let initialArguments: [String]
    private let baseEnvironment: [String: String]
    private let supervisor: QEMUGPUProcessSupervisor
    private let preferenceStore: AudioRoutingPreferenceStore
    private let sharedFolderStore: SharedFolderPreferenceStore
    private let deviceProvider: HostAudioDeviceProviding
    private var startMenuWindow: StartMenuWindow?

    private var lifecycle = VMRunLifecycle()
    private var childRunning = false
    private var applicationTerminationPending = false
    private var virtualMachineReachedStart = false

    private(set) var exitStatus: Int32 = 0

    init(
        launcherURL: URL,
        initialArguments: [String],
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        supervisor: QEMUGPUProcessSupervisor = QEMUGPUProcessSupervisor(),
        preferenceStore: AudioRoutingPreferenceStore = AudioRoutingPreferenceStore(),
        sharedFolderStore: SharedFolderPreferenceStore = SharedFolderPreferenceStore(),
        deviceProvider: HostAudioDeviceProviding = CoreAudioHostAudioDeviceProvider()
    ) {
        self.launcherURL = launcherURL
        self.initialArguments = initialArguments
        self.baseEnvironment = baseEnvironment
        self.supervisor = supervisor
        self.preferenceStore = preferenceStore
        self.sharedFolderStore = sharedFolderStore
        self.deviceProvider = deviceProvider
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showStartMenu()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        startMenuWindow?.refreshPermissionStatus()
    }

    private func showStartMenu() {
        let resetOptions = [
            QEMUGPUStorageOption.resetStorage.rawValue,
            QEMUGPUStorageOption.resetStorageOnly.rawValue,
        ]
        let initialResetRequested = initialArguments.first.map(resetOptions.contains) ?? false
        let canResetStorage = initialArguments.first != QEMUGPUStorageOption.ephemeral.rawValue
        let startMenu = StartMenuWindow(
            accessibilityStatus: { AXIsProcessTrusted() },
            microphoneStatus: { MicrophonePreflight.authorizationState() },
            requestAccessibility: { [weak self] in
                self?.requestOptionalAccessibilityPermission()
            },
            requestMicrophone: { completion in
                MicrophonePreflight.requestAccess(completion: completion)
            },
            canResetStorage: canResetStorage,
            storageLocation: canResetStorage
                ? QEMUGPUStorageSpaceEstimate.dataDirectoryDisplayPath(
                    environment: baseEnvironment
                )
                : nil,
            storageLocationURL: canResetStorage
                ? QEMUGPUStorageSpaceEstimate.dataDirectoryURL(
                    environment: baseEnvironment
                )
                : nil,
            storageSpaceEstimate: { [baseEnvironment] in
                QEMUGPUStorageSpaceEstimate.formattedReclaimableSpace(
                    environment: baseEnvironment,
                    bundleIdentity: QEMUGPUStorageSpaceEstimate.bundledIdentity()
                )
            },
            resetStorage: { [weak self] in
                self?.resetVirtualMachine()
            },
            sharedFolderStatus: { [weak self] in
                self?.sharedFolderMenuState() ?? SharedFolderMenuState.disabled
            },
            chooseSharedFolder: { [weak self] path in
                self?.chooseSharedFolder(path)
            },
            setSharedFolderEnabled: { [weak self] enabled in
                self?.setSharedFolderEnabled(enabled)
            },
            launch: { [weak self] in
                self?.startVirtualMachine()
            }
        )
        startMenuWindow = startMenu
        startMenu.show()
        if initialResetRequested {
            startMenu.promptForReset()
        }
    }

    private func startVirtualMachine() {
        virtualMachineReachedStart = false
        do {
            let accessibilityDecision = AccessibilityLaunchDecision.make(
                for: AXIsProcessTrusted() ? .authorized : .unavailable
            )
            if let warning = accessibilityDecision.warning {
                fputs("[input-bridge] \(warning)\n", stderr)
            }
            guard accessibilityDecision.allowsLaunch else {
                throw HelperError.io("accessibility policy unexpectedly prevented launch")
            }
            let microphoneDecision = MicrophonePreflight.decision()
            if let warning = microphoneDecision.warning {
                fputs("[audio] \(warning)\n", stderr)
            }
            guard microphoneDecision.allowsLaunch else {
                throw HelperError.io("microphone policy unexpectedly prevented audio playback")
            }
            try launch(arguments: launchArguments())
        } catch {
            failLaunch(error)
        }
    }

    private func launchArguments() -> [String] {
        var arguments = initialArguments
        let resetOptions = [
            QEMUGPUStorageOption.resetStorage.rawValue,
            QEMUGPUStorageOption.resetStorageOnly.rawValue,
        ]
        if let first = arguments.first, resetOptions.contains(first) {
            arguments.removeFirst()
        }
        return arguments
    }

    private func resetArguments() -> [String] {
        var arguments = launchArguments()
        arguments.insert(QEMUGPUStorageOption.resetStorageOnly.rawValue, at: 0)
        return arguments
    }

    private func resetVirtualMachine() {
        do {
            try supervisor.start(
                executableURL: launcherURL,
                arguments: resetArguments(),
                environment: baseEnvironment
            ) { [weak self] status in
                self?.resetDidExit(status: status)
            }
            childRunning = true
        } catch {
            startMenuWindow?.resetDidFinish(errorMessage: error.localizedDescription)
        }
    }

    private func resetDidExit(status: Int32) {
        guard childRunning else { return }
        childRunning = false
        let wasStopping = lifecycle.isStopping
        lifecycle.childExited()
        if applicationTerminationPending {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else if wasStopping {
            finish(status: status)
        } else if status == 0 {
            startMenuWindow?.resetDidFinish(errorMessage: nil)
        } else {
            startMenuWindow?.resetDidFinish(
                errorMessage: "The VM disk could not be reset. Try again, or reinstall the latest Try Omarchy app."
            )
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard childRunning else { return .terminateNow }
        guard !applicationTerminationPending else { return .terminateLater }

        applicationTerminationPending = true
        lifecycle.requestQuit()
        supervisor.forward(signal: SIGTERM)
        return .terminateLater
    }

    func handleTerminationSignal(_ signal: Int32) {
        guard !applicationTerminationPending else { return }
        lifecycle.requestTermination(signal: signal)
        if childRunning {
            supervisor.forward(signal: signal)
        } else {
            finish(status: 128 + signal)
        }
    }

    private func launch(arguments: [String]) throws {
        let preferences = preferenceStore.load()
        let catalog = deviceProvider.catalog()
        let configuration = AudioLaunchConfiguration.make(
            baseEnvironment: baseEnvironment,
            preferences: preferences,
            catalog: catalog
        )
        let sharing = SharedFolderLaunchConfiguration.make(
            baseEnvironment: configuration.environment,
            preference: sharedFolderStore.load(),
            homeDirectory: Self.homeDirectory
        )

        try supervisor.start(
            executableURL: launcherURL,
            arguments: arguments,
            environment: sharing.environment,
            launchEvent: { [weak self] event in
                if event == .virtualMachineReady {
                    self?.virtualMachineDidStart()
                }
            }
        ) { [weak self] status in
            self?.childDidExit(status: status)
        }
        childRunning = true
    }

    private func virtualMachineDidStart() {
        virtualMachineReachedStart = true
        startMenuWindow?.dismiss()
        startMenuWindow = nil
    }

    private static var homeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    private func sharedFolderMenuState() -> SharedFolderMenuState {
        SharedFolderMenuState.make(
            preference: sharedFolderStore.load(),
            homeDirectory: Self.homeDirectory
        )
    }

    /// Returns an error message when the folder is rejected; otherwise saves
    /// it as the enabled share.
    private func chooseSharedFolder(_ path: String) -> String? {
        do {
            let canonical = try SharedFolderPolicy.validate(path, homeDirectory: Self.homeDirectory)
            sharedFolderStore.save(SharedFolderPreference(path: canonical, isEnabled: true))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func setSharedFolderEnabled(_ enabled: Bool) {
        var preference = sharedFolderStore.load()
        guard preference.path != nil else { return }
        preference.isEnabled = enabled
        sharedFolderStore.save(preference)
    }

    private func requestOptionalAccessibilityPermission() {
        guard !AXIsProcessTrusted() else { return }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    private func childDidExit(status: Int32) {
        guard childRunning else { return }
        childRunning = false

        let wasStopping = lifecycle.isStopping
        let presentation = VMExitPresentationDecision.make(
            status: status,
            reachedVirtualMachineStart: virtualMachineReachedStart,
            wasStopping: wasStopping
        )
        lifecycle.childExited()
        if applicationTerminationPending {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            if presentation.requiresWorkspaceReset {
                startMenuWindow?.launchRequiresReset()
                return
            }
            if presentation.showsStartupFailure {
                startMenuWindow?.dismiss()
                startMenuWindow = nil
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Try Omarchy couldn’t start"
                alert.informativeText = "The app’s virtual machine stopped during startup. Reinstall the latest Omarchy app and try again."
                alert.addButton(withTitle: "Close")
                alert.runModal()
            }
            finish(status: status)
        }
    }

    private func failLaunch(_ error: Error) {
        fputs("omarchy-vm-helper: \(error.localizedDescription)\n", stderr)
        startMenuWindow?.dismiss()
        startMenuWindow = nil
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Try Omarchy couldn’t start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Close")
        alert.runModal()
        finish(status: 1)
    }

    private func finish(status: Int32) {
        exitStatus = status
        NSApp.stop(nil)

        // `stop` takes effect after the current event is handled. Posting a
        // private wake-up also covers completion handlers that arrive while
        // the application is otherwise idle.
        if let wakeUp = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            NSApp.postEvent(wakeUp, atStart: false)
        }
    }
}
