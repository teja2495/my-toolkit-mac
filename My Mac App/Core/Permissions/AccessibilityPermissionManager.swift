import AppKit
import ApplicationServices
import Foundation
import Combine

@MainActor
final class AccessibilityPermissionManager: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()

    func refreshStatus() {
        isTrusted = AXIsProcessTrusted()
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
