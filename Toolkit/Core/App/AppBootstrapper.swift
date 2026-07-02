import AppKit
import Combine
import Foundation

struct VSCodeFolderShortcut: Identifiable, Codable, Equatable {
    let id: UUID
    var path: String

    init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }
}

@MainActor
final class AppBootstrapper: ObservableObject {
    @Published var mediaControlsHoverDelay: Double {
        didSet {
            UserDefaults.standard.set(mediaControlsHoverDelay, forKey: Self.mediaControlsHoverDelayKey)
            (liveFeatures["media-controls"] as? MediaControlsFeature)?.hoverDelay = max(0, mediaControlsHoverDelay)
        }
    }

    @Published var dockHoverPopupDelay: Double {
        didSet {
            UserDefaults.standard.set(dockHoverPopupDelay, forKey: Self.dockHoverPopupDelayKey)
            (liveFeatures["dock-window-hover"] as? DockWindowHoverFeature)?.popupDelay = max(0, dockHoverPopupDelay)
        }
    }

    @Published private(set) var availableFeatures: [FeatureDescriptor] = [
        FeatureDescriptor(
            id: "corner-notes",
            title: "Quick Notes & Tasks",
            summary: "Opens a two-pane todo checklist and note window from the bottom-right corner.",
            requiresAccessibilityAccess: false,
            isEnabled: false
        ),
        FeatureDescriptor(
            id: "system-health",
            title: "System Health",
            summary: "Shows a menu bar health dot for CPU, memory, disk, battery, and swap usage.",
            requiresAccessibilityAccess: false,
            isEnabled: false
        ),
        FeatureDescriptor(
            id: "media-controls",
            title: "Media Controls",
            summary: "Shows playback controls at the top center of notched and non-notched displays.",
            requiresAccessibilityAccess: false,
            isEnabled: false
        ),
        FeatureDescriptor(
            id: "phone-integration",
            title: "Phone",
            summary: "Pairs with Android phones over the local network for secure Toolkit integration.",
            requiresAccessibilityAccess: false,
            isEnabled: true
        ),
        FeatureDescriptor(
            id: "dock-window-hover",
            title: "App Windows",
            summary: "Shows a popup with open window titles when hovering app icons in the Dock.",
            requiresAccessibilityAccess: true,
            isEnabled: true
        ),
        FeatureDescriptor(
            id: "writing-fix",
            title: "Rewritely",
            summary: "Type a trigger at the end of focused text to fix grammar and typos with Apple Intelligence.",
            requiresAccessibilityAccess: true,
            isEnabled: true
        ),
        FeatureDescriptor(
            id: "text-expander",
            title: "Text Expander",
            summary: "Type a shortcut followed by a space to instantly expand it to the full text in any app.",
            requiresAccessibilityAccess: true,
            isEnabled: true
        ),
        FeatureDescriptor(
            id: "miscellaneous",
            title: "Miscellaneous",
            summary: "Small system tweaks and utility behaviors.",
            requiresAccessibilityAccess: false,
            isEnabled: true
        )
    ]

    @Published var textExpanderEntries: [TextExpanderEntry] {
        didSet {
            let safeEntries = Self.sanitizedEntries(textExpanderEntries)
            if textExpanderEntries != safeEntries {
                textExpanderEntries = safeEntries
                return
            }

            if let encoded = try? JSONEncoder().encode(safeEntries) {
                UserDefaults.standard.set(encoded, forKey: Self.textExpanderEntriesKey)
            }

            (liveFeatures["text-expander"] as? TextExpanderFeature)?.entries = safeEntries
        }
    }

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

    @Published var vscodeFolderShortcuts: [VSCodeFolderShortcut] {
        didSet {
            let safeShortcuts = Self.sanitizedVSCodeFolderShortcuts(vscodeFolderShortcuts)
            if vscodeFolderShortcuts != safeShortcuts {
                vscodeFolderShortcuts = safeShortcuts
                return
            }

            if let encodedShortcuts = try? JSONEncoder().encode(safeShortcuts) {
                UserDefaults.standard.set(encodedShortcuts, forKey: Self.vscodeFolderShortcutsKey)
            }

            (liveFeatures["dock-window-hover"] as? DockWindowHoverFeature)?.vscodeFolderShortcuts = safeShortcuts
        }
    }

    @Published var accessibilityFeaturesMasterEnabled: Bool {
        didSet {
            UserDefaults.standard.set(accessibilityFeaturesMasterEnabled, forKey: Self.accessibilityFeaturesMasterEnabledKey)
            updateFeatureLifecycle()
        }
    }

