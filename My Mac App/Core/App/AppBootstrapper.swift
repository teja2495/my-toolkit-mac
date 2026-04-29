import Foundation
import Combine

@MainActor
final class AppBootstrapper: ObservableObject {
    @Published private(set) var availableFeatures: [FeatureDescriptor] = [
        FeatureDescriptor(
            id: "dock-window-hover",
            title: "Dock Hover Window Titles",
            summary: "Shows a popup with open window titles when hovering app icons in the Dock.",
            requiresAccessibilityAccess: true,
            isEnabled: true
        )
    ]

    let accessibilityPermissionManager = AccessibilityPermissionManager()

    private var liveFeatures: [String: AppFeature] = [:]
    private var permissionRefreshTimer: Timer?

    init() {
        accessibilityPermissionManager.resetAccessibilityPermission()
        accessibilityPermissionManager.refreshStatus()
        accessibilityPermissionManager.requestAccessIfNeeded()
        updateFeatureLifecycle()
        startPermissionWatchdog()
    }

    func requestAccessibilityAccess() {
        accessibilityPermissionManager.requestAccessIfNeeded()
        updateFeatureLifecycle()
    }

    func toggleFeature(id: String) {
        guard let index = availableFeatures.firstIndex(where: { $0.id == id }) else { return }
        availableFeatures[index].isEnabled.toggle()
        let isEnabled = availableFeatures[index].isEnabled
        if isEnabled {
            liveFeatures[id]?.start()
        } else {
            liveFeatures[id]?.stop()
        }
    }

    private func startPermissionWatchdog() {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.accessibilityPermissionManager.refreshStatus()
                self.updateFeatureLifecycle()
            }
        }

        if let permissionRefreshTimer {
            RunLoop.main.add(permissionRefreshTimer, forMode: .common)
        }
    }

    private func updateFeatureLifecycle() {
        if accessibilityPermissionManager.isTrusted {
            if liveFeatures.isEmpty {
                let feature = DockWindowHoverFeature()
                liveFeatures[feature.id] = feature
                if availableFeatures.first(where: { $0.id == feature.id })?.isEnabled == true {
                    feature.start()
                }
            }
        } else {
            liveFeatures.values.forEach { $0.stop() }
            liveFeatures = [:]
        }
    }
}
