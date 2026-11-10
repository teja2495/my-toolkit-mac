import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class ScreenshotsFeature: AppFeature {
    let id = "screenshots"

    /// Hard-coded trigger: ⌘⇧2.
    static let triggerSymbol = "⌘ ⇧ 2"

    private lazy var menuController = ScreenshotMenuPanelController()
    private var triggerHotKey: HotKey?
    private var isStarted = false
    private var isCapturing = false

    func start() {
        guard !isStarted else { return }
        isStarted = true

        triggerHotKey = HotKey(
            carbonKeyCode: kVK_ANSI_2,
            carbonModifiers: cmdKey | shiftKey,
            onKeyDown: { [weak self] in
                MainActor.assumeIsolated {
                    self?.captureSelection()
                }
            },
            onKeyUp: {}
        )
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        triggerHotKey = nil
        menuController.close()
    }

    // MARK: - Capture

    private func captureSelection() {
        guard !isCapturing else { return }
        menuController.close()
        ScreenshotFiles.removeStaleCaptures()

        let url = ScreenshotFiles.newCaptureURL()
        // -i: interactive selection (Space toggles window mode, Esc cancels).
        runScreencapture(arguments: ["-i", "-t", "png", url.path]) { [weak self] in
            self?.handleCapture(at: url, allowsFullScreen: true)
        }
    }

    private func captureFullScreen() {
        guard !isCapturing else { return }
        menuController.close()

        let url = ScreenshotFiles.newCaptureURL()
        // PNG at the display's native backing resolution (2× on Retina); keeps the DPI metadata.
        var arguments = ["-x", "-t", "png"]
        if let displayIndex = Self.displayIndexUnderMouse() {
            arguments += ["-D", String(displayIndex)]
        }
        arguments.append(url.path)

        // Give the menu panel a moment to disappear before grabbing the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.runScreencapture(arguments: arguments) { [weak self] in
                self?.handleCapture(at: url, allowsFullScreen: false)
            }
        }
    }

    private func runScreencapture(arguments: [String], completion: @escaping @MainActor () -> Void) {
        isCapturing = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in
                self?.isCapturing = false
                completion()
            }
        }
        do {
            try process.run()
        } catch {
            isCapturing = false
            NSLog("Screenshots: failed to launch screencapture: \(error)")
        }
    }

    private func handleCapture(at url: URL, allowsFullScreen: Bool) {
        // No file means the user cancelled the selection.
        guard isStarted,
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let image = NSImage(data: data) else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        copyToClipboard(pngData: data, image: image)

        menuController.show(
            thumbnail: image,
            onScreenAt: NSEvent.mouseLocation,
            allowsFullScreen: allowsFullScreen,
            onAction: { [weak self] action in
                self?.perform(action, captureURL: url)
            }
        )
    }

    // MARK: - Actions

    private func perform(_ action: ScreenshotMenuAction, captureURL: URL) {
        switch action {
        case .saveToDesktop:
            menuController.close()
            saveToDesktop(captureURL)
        case .openInPreview:
            menuController.close()
            openInPreview(captureURL)
        case .captureFullScreen:
            captureFullScreen()
        }
    }

    /// Writes the original PNG bytes untouched (full native pixel resolution), plus a TIFF built
    /// directly from the same bitmap so apps that prefer TIFF also get every pixel.
    private func copyToClipboard(pngData: Data, image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        if let tiff = NSBitmapImageRep(data: pngData)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    private func saveToDesktop(_ captureURL: URL) {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return }
        let destination = ScreenshotFiles.uniqueURL(in: desktop, baseName: captureURL.deletingPathExtension().lastPathComponent)
        do {
            try FileManager.default.copyItem(at: captureURL, to: destination)
        } catch {
            NSLog("Screenshots: failed to save to Desktop: \(error)")
            NSSound.beep()
        }
    }

    private func openInPreview(_ captureURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([captureURL], withApplicationAt: previewURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(captureURL)
        }
    }

    /// `screencapture -D` numbers displays from 1, starting with the main display,
    /// in the same order as `CGGetActiveDisplayList`.
    private static func displayIndexUnderMouse() -> Int? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }

        guard let index = displays.firstIndex(of: CGDirectDisplayID(number.uint32Value)) else { return nil }
        return index + 1
    }
}

/// Where captures live before the user decides what to do with them.
enum ScreenshotFiles {
    private static let staleAge: TimeInterval = 24 * 60 * 60

    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "Toolkit"
        let url = caches.appendingPathComponent(bundleID).appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newCaptureURL() -> URL {
        uniqueURL(in: directory, baseName: baseName(for: Date()))
    }

    /// Matches the macOS naming style: "Screenshot 2026-11-10 at 9.41.05 AM".
    static func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return "Screenshot \(formatter.string(from: date))"
    }

    static func uniqueURL(in directory: URL, baseName: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) (\(suffix))").appendingPathExtension("png")
            suffix += 1
        }
        return candidate
    }

    /// Captures are kept for a day so Preview can still read files opened from the menu.
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
