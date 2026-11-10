import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation

@MainActor
final class ScreenCaptureFeature: NSObject, AppFeature {
    let id = "screen-capture"

    /// Hard-coded triggers.
    static let screenshotSymbol = "⌘ ⇧ 2"
    static let recordingSymbol = "⌘ ⇧ 3"

    private enum RecordingState {
        case idle
        case starting
        case recording
        case stopping
    }

    private lazy var resultPanel = CaptureResultPanelController()
    private lazy var recordingToolbar = RecordingToolbarController()
    private let recorder = ScreenRecorder()

    private var screenshotHotKey: HotKey?
    private var recordingHotKey: HotKey?
    private var isStarted = false
    /// Hide open apps (and Toolkit's windows) while an area or full-screen recording runs.
    var hidesAppsBeforeRecording = true
    private var isCapturingScreenshot = false

    private var recordingState: RecordingState = .idle
    private var recordingStatusItem: NSStatusItem?
    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    private var stopRequestedWhileStarting = false
    private var stopGlobalKeyMonitor: Any?
    private var stopLocalKeyMonitor: Any?
    private lazy var areaIndicator = RecordingAreaIndicator()
    private let stopToolbar = RecordingStopToolbarController()
    private var appsHiddenForDesktop = MinimizedApps()

    override init() {
        super.init()
        recorder.onFinished = { [weak self] result in
            self?.recordingFinished(result)
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        CaptureFiles.removeStaleCaptures()

        screenshotHotKey = HotKey(
            carbonKeyCode: kVK_ANSI_2,
            carbonModifiers: cmdKey | shiftKey,
            onKeyDown: { [weak self] in
                MainActor.assumeIsolated {
                    self?.captureSelection()
                }
            },
            onKeyUp: {}
        )

        recordingHotKey = HotKey(
            carbonKeyCode: kVK_ANSI_3,
            carbonModifiers: cmdKey | shiftKey,
            onKeyDown: { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleRecordingShortcut()
                }
            },
            onKeyUp: {}
        )
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        screenshotHotKey = nil
        recordingHotKey = nil
        resultPanel.close()
        recordingToolbar.close()
        switch recordingState {
        case .recording:
            stopRecording()
        case .starting:
            stopRequestedWhileStarting = true
        case .idle, .stopping:
            break
        }
    }

    // MARK: - Screenshot

    private func captureSelection() {
        guard !isCapturingScreenshot else { return }
        resultPanel.close()
        recordingToolbar.close()
        CaptureFiles.removeStaleCaptures()

        let url = CaptureFiles.newURL(for: .screenshot)
        // -i: interactive selection (Space toggles window mode, Esc cancels).
        // PNG at the display's native backing resolution (2× on Retina); keeps the DPI metadata.
        runScreencapture(arguments: ["-i", "-t", "png", url.path]) { [weak self] in
            self?.handleScreenshot(at: url, allowsFullScreen: true)
        }
    }

