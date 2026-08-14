import AppKit
import ApplicationServices
import Foundation
import Combine

@MainActor
final class AccessibilityPermissionManager: ObservableObject {
    @Published private(set) var isTrusted = false

    init() {
        refreshStatus()
    }

    func resetAccessibilityPermission() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.tk.toolkit"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleIdentifier]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Failed to reset Accessibility permission for %@: %@", bundleIdentifier, error.localizedDescription)
        }
    }

    @discardableResult
    func refreshStatus() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let newValue = AXIsProcessTrustedWithOptions(options)
        guard newValue != isTrusted else { return false }
        isTrusted = newValue
        return true
    }

    func requestAccessIfNeeded() {
        guard !isTrusted else { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshStatus()
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
