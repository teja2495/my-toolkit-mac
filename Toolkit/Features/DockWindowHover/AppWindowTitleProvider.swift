import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String
    let isMinimized: Bool
    let accessibilityIndex: Int?
    let ownerProcessIdentifier: pid_t
    let repositoryPath: String?
}

final class AppWindowTitleProvider {
    func windows(for processIdentifier: pid_t, bundleIdentifier: String?) -> [WindowInfo] {
        let primaryWindows = windowsForSingleProcess(processIdentifier, bundleIdentifier: bundleIdentifier)
        if !primaryWindows.isEmpty {
            return primaryWindows
        }

        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return []
        }

        let siblingProcesses = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != processIdentifier && $0.activationPolicy == .regular }

        for sibling in siblingProcesses {
            let siblingWindows = windowsForSingleProcess(
                sibling.processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
            if !siblingWindows.isEmpty {
                return siblingWindows
            }
        }

        return []
    }

    private func windowsForSingleProcess(
        _ processIdentifier: pid_t,
        bundleIdentifier: String?
    ) -> [WindowInfo] {
        let accessibilityWindows = windowsFromAccessibility(
            for: processIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        if !accessibilityWindows.isEmpty {
            return normalizeTitlesIfNeeded(accessibilityWindows, bundleIdentifier: bundleIdentifier)
        }

        let coreGraphicsWindows = windowsFromCoreGraphics(for: processIdentifier)
        return normalizeTitlesIfNeeded(coreGraphicsWindows, bundleIdentifier: bundleIdentifier)
    }

    private func windowsFromAccessibility(
        for processIdentifier: pid_t,
        bundleIdentifier: String?
    ) -> [WindowInfo] {
        let axApp = AXUIElementCreateApplication(processIdentifier)
        var ref: CFTypeRef?

        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return [] }

        let shouldResolveRepositoryPath = isVSCodeBundle(bundleIdentifier)
        return axWindows.enumerated().compactMap { index, axWindow in
            guard stringAttribute(kAXRoleAttribute as String, from: axWindow) == (kAXWindowRole as String) else {
                return nil
            }

            let rawTitle = stringAttribute(kAXTitleAttribute as String, from: axWindow) ?? ""
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let isMinimized = boolAttribute(kAXMinimizedAttribute as String, from: axWindow) ?? false
            let repositoryPath = shouldResolveRepositoryPath ? repositoryPathForVSCodeWindow(axWindow) : nil

            return WindowInfo(
                id: CGWindowID(index + 1),
                title: title,
                isMinimized: isMinimized,
                accessibilityIndex: index,
                ownerProcessIdentifier: processIdentifier,
                repositoryPath: repositoryPath
            )
        }
    }

    private func windowsFromCoreGraphics(for processIdentifier: pid_t) -> [WindowInfo] {
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var results: [WindowInfo] = []
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  pid_t(ownerPID) == processIdentifier else { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? true
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1

            // Off-screen windows with no alpha are hidden, not minimized — skip them
            if !isOnScreen && alpha <= 0 { continue }

            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            let rawTitle = info[kCGWindowName as String] as? String ?? ""
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            results.append(
                WindowInfo(
                    id: windowID,
                    title: title,
                    isMinimized: !isOnScreen,
                    accessibilityIndex: nil,
                    ownerProcessIdentifier: processIdentifier,
                    repositoryPath: nil
                )
            )
        }

        return results
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func normalizeTitlesIfNeeded(
        _ windows: [WindowInfo],
        bundleIdentifier: String?
    ) -> [WindowInfo] {
        let normalizer: ((String) -> String)?
        if isVSCodeBundle(bundleIdentifier) {
            normalizer = normalizedVSCodeTitle
        } else if isChromeBundle(bundleIdentifier) {
            normalizer = normalizedChromeTitle
        } else if isTeamsBundle(bundleIdentifier) {
            normalizer = normalizedTeamsTitle
        } else if isSlackBundle(bundleIdentifier) {
            normalizer = normalizedSlackTitle
        } else if isXcodeBundle(bundleIdentifier) {
            normalizer = normalizedXcodeTitle
        } else {
            normalizer = nil
        }

        guard let normalizer else { return windows }

        return windows.map { window in
            WindowInfo(
                id: window.id,
                title: normalizer(window.title),
                isMinimized: window.isMinimized,
                accessibilityIndex: window.accessibilityIndex,
                ownerProcessIdentifier: window.ownerProcessIdentifier,
                repositoryPath: window.repositoryPath
            )
        }
    }

    private func isVSCodeBundle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.microsoft.VSCode"
            || bundleIdentifier == "com.microsoft.VSCodeInsiders"
    }

    private func isChromeBundle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.google.Chrome"
            || bundleIdentifier == "com.google.Chrome.beta"
            || bundleIdentifier == "com.google.Chrome.canary"
    }

    private func isTeamsBundle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.microsoft.teams2"
            || bundleIdentifier == "com.microsoft.teams"
    }

    private func isSlackBundle(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.tinyspeck.slackmacgap"
    }

    private func isXcodeBundle(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.dt.Xcode"
    }

    private func normalizedVSCodeTitle(_ title: String) -> String {
        for separator in [" - ", " — ", " – "] {
            guard title.contains(separator) else { continue }
            let parts = title
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let lastPart = parts.last, !lastPart.isEmpty {
                return lastPart
            }
        }
        return title
    }

    // "Tab Name - Google Chrome - Profile Name" → "Tab Name - Profile Name"
    private func normalizedChromeTitle(_ title: String) -> String {
        let parts = title
            .components(separatedBy: " - ")
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != "Google Chrome" }
        return parts.joined(separator: " - ")
    }

    // "Something | Microsoft Teams" → "Something"
    private func normalizedTeamsTitle(_ title: String) -> String {
        if let range = title.range(of: " | Microsoft Teams", options: .backwards) {
            return String(title[title.startIndex..<range.lowerBound])
        }
        return title
    }

    // "Something - Slack" → "Something"
    private func normalizedSlackTitle(_ title: String) -> String {
        if title.hasSuffix(" - Slack") {
            return String(title.dropLast(" - Slack".count))
        }
        return title
    }

    // "Project Name — My Mac App.xcodeproj" → "Project Name"
    private func normalizedXcodeTitle(_ title: String) -> String {
        for separator in [" — ", " – ", " - "] {
            if let range = title.range(of: separator) {
                return String(title[title.startIndex..<range.lowerBound])
            }
        }
        return title
    }

    private func repositoryPathForVSCodeWindow(_ window: AXUIElement) -> String? {
        guard let documentPath = stringAttribute(kAXDocumentAttribute as String, from: window)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !documentPath.isEmpty else {
            return nil
        }

        let documentURL: URL
        if documentPath.hasPrefix("file://"), let fileURL = URL(string: documentPath), fileURL.isFileURL {
            documentURL = fileURL
        } else {
            documentURL = URL(fileURLWithPath: documentPath)
        }

        guard documentURL.isFileURL else { return nil }
        return repositoryURL(from: documentURL)?.path
    }

    private func repositoryURL(from documentURL: URL) -> URL? {
        let fileManager = FileManager.default
        let standardizedURL = documentURL.standardizedFileURL
        let path = standardizedURL.path

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)

        if exists && !isDirectory.boolValue {
            if standardizedURL.pathExtension == "code-workspace" {
                return standardizedURL
            }

            if let nearestRepositoryRoot = nearestRepositoryRoot(startingAt: standardizedURL.deletingLastPathComponent()) {
                return nearestRepositoryRoot
            }

            let parentDirectory = standardizedURL.deletingLastPathComponent()
            return fileManager.fileExists(atPath: parentDirectory.path) ? parentDirectory : nil
        }

        if exists && isDirectory.boolValue {
            if let nearestRepositoryRoot = nearestRepositoryRoot(startingAt: standardizedURL) {
                return nearestRepositoryRoot
            }
            return standardizedURL
        }

        if standardizedURL.pathExtension == "code-workspace" {
            return standardizedURL
        }

        if let nearestRepositoryRoot = nearestRepositoryRoot(startingAt: standardizedURL.deletingLastPathComponent()) {
            return nearestRepositoryRoot
        }

        return nil
    }

    private func nearestRepositoryRoot(startingAt url: URL) -> URL? {
        let fileManager = FileManager.default
        var currentURL = url.standardizedFileURL

        while true {
            let gitMarkerPath = currentURL.appendingPathComponent(".git").path
            if fileManager.fileExists(atPath: gitMarkerPath) {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                break
            }
            currentURL = parentURL
        }

        return nil
    }
}
