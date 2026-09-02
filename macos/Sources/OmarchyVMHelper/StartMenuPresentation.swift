import Foundation

enum StartMenuPermissionAction: Equatable {
    case request
    case openSettings
}

struct StartMenuPermissionPresentation: Equatable {
    let detail: String
    let isGranted: Bool
    let actionTitle: String?
    let action: StartMenuPermissionAction?
}

struct StartMenuSharedFolderPresentation: Equatable {
    let detail: String
    let compactDetailLines: [String]?
    let isGranted: Bool
    let toggleActionTitle: String?
}

struct StartMenuMemoryPresentation: Equatable {
    let detail: String
    /// The MiB value behind each popup entry, in display order.
    let choicesMiB: [Int]
    let choiceTitles: [String]
    let selectedIndex: Int
    /// False when this Mac's RAM fits only the default, so the popup renders
    /// disabled rather than offering a single-item "choice".
    let isAdjustable: Bool
}

struct StartMenuPortForwardingPresentation: Equatable {
    let detail: String
    let compactDetailLines: [String]?
    let isGranted: Bool
    let grantedStatusLabel: String
}

/// Pure presentation rules for the start menu. Keeping user-visible state out
/// of AppKit makes the important behavior testable without relying on window
/// positions, font metrics, run-loop timing, or the current display size.
enum StartMenuPresentation {
    static func microphone(
        state: MicrophoneAuthorizationState,
        requestInFlight: Bool
    ) -> StartMenuPermissionPresentation {
        switch state {
        case .authorized:
            StartMenuPermissionPresentation(
                detail: "Apps in Omarchy can record from your Mac microphone.",
                isGranted: true,
                actionTitle: nil,
                action: nil
            )
        case .notDetermined:
            StartMenuPermissionPresentation(
                detail: "Optional. Speaker playback works without microphone access.",
                isGranted: false,
                actionTitle: requestInFlight ? "Waiting…" : "Allow…",
                action: .request
            )
        case .denied:
            StartMenuPermissionPresentation(
                detail: "Recording is off. Speaker playback will still work.",
                isGranted: false,
                actionTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            StartMenuPermissionPresentation(
                detail: "Recording is unavailable because of this Mac’s policy.",
                isGranted: false,
                actionTitle: nil,
                action: nil
            )
        }
    }

    static func camera(
        state: CameraAuthorizationState,
        requestInFlight: Bool
    ) -> StartMenuPermissionPresentation {
        switch state {
        case .authorized:
            StartMenuPermissionPresentation(
                detail: "Apps in Omarchy can use your Mac camera while they are recording.",
                isGranted: true,
                actionTitle: nil,
                action: nil
            )
        case .notDetermined:
            StartMenuPermissionPresentation(
                detail: "Optional. The camera turns on only while an Omarchy app uses it.",
                isGranted: false,
                actionTitle: requestInFlight ? "Waiting…" : "Allow…",
                action: .request
            )
        case .denied:
            StartMenuPermissionPresentation(
                detail: "The Mac camera is off inside Omarchy.",
                isGranted: false,
                actionTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            StartMenuPermissionPresentation(
                detail: "Camera access is unavailable because of this Mac’s policy.",
                isGranted: false,
                actionTitle: nil,
                action: nil
            )
        }
    }

    static func sharedFolder(
        state: SharedFolderMenuState
    ) -> StartMenuSharedFolderPresentation {
        let detail: String
        let compactDetailLines: [String]?
        if let problem = state.problem {
            detail = problem
            compactDetailLines = nil
        } else if let displayPath = state.displayPath, state.isEnabled {
            let guestPath = "~/\(SharedFolderPolicy.guestLinkName(state.path ?? displayPath))"
            detail = "Mac folder: \(displayPath). In Omarchy: \(guestPath)."
            compactDetailLines = [
                "Mac folder: \(displayPath)",
                "In Omarchy: \(guestPath)",
            ]
        } else if let displayPath = state.displayPath {
            detail = "Mac folder: \(displayPath). In Omarchy: Off."
            compactDetailLines = [
                "Mac folder: \(displayPath)",
                "In Omarchy: Off",
            ]
        } else {
            detail = "Optional. Pick a Mac folder to use inside Omarchy under the same name."
            compactDetailLines = nil
        }

        return StartMenuSharedFolderPresentation(
            detail: detail,
            compactDetailLines: compactDetailLines,
            isGranted: state.isEnabled && state.problem == nil,
            toggleActionTitle: state.path == nil ? nil : (state.isEnabled ? "Turn Off" : "Turn On")
        )
    }

    static func portForwarding(
        mappings: [PortForwardMapping]
    ) -> StartMenuPortForwardingPresentation {
        if mappings.isEmpty {
            return StartMenuPortForwardingPresentation(
                detail: "Optional. Reach services running in Omarchy at localhost on this Mac.",
                compactDetailLines: nil,
                isGranted: false,
                grantedStatusLabel: "●  0 Ports"
            )
        }
        if mappings.count == 1, let mapping = mappings.first {
            return StartMenuPortForwardingPresentation(
                detail: "localhost:\(mapping.hostPort) → "
                    + "Omarchy:\(mapping.guestPort) · \(mapping.protocol.displayName)",
                compactDetailLines: [
                    "Mac: localhost:\(mapping.hostPort)",
                    "Omarchy: port \(mapping.guestPort) · \(mapping.protocol.displayName)",
                ],
                isGranted: true,
                grantedStatusLabel: "●  1 Port"
            )
        }
        return StartMenuPortForwardingPresentation(
            detail: "\(mappings.count) localhost mappings. Available only on this Mac.",
            compactDetailLines: [
                "\(mappings.count) localhost mappings",
                "Available only on this Mac",
            ],
            isGranted: true,
            grantedStatusLabel: "●  \(mappings.count) Ports"
        )
    }

    static func memory(
        preferredMiB: Int,
        hostMemoryMiB: Int
    ) -> StartMenuMemoryPresentation {
        let choices = MemoryPolicy.allowedChoicesMiB(hostMemoryMiB: hostMemoryMiB)
        let selected = MemoryPolicy.resolvedMemoryMiB(
            preferredMiB: preferredMiB,
            hostMemoryMiB: hostMemoryMiB
        )
        let titles = choices.map { choice in
            choice == MemoryPolicy.defaultMemoryMiB
                ? "\(MemoryPolicy.displayLabel(memoryMiB: choice)) · default"
                : MemoryPolicy.displayLabel(memoryMiB: choice)
        }
        let isAdjustable = choices.count > 1
        return StartMenuMemoryPresentation(
            detail: isAdjustable
                ? "Give Omarchy more of this Mac’s memory. Applies on the next launch."
                : "This Mac’s memory fits the \(MemoryPolicy.displayLabel(memoryMiB: MemoryPolicy.defaultMemoryMiB)) default.",
            choicesMiB: choices,
            choiceTitles: titles,
            selectedIndex: choices.firstIndex(of: selected) ?? 0,
            isAdjustable: isAdjustable
        )
    }

    static func immersiveDetail(isEnabled: Bool) -> String {
        isEnabled
            ? "Mac menu bar and Dock stay hidden while Omarchy is Full Screen."
            : "Mac menu bar and Dock remain available at the screen edges while Omarchy is Full Screen."
    }
}
