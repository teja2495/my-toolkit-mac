import AppKit
import FinderSync
import Foundation

final class FinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()

    override init() {
        super.init()
        controller.directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }

        let fileURLs = selectedRegularFileURLs()
        guard !fileURLs.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        let item = NSMenuItem(
            title: "Send to Phone with Toolkit",
            action: #selector(sendSelectedFilesToToolkit),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc
    private func sendSelectedFilesToToolkit() {
        let fileURLs = selectedRegularFileURLs()
        guard !fileURLs.isEmpty else { return }

        do {
            let shareURL = try makeToolkitShareURL(for: fileURLs)
            NSWorkspace.shared.open(shareURL)
        } catch {
            NSSound.beep()
        }
    }

    private func selectedRegularFileURLs() -> [URL] {
        let selectedURLs = controller.selectedItemURLs() ?? []

        let filteredURLs = selectedURLs.filter { url in
            guard url.isFileURL else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }

        return filteredURLs.sorted { $0.path < $1.path }
    }

    private func makeToolkitShareURL(for fileURLs: [URL]) throws -> URL {
        let paths = fileURLs.map(\.path)
        let payload = try JSONEncoder().encode(paths)
        let encodedPayload = payload.base64URLEncodedString()

        var components = URLComponents()
        components.scheme = "toolkit"
        components.host = "share-files"
        components.queryItems = [
            URLQueryItem(name: "payload", value: encodedPayload)
        ]

        guard let url = components.url else {
            throw FinderSyncError.invalidShareURL
        }
        return url
    }
}

private enum FinderSyncError: LocalizedError {
    case invalidShareURL

    var errorDescription: String? {
        switch self {
        case .invalidShareURL:
            return "Toolkit could not prepare the Finder share request."
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
