import AppKit
import Foundation
import OSLog

@MainActor
final class ToolkitAppDelegate: NSObject, NSApplicationDelegate {
    var onOpenFiles: (([URL]) -> Void)? {
        didSet {
            guard let onOpenFiles, !pendingOpenFileURLs.isEmpty else { return }
            onOpenFiles(pendingOpenFileURLs)
            pendingOpenFileURLs.removeAll()
        }
    }
    var onOpenShareURLPaths: (([URL]) -> Void)? {
        didSet {
            guard let onOpenShareURLPaths, !pendingShareURLPaths.isEmpty else { return }
            onOpenShareURLPaths(pendingShareURLPaths)
            pendingShareURLPaths.removeAll()
        }
    }
    private var pendingOpenFileURLs: [URL] = []
    private var pendingShareURLPaths: [URL] = []
    private let logger = Logger(subsystem: "com.tk.toolkit", category: "ToolkitAppDelegate")

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let onOpenFiles {
            onOpenFiles(urls)
        } else {
            pendingOpenFileURLs.append(contentsOf: urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    deinit {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc
    private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString)
        else {
            return
        }

        let sharedFileURLs = Self.sharedFileURLs(from: url)
        guard !sharedFileURLs.isEmpty else { return }

        logger.debug("Received share URL with \(sharedFileURLs.count) file(s)")
        if let onOpenShareURLPaths {
            onOpenShareURLPaths(sharedFileURLs)
        } else {
            pendingShareURLPaths.append(contentsOf: sharedFileURLs)
        }
    }

    private static func sharedFileURLs(from url: URL) -> [URL] {
        guard url.scheme == "toolkit", url.host == "share-files" else { return [] }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let payload = components.queryItems?.first(where: { $0.name == "payload" })?.value,
            let payloadData = Data(base64URLEncoded: payload),
            let paths = try? JSONDecoder().decode([String].self, from: payloadData)
        else {
            return []
        }

        return paths
            .map { URL(fileURLWithPath: $0) }
            .filter(\.isFileURL)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - (normalized.count % 4)) % 4
        let padded = normalized + String(repeating: "=", count: padding)
        self.init(base64Encoded: padded)
    }
}
