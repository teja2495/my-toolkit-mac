import Combine
import Foundation

@MainActor
final class AppBootstrapper: ObservableObject {
    @Published var dockHoverPopupDelay: Double {
        didSet {
            UserDefaults.standard.set(dockHoverPopupDelay, forKey: Self.dockHoverPopupDelayKey)
            (liveFeatures["dock-window-hover"] as? DockWindowHoverFeature)?.popupDelay = max(0, dockHoverPopupDelay)
        }
    }

    @Published private(set) var availableFeatures: [FeatureDescriptor] = [
        FeatureDescriptor(
            id: "corner-notes",
            title: "Bottom-Right Quick Notes",
            summary: "Opens a two-pane todo checklist and note window from the bottom-right corner.",
            requiresAccessibilityAccess: false,
            isEnabled: true
        ),
        FeatureDescriptor(
            id: "dock-window-hover",
            title: "Dock App Windows Popup",
            summary: "Shows a popup with open window titles when hovering app icons in the Dock.",
            requiresAccessibilityAccess: true,
            isEnabled: true
        )
    ]

    let accessibilityPermissionManager = AccessibilityPermissionManager()

    private static let dockHoverPopupDelayKey = "dockHoverPopupDelay"
    private static let defaultDockHoverPopupDelay = 0.25

    private var liveFeatures: [String: AppFeature] = [:]
    private var permissionRefreshTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let savedDelay = UserDefaults.standard.object(forKey: Self.dockHoverPopupDelayKey) as? Double
        dockHoverPopupDelay = savedDelay ?? Self.defaultDockHoverPopupDelay
        accessibilityPermissionManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        accessibilityPermissionManager.refreshStatus()
        updateFeatureLifecycle()
        startPermissionWatchdog()
    }

    func requestAccessibilityAccess() {
        accessibilityPermissionManager.resetAccessibilityPermission()
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
        ensureFeatureExists(CornerNotesFeature())

        if accessibilityPermissionManager.isTrusted {
            let feature = DockWindowHoverFeature()
            feature.popupDelay = max(0, dockHoverPopupDelay)
            ensureFeatureExists(feature)
        } else if let feature = liveFeatures.removeValue(forKey: "dock-window-hover") {
            feature.stop()
        }

        for descriptor in availableFeatures {
            guard let feature = liveFeatures[descriptor.id] else { continue }
            if descriptor.isEnabled {
                feature.start()
            } else {
                feature.stop()
            }
        }
    }

    private func ensureFeatureExists(_ feature: AppFeature) {
        guard liveFeatures[feature.id] == nil else {
            if let dockFeature = liveFeatures[feature.id] as? DockWindowHoverFeature {
                dockFeature.popupDelay = max(0, dockHoverPopupDelay)
            }
            return
        }

        liveFeatures[feature.id] = feature
    }
}