    private func captureFullScreen() {
        guard !isCapturingScreenshot else { return }
        resultPanel.close()

        let url = CaptureFiles.newURL(for: .screenshot)
        var arguments = ["-x", "-t", "png"]
        if let displayIndex = Self.displayIndexUnderMouse() {
            arguments += ["-D", String(displayIndex)]
        }
        arguments.append(url.path)

        // Give the popup a moment to disappear before grabbing the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.runScreencapture(arguments: arguments) { [weak self] in
                self?.handleScreenshot(at: url, allowsFullScreen: false)
            }
        }
    }

    private func runScreencapture(arguments: [String], completion: @escaping @MainActor () -> Void) {
        isCapturingScreenshot = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in
                self?.isCapturingScreenshot = false
                completion()
            }
        }
        do {
            try process.run()
        } catch {
            isCapturingScreenshot = false
            NSLog("Screen Capture: failed to launch screencapture: \(error)")
        }
    }

    private func handleScreenshot(at url: URL, allowsFullScreen: Bool) {
        // No file means the user cancelled the selection.
        guard isStarted,
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let image = NSImage(data: data) else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        copyImageToClipboard(pngData: data)

        var actions = [
            CaptureResultAction(title: "Save to Desktop", systemImage: "menubar.dock.rectangle") { [weak self] in
                self?.resultPanel.close()
                self?.saveToDesktop(url)
            },
            CaptureResultAction(title: "Open in Preview", systemImage: "eye") { [weak self] in
                self?.resultPanel.close()
                Self.open(url, withBundleIdentifier: "com.apple.Preview")
            }
        ]
        if allowsFullScreen {
            actions.append(CaptureResultAction(title: "Capture Full Screen", systemImage: "rectangle.dashed") { [weak self] in
                self?.captureFullScreen()
            })
        }

        resultPanel.show(
            thumbnail: image,
            caption: "Copied to clipboard",
            onScreenAt: NSEvent.mouseLocation,
            actions: actions
        )
    }

    /// Writes the original PNG bytes untouched (full native pixel resolution), plus a TIFF built
    /// directly from the same bitmap so apps that prefer TIFF also get every pixel.
    private func copyImageToClipboard(pngData: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        if let tiff = NSBitmapImageRep(data: pngData)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    // MARK: - Recording

    private func handleRecordingShortcut() {
        switch recordingState {
        case .idle:
            if recordingToolbar.isVisible {
                recordingToolbar.close()
                return
            }
            resultPanel.close()
            recordingToolbar.show(hidesApps: hidesAppsBeforeRecording) { [weak self] target, hiddenApps, recordAudio in
                self?.startRecording(target, hiddenApps: hiddenApps, recordAudio: recordAudio)
            }
        case .recording:
            stopRecording()
        case .starting:
            // Pressed again before capture actually began: stop as soon as it does.
            stopRequestedWhileStarting = true
        case .stopping:
            break
        }
    }

    private func startRecording(_ target: RecordingTarget, hiddenApps: MinimizedApps, recordAudio: Bool) {
        guard recordingState == .idle else { return }
        recordingState = .starting
        stopRequestedWhileStarting = false
        CaptureFiles.removeStaleCaptures()
        let url = CaptureFiles.newURL(for: .recording)
        CaptureFiles.activeRecordingURL = url

        // Apps hidden for the recording stay hidden until it ends.
        appsHiddenForDesktop = hiddenApps

        Task { [weak self] in
            // Let the overlays, toolbar and hidden apps finish disappearing so they never show in
            // the video.
            try? await Task.sleep(for: .milliseconds(hiddenApps.isEmpty ? 150 : 400))
            guard let self else { return }
            do {
                try await self.recorder.start(target: target, outputURL: url, capturesAudio: recordAudio)
                self.recordingState = .recording
                self.showRecordingStatusItem()
                self.stopToolbar.show(
                    on: self.recordingToolbar.lastScreen,
                    startDate: self.recordingStartDate ?? Date()
                ) { [weak self] in
                    self?.stopRecording()
                }
                self.installStopKeyMonitors()
                if case .area(let displayID, let rect) = target {
                    self.areaIndicator.show(displayID: displayID, rect: rect)
                }
                if self.stopRequestedWhileStarting {
                    self.stopRecording()
                }
            } catch {
                self.recordingState = .idle
                CaptureFiles.activeRecordingURL = nil
                self.unhideAppsHiddenForDesktop()
                NSLog("Screen Capture: failed to start recording: \(error)")
                NSSound.beep()
            }
        }
    }

    private func stopRecording() {
        guard recordingState == .recording else { return }
        recordingState = .stopping
        tearDownRecordingUI()
        recorder.stop()
    }

    private func tearDownRecordingUI() {
        removeRecordingStatusItem()
        removeStopKeyMonitors()
        areaIndicator.hide()
        stopToolbar.close()
        stopRequestedWhileStarting = false
    }

    /// Backup for the ⌘⇧3 hotkey while recording. The Carbon hotkey is paused whenever any menu is
    /// tracking (e.g. after using the App dropdown) and can fail to come back; these monitors
    /// make sure the shortcut still stops the recording. When the hotkey does fire, Carbon
    /// consumes the event, so only one path runs.
    private func installStopKeyMonitors() {
        removeStopKeyMonitors()

        let isStopShortcut: (NSEvent) -> Bool = { event in
            Int(event.keyCode) == kVK_ANSI_3
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
        }

        stopGlobalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard isStopShortcut(event) else { return }
            MainActor.assumeIsolated { self?.stopRecording() }
        }
        stopLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard isStopShortcut(event) else { return event }
            MainActor.assumeIsolated { self?.stopRecording() }
            return nil
        }
    }

    private func removeStopKeyMonitors() {
        for monitor in [stopGlobalKeyMonitor, stopLocalKeyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        stopGlobalKeyMonitor = nil
        stopLocalKeyMonitor = nil
    }

    // MARK: - Hidden apps

    private func unhideAppsHiddenForDesktop() {
        let hidden = appsHiddenForDesktop
        appsHiddenForDesktop = MinimizedApps()
        hidden.restore()
    }

    @objc private func stopRecordingFromStatusItem() {
        stopRecording()
    }

    private func recordingFinished(_ result: Result<URL, Error>) {
        recordingState = .idle
        CaptureFiles.activeRecordingURL = nil
        tearDownRecordingUI()
        unhideAppsHiddenForDesktop()

        switch result {
        case .failure(let error):
            NSLog("Screen Capture: recording failed: \(error)")
            NSSound.beep()
        case .success(let url):
            guard isStarted else { return }
            copyFileToClipboard(url)
            Task { [weak self] in
                let thumbnail = await Self.thumbnail(forVideoAt: url)
                self?.showRecordingResult(url: url, thumbnail: thumbnail)
            }
        }
    }

    private func showRecordingResult(url: URL, thumbnail: NSImage?) {
        resultPanel.show(
            thumbnail: thumbnail,
            caption: "Recording copied to clipboard",
            onScreenAt: NSEvent.mouseLocation,
            actions: [
                CaptureResultAction(title: "Save to Desktop", systemImage: "menubar.dock.rectangle") { [weak self] in
                    self?.resultPanel.close()
                    self?.saveToDesktop(url)
                },
                CaptureResultAction(title: "Open in QuickTime Player", systemImage: "play.rectangle") { [weak self] in
                    self?.resultPanel.close()
                    Self.open(url, withBundleIdentifier: "com.apple.QuickTimePlayerX")
                },
                CaptureResultAction(title: "Delete", systemImage: "trash", isDestructive: true) { [weak self] in
                    self?.resultPanel.close()
                    Self.deleteRecording(at: url)
                }
            ]
        )
    }

    /// Deletes the cached recording, and clears the clipboard if it still holds that file (pasting
    /// it would fail now). Copies already saved to the Desktop aren't touched.
    private static func deleteRecording(at url: URL) {
        let pasteboard = NSPasteboard.general
        let copied = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if copied.map(\.standardizedFileURL) == [url.standardizedFileURL] {
            pasteboard.clearContents()
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("Screen Capture: failed to delete recording: \(error)")
        }
    }

    /// Copies the file itself (as a file URL) so it can be pasted into Finder, Messages, Slack, etc.
    private func copyFileToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private static func thumbnail(forVideoAt url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    // MARK: - Recording status item

    /// Alongside the stop toolbar, this menu bar item shows elapsed time and stops the recording.
    private func showRecordingStatusItem() {
        removeRecordingStatusItem()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
            button.contentTintColor = .systemRed
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.title = " 0:00"
            button.toolTip = "Stop recording (\(Self.recordingSymbol))"
            button.target = self
            button.action = #selector(stopRecordingFromStatusItem)
        }
        recordingStatusItem = item
        recordingStartDate = Date()

        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.updateRecordingElapsedTime()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func updateRecordingElapsedTime() {
        guard let start = recordingStartDate else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let text = elapsed >= 3600
            ? String(format: " %d:%02d:%02d", elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60)
            : String(format: " %d:%02d", elapsed / 60, elapsed % 60)
        recordingStatusItem?.button?.title = text
    }

    private func removeRecordingStatusItem() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        if let recordingStatusItem {
            NSStatusBar.system.removeStatusItem(recordingStatusItem)
        }
        recordingStatusItem = nil
    }

    // MARK: - Shared actions

    private func saveToDesktop(_ captureURL: URL) {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        let destination = CaptureFiles.uniqueURL(
            in: desktop,
            baseName: captureURL.deletingPathExtension().lastPathComponent,
            pathExtension: captureURL.pathExtension
        )
        do {
            try FileManager.default.copyItem(at: captureURL, to: destination)
        } catch {
            NSLog("Screen Capture: failed to save to Desktop: \(error)")
            NSSound.beep()
        }
    }

    private static func open(_ url: URL, withBundleIdentifier bundleIdentifier: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// `screencapture -D` numbers displays from 1, starting with the main display,
    /// in the same order as `CGGetActiveDisplayList`.
    private static func displayIndexUnderMouse() -> Int? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let displayID = screen.captureDisplayID else {
            return nil
        }

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }

        guard let index = displays.firstIndex(of: displayID) else { return nil }
        return index + 1
    }

    /// Whether macOS's own ⌘⇧3 ("Save picture of screen as a file") is on. It takes priority
    /// over app shortcuts, so the recording shortcut only works once it is turned off.
    static var systemScreenshotShortcutEnabled: Bool {
        guard let hotKeys = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any],
            let entry = hotKeys["28"] as? [String: Any],
            let enabled = entry["enabled"] as? Bool else {
            return true // Not customized: macOS default is on.
        }
        return enabled
    }
}

