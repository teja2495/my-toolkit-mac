import AppKit
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
        ),
        FeatureDescriptor(
            id: "writing-fix",
            title: "Inline Grammar Fix",
            summary: "Type a trigger at the end of focused text to fix grammar and typos with Apple Intelligence.",
            requiresAccessibilityAccess: true,
            isEnabled: true
        )
    ]

    @Published var writingFixRules: [WritingFixRule] {
        didSet {
            let safeRules = Self.sanitizedRules(writingFixRules)
            if writingFixRules != safeRules {
                writingFixRules = safeRules
                return
            }

            if let encodedRules = try? JSONEncoder().encode(safeRules) {
                UserDefaults.standard.set(encodedRules, forKey: Self.writingFixRulesKey)
            }

            (liveFeatures["writing-fix"] as? WritingFixFeature)?.rules = safeRules
        }
    }

    let accessibilityPermissionManager = AccessibilityPermissionManager()

    private static let dockHoverPopupDelayKey = "dockHoverPopupDelay"
    private static let defaultDockHoverPopupDelay = 0.25
    private static let writingFixRulesKey = "writingFixRules"
    private static let writingFixTriggerKey = "writingFixTrigger"
    private static let defaultWritingFixTrigger = "fxx"
    private static let defaultWritingFixPrompt = GrammarTypoCorrector.defaultPromptTemplate

    private var liveFeatures: [String: AppFeature] = [:]
    private var permissionRefreshTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let savedDelay = UserDefaults.standard.object(forKey: Self.dockHoverPopupDelayKey) as? Double
        dockHoverPopupDelay = savedDelay ?? Self.defaultDockHoverPopupDelay
        writingFixRules = Self.loadWritingFixRules()
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
            guard let self else { return }
            Task { @MainActor in
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
            ensureFeatureExists(WritingFixFeature())
        } else {
            if let feature = liveFeatures.removeValue(forKey: "dock-window-hover") {
                feature.stop()
            }
            if let writingFixFeature = liveFeatures.removeValue(forKey: "writing-fix") {
                writingFixFeature.stop()
            }
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
            if let writingFixFeature = liveFeatures[feature.id] as? WritingFixFeature {
                writingFixFeature.rules = writingFixRules
            }
            return
        }

        if let writingFixFeature = feature as? WritingFixFeature {
            writingFixFeature.rules = writingFixRules
        }
        liveFeatures[feature.id] = feature
    }

    private static func loadWritingFixRules() -> [WritingFixRule] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: writingFixRulesKey),
           let decodedRules = try? JSONDecoder().decode([WritingFixRule].self, from: data) {
            return sanitizedRules(decodedRules)
        }

        let savedTrigger = defaults.string(forKey: writingFixTriggerKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fallbackTrigger = (savedTrigger?.isEmpty == false) ? savedTrigger! : defaultWritingFixTrigger
        return sanitizedRules([
            WritingFixRule(trigger: fallbackTrigger, prompt: defaultWritingFixPrompt)
        ])
    }

    private static func sanitizedRules(_ rules: [WritingFixRule]) -> [WritingFixRule] {
        var deduplicatedRules: [WritingFixRule] = []
        var seenTriggers: Set<String> = []

        for rule in rules {
            let trigger = rule.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = rule.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTrigger = trigger.isEmpty ? defaultWritingFixTrigger : trigger
            let safePrompt = prompt.isEmpty ? defaultWritingFixPrompt : prompt

            guard !seenTriggers.contains(safeTrigger) else { continue }
            seenTriggers.insert(safeTrigger)
            deduplicatedRules.append(
                WritingFixRule(id: rule.id, trigger: safeTrigger, prompt: safePrompt)
            )
        }

        if deduplicatedRules.isEmpty {
            deduplicatedRules = [
                WritingFixRule(
                    trigger: defaultWritingFixTrigger,
                    prompt: defaultWritingFixPrompt
                )
            ]
        }

        return deduplicatedRules
    }
}
