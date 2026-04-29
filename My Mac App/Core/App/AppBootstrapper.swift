import Foundation
import Combine

@MainActor
final class AppBootstrapper: ObservableObject {
    @Published private(set) var availableFeatures: [FeatureDescriptor] = [
        FeatureDescriptor(
            id: "dock-window-hover",
            title: "Dock Hover Window Titles",
            summary: "Shows a popup with open window titles when hovering app icons in the Dock.",
            requiresAccessibilityAccess: true
        )
    ]

    let accessibilityPermissionManager = AccessibilityPermissionManager()

    private var featureRegistry: FeatureRegistry?
    private var permissionRefreshTimer: Timer?

    init() {
        accessibilityPermissionManager.refreshStatus()
        accessibilityPermissionManager.requestAccessIfNeeded()
        updateFeatureLifecycle()
        startPermissionWatchdog()
    }

    func requestAccessibilityAccess() {
        accessibilityPermissionManager.requestAccessIfNeeded()
        updateFeatureLifecycle()
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
            if featureRegistry == nil {
                let features: [AppFeature] = [
                    DockWindowHoverFeature()
                ]

                featureRegistry = FeatureRegistry(features: features)
                featureRegistry?.startAll()
            }
        } else {
            featureRegistry?.stopAll()
            featureRegistry = nil
        }
    }
}
