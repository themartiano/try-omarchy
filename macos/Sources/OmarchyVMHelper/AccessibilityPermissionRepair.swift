import Foundation

enum AccessibilityPermissionRepair {
    static let bundleIdentifier = "dev.tryomarchy.native"

    /// Remove only this app's Accessibility decision before asking macOS to
    /// register the currently installed code. This repairs TCC records left
    /// behind when an older or ad-hoc-signed app was replaced.
    static func resetStaleEntry(
        tccutilURL: URL = URL(fileURLWithPath: "/usr/bin/tccutil")
    ) -> Bool {
        let process = Process()
        process.executableURL = tccutilURL
        process.arguments = ["reset", "Accessibility", bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