    @Published var phoneClipboardSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(phoneClipboardSyncEnabled, forKey: Self.phoneClipboardSyncEnabledKey)
            (liveFeatures["phone-integration"] as? PhoneIntegrationFeature)?
                .controller
                .setClipboardSyncEnabled(phoneClipboardSyncEnabled)
        }
    }

    let accessibilityPermissionManager = AccessibilityPermissionManager()

    private static let textExpanderEntriesKey = "textExpanderEntries"
    private static let mediaControlsHoverDelayKey = "mediaControlsHoverDelay"
    private static let dockHoverPopupDelayKey = "dockHoverPopupDelay"
    private static let defaultMediaControlsHoverDelay = 0.0
    private static let defaultDockHoverPopupDelay = 2.0
    private static let legacyDockHoverPopupDelay = 0.25
    private static let writingFixRulesKey = "writingFixRules"
    private static let writingFixTriggerKey = "writingFixTrigger"
    private static let vscodeFolderShortcutsKey = "vscodeFolderShortcuts"
    private static let accessibilityFeaturesMasterEnabledKey = "accessibilityFeaturesMasterEnabled"
    private static let phoneClipboardSyncEnabledKey = "phoneClipboardSyncEnabled"
    private static let defaultWritingFixTrigger = "fxx"
    private static let defaultWritingFixPrompt = GrammarTypoCorrector.defaultPromptTemplate

    private var liveFeatures: [String: AppFeature] = [:]
    private var permissionRefreshTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        mediaControlsHoverDelay = UserDefaults.standard.object(forKey: Self.mediaControlsHoverDelayKey) as? Double ?? Self.defaultMediaControlsHoverDelay
        let savedDelay = UserDefaults.standard.object(forKey: Self.dockHoverPopupDelayKey) as? Double
        let resolvedDelay: Double
        if let savedDelay, abs(savedDelay - Self.legacyDockHoverPopupDelay) < 0.001 {
            resolvedDelay = Self.defaultDockHoverPopupDelay
        } else {
            resolvedDelay = savedDelay ?? Self.defaultDockHoverPopupDelay
        }
        dockHoverPopupDelay = resolvedDelay
        textExpanderEntries = Self.loadTextExpanderEntries()
        writingFixRules = Self.loadWritingFixRules()
        vscodeFolderShortcuts = Self.loadVSCodeFolderShortcuts()
        accessibilityFeaturesMasterEnabled = UserDefaults.standard.object(forKey: Self.accessibilityFeaturesMasterEnabledKey) as? Bool ?? true
        phoneClipboardSyncEnabled = UserDefaults.standard.object(forKey: Self.phoneClipboardSyncEnabledKey) as? Bool ?? true
        if resolvedDelay != savedDelay {
            UserDefaults.standard.set(resolvedDelay, forKey: Self.dockHoverPopupDelayKey)
        }
        Self.ensureDefaultShortcut(for: writingFixRules)
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

    func setDockWindowHoverSuspended(_ isSuspended: Bool) {
        (liveFeatures["dock-window-hover"] as? DockWindowHoverFeature)?.isSuspended = isSuspended
    }

    func phoneIntegrationController() -> PhoneBridgeController {
        ensureFeatureExists(PhoneIntegrationFeature())
        return (liveFeatures["phone-integration"] as? PhoneIntegrationFeature)?.controller ?? PhoneBridgeController()
    }

    func handleSharedFiles(_ urls: [URL]) {
        let controller = phoneIntegrationController()
        if liveFeatures["phone-integration"] == nil {
            ensureFeatureExists(PhoneIntegrationFeature())
        }
        controller.start()
        controller.queueFilesForRemoteShare(urls)
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
        ensureFeatureExists(SystemHealthFeature())
        let mediaControlsFeature = MediaControlsFeature()
        mediaControlsFeature.hoverDelay = max(0, mediaControlsHoverDelay)
        ensureFeatureExists(mediaControlsFeature)
        ensureFeatureExists(PhoneIntegrationFeature())
        ensureFeatureExists(MiscellaneousFeature())

        if accessibilityPermissionManager.isTrusted {
            let feature = DockWindowHoverFeature()
            feature.popupDelay = max(0, dockHoverPopupDelay)
            feature.vscodeFolderShortcuts = vscodeFolderShortcuts
            ensureFeatureExists(feature)
            ensureFeatureExists(WritingFixFeature())
            ensureFeatureExists(TextExpanderFeature())
        } else {
            if let feature = liveFeatures.removeValue(forKey: "dock-window-hover") {
                feature.stop()
            }
            if let writingFixFeature = liveFeatures.removeValue(forKey: "writing-fix") {
                writingFixFeature.stop()
            }
            if let textExpanderFeature = liveFeatures.removeValue(forKey: "text-expander") {
                textExpanderFeature.stop()
            }
        }

        for descriptor in availableFeatures {
            guard let feature = liveFeatures[descriptor.id] else { continue }
            let canRun = !(descriptor.requiresAccessibilityAccess && !accessibilityFeaturesMasterEnabled)
            if descriptor.isEnabled && canRun {
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
                dockFeature.vscodeFolderShortcuts = vscodeFolderShortcuts
            }
            if let mediaControlsFeature = liveFeatures[feature.id] as? MediaControlsFeature {
                mediaControlsFeature.hoverDelay = max(0, mediaControlsHoverDelay)
            }
            if let writingFixFeature = liveFeatures[feature.id] as? WritingFixFeature {
                writingFixFeature.rules = writingFixRules
            }
            if let textExpanderFeature = liveFeatures[feature.id] as? TextExpanderFeature {
                textExpanderFeature.entries = textExpanderEntries
            }
            if let phoneIntegrationFeature = liveFeatures[feature.id] as? PhoneIntegrationFeature {
                phoneIntegrationFeature.controller.setClipboardSyncEnabled(phoneClipboardSyncEnabled)
            }
            return
        }

        if let dockFeature = feature as? DockWindowHoverFeature {
            dockFeature.popupDelay = max(0, dockHoverPopupDelay)
            dockFeature.vscodeFolderShortcuts = vscodeFolderShortcuts
        }
        if let mediaControlsFeature = feature as? MediaControlsFeature {
            mediaControlsFeature.hoverDelay = max(0, mediaControlsHoverDelay)
        }
        if let writingFixFeature = feature as? WritingFixFeature {
            writingFixFeature.rules = writingFixRules
        }
        if let textExpanderFeature = feature as? TextExpanderFeature {
            textExpanderFeature.entries = textExpanderEntries
        }
        if let phoneIntegrationFeature = feature as? PhoneIntegrationFeature {
            phoneIntegrationFeature.controller.setClipboardSyncEnabled(phoneClipboardSyncEnabled)
        }
        liveFeatures[feature.id] = feature
    }

    private static func loadTextExpanderEntries() -> [TextExpanderEntry] {
        if let data = UserDefaults.standard.data(forKey: textExpanderEntriesKey),
           let decoded = try? JSONDecoder().decode([TextExpanderEntry].self, from: data) {
            return sanitizedEntries(decoded)
        }
        return []
    }

    private static func sanitizedEntries(_ entries: [TextExpanderEntry]) -> [TextExpanderEntry] {
        var seen: Set<String> = []
        return entries.compactMap { entry in
            let shortcut = entry.shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
            let expansion = entry.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shortcut.isEmpty, !expansion.isEmpty else { return nil }
            guard !seen.contains(shortcut) else { return nil }
            seen.insert(shortcut)
            return TextExpanderEntry(id: entry.id, shortcut: shortcut, expansion: expansion)
        }
    }

    private static func ensureDefaultShortcut(for rules: [WritingFixRule]) {
        guard let firstRule = rules.first,
              KeyboardShortcuts.getShortcut(for: firstRule.shortcutName) == nil
        else { return }
        KeyboardShortcuts.setShortcut(.init(.g, modifiers: [.command, .shift]), for: firstRule.shortcutName)
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

    private static func loadVSCodeFolderShortcuts() -> [VSCodeFolderShortcut] {
        guard let data = UserDefaults.standard.data(forKey: vscodeFolderShortcutsKey),
              let decoded = try? JSONDecoder().decode([VSCodeFolderShortcut].self, from: data) else {
            return []
        }
        return sanitizedVSCodeFolderShortcuts(decoded)
    }

    private static func sanitizedVSCodeFolderShortcuts(
        _ shortcuts: [VSCodeFolderShortcut]
    ) -> [VSCodeFolderShortcut] {
        var seenPaths: Set<String> = []
        return shortcuts.compactMap { shortcut in
            let trimmedPath = shortcut.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { return nil }

            let expandedPath = (trimmedPath as NSString).expandingTildeInPath
            let standardizedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
            guard !standardizedPath.isEmpty else { return nil }
            guard !seenPaths.contains(standardizedPath) else { return nil }
            seenPaths.insert(standardizedPath)
            return VSCodeFolderShortcut(id: shortcut.id, path: standardizedPath)
        }
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
