/// Whether the current persistent VM needs the one-time boot-file pairing
/// before it can launch with its own saved kernel and initramfs.
enum BootRecoveryLaunchPreflight: Equatable {
    case notRequired
    case requiresConfirmation
}

enum BootRecoveryLaunchGateDecision: Equatable {
    case cancel
    case launch(allowBootRecovery: Bool)
}

enum BootRecoveryChildExitDecision: Equatable {
    case unrelated
    case requestConfirmation
    case reportFailure
}

/// Keeps the consent decision pure and testable. The confirmation closure is
/// deliberately not evaluated for ordinary launches, so a paired VM never
/// sees the one-time prompt again.
enum BootRecoveryLaunchGate {
    static func decide(
        preflight: BootRecoveryLaunchPreflight,
        confirm: () -> Bool
    ) -> BootRecoveryLaunchGateDecision {
        switch preflight {
        case .notRequired:
            .launch(allowBootRecovery: false)
        case .requiresConfirmation:
            confirm() ? .launch(allowBootRecovery: true) : .cancel
        }
    }
}

/// Resolves the second half of the fail-closed shell handshake. A second
/// consent request after an authorized retry is always a failure, never a new
/// prompt, which bounds recovery to one attempt per user decision.
enum BootRecoveryChildExitGate {
    static func decide(
        presentation: VMExitPresentationDecision,
        launchWasAuthorized: Bool
    ) -> BootRecoveryChildExitDecision {
        if presentation.reportsBootRecoveryFailure {
            return .reportFailure
        }
        if presentation.requiresBootRecoveryConsent {
            return launchWasAuthorized ? .reportFailure : .requestConfirmation
        }
        return .unrelated
    }
}
