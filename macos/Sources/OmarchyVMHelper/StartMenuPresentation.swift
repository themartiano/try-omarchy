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

    static func immersiveDetail(isEnabled: Bool) -> String {
        isEnabled
            ? "Mac controls stay hidden. First press Control-Option-G, then Command-F to leave Full Screen."
            : "Move the pointer to the top of the screen, then choose View › Exit Full Screen or press Command-F."
    }
}