/// Where captures live before the user decides what to do with them.
enum CaptureFiles {
    enum Kind {
        case screenshot
        case recording

        var prefix: String {
            switch self {
            case .screenshot: return "Screenshot"
            case .recording: return "Screen Recording"
            }
        }

        var pathExtension: String {
            switch self {
            case .screenshot: return "png"
            case .recording: return "mov"
            }
        }
    }

    private static let staleAge: TimeInterval = 24 * 60 * 60

    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "Toolkit"
        let url = caches.appendingPathComponent(bundleID).appendingPathComponent("ScreenCapture", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newURL(for kind: Kind) -> URL {
        uniqueURL(in: directory, baseName: baseName(for: kind, date: Date()), pathExtension: kind.pathExtension)
    }

    /// Matches the macOS naming style: "Screenshot 2026-11-10 at 9.41.05 AM".
    static func baseName(for kind: Kind, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return "\(kind.prefix) \(formatter.string(from: date))"
    }

    static func uniqueURL(in directory: URL, baseName: String, pathExtension: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) (\(suffix))").appendingPathExtension(pathExtension)
            suffix += 1
        }
        return candidate
    }

    /// The file a recording in progress is writing to; never removed by the cleanup below.
    static var activeRecordingURL: URL?

    /// Total size and count of cached captures (files saved to the Desktop are separate copies).
    static func cacheUsage() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let bytes = files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (files.count, bytes)
    }

    /// Removes every cached screenshot and recording. Desktop copies are untouched.
    static func removeAllCaptures() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.standardizedFileURL != activeRecordingURL?.standardizedFileURL {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Captures are kept for a day so Preview / QuickTime / pasted file references keep working.
    static func removeStaleCaptures() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-staleAge)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
