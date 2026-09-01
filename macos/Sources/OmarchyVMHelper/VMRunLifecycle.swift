import Darwin
import Foundation

struct VMRunLifecycle: Equatable {
    private enum StopIntent: Equatable {
        case none
        case quit
        case signal(Int32)
    }

    private var stopIntent: StopIntent = .none

    var isStopping: Bool {
        stopIntent != .none
    }

    mutating func requestQuit() {
        stopIntent = .quit
    }

    mutating func requestTermination(signal: Int32) {
        stopIntent = .signal(signal)
    }

    mutating func childExited() {
        stopIntent = .none
    }
}

struct VMExitPresentationDecision: Equatable {
    let showsStartupFailure: Bool
    let requiresWorkspaceReset: Bool
    let requiresBootRecoveryConsent: Bool
    let reportsBootRecoveryFailure: Bool

    static let incompatibleWorkspaceStatus: Int32 = 78
    static let bootRecoveryConsentRequiredStatus: Int32 = 80
    static let bootRecoveryFailedStatus: Int32 = 81

    static func make(status: Int32, reachedVirtualMachineStart: Bool, wasStopping: Bool) -> Self {
        let requiresWorkspaceReset = status == incompatibleWorkspaceStatus
            && !reachedVirtualMachineStart
            && !wasStopping
        let requiresBootRecoveryConsent = status == bootRecoveryConsentRequiredStatus
            && !reachedVirtualMachineStart
            && !wasStopping
        let reportsBootRecoveryFailure = status == bootRecoveryFailedStatus
            && !reachedVirtualMachineStart
            && !wasStopping
        return Self(
            showsStartupFailure: status != 0
                && !reachedVirtualMachineStart
                && !wasStopping
                && !requiresWorkspaceReset
                && !requiresBootRecoveryConsent
                && !reportsBootRecoveryFailure,
            requiresWorkspaceReset: requiresWorkspaceReset,
            requiresBootRecoveryConsent: requiresBootRecoveryConsent,
            reportsBootRecoveryFailure: reportsBootRecoveryFailure
        )
    }
}
