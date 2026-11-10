import AppKit
import CoreGraphics
import Combine
import Foundation

/// Screen Recording (ScreenCapture TCC) access, mirroring `AccessibilityPermissionManager`.
@MainActor
final class ScreenRecordingPermissionManager: ObservableObject {
    @Published private(set) var isGranted = false

    init() {
        refreshStatus()
    }

    /// macOS may cache this per process; after granting, choose "Quit & Reopen" when offered.
    @discardableResult
    func refreshStatus() -> Bool {
        let newValue = CGPreflightScreenCaptureAccess()
        guard newValue != isGranted else { return false }
        isGranted = newValue
        return true
    }

    /// Drops any stale entry left by an older build, then shows the system prompt.
    /// Falls back to System Settings when macOS doesn't show a prompt.
    func requestAccess() {
        refreshStatus()
        guard !isGranted else { return }
        resetScreenRecordingPermission()
        if !CGRequestScreenCaptureAccess() {
            openSystemSettings()
        }
        refreshStatus()
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func resetScreenRecordingPermission() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.tk.toolkit.mac"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleIdentifier]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Failed to reset Screen Recording permission for %@: %@", bundleIdentifier, error.localizedDescription)
        }
    }
}
