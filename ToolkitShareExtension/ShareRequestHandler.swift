import AppKit
import Foundation
import UniformTypeIdentifiers

final class ShareRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        Task {
            do {
                let fileURLs = try await extractFileURLs(from: context)
                guard !fileURLs.isEmpty else {
                    throw ShareRequestHandlerError.noFiles
                }

                let shareURL = try makeToolkitShareURL(for: fileURLs)
                let didOpen = await MainActor.run {
                    NSWorkspace.shared.open(shareURL)
                }
                guard didOpen else {
                    throw ShareRequestHandlerError.failedToLaunchToolkit
                }

                context.completeRequest(returningItems: nil)
            } catch {
                let nsError = error as NSError
                context.cancelRequest(withError: nsError)
            }
        }
    }

    private func extractFileURLs(from context: NSExtensionContext) async throws -> [URL] {
        let inputItems = context.inputItems.compactMap { $0 as? NSExtensionItem }
        let providers = inputItems
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }

        var fileURLs: [URL] = []
        for provider in providers {
            if let fileURL = try await loadFileURL(from: provider) {
                fileURLs.append(fileURL)
            }
        }

        return Array(Set(fileURLs)).sorted { $0.path < $1.path }
    }

    private func loadFileURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   url.isFileURL {
                    continuation.resume(returning: url)
                    return
                }

                if let urlData = (item as? NSSecureCoding) as? Data,
                   let url = URL(dataRepresentation: urlData, relativeTo: nil),
                   url.isFileURL {
                    continuation.resume(returning: url)
                    return
                }

                if let path = item as? String {
                    continuation.resume(returning: URL(fileURLWithPath: path))
                    return
                }

                continuation.resume(returning: nil)
            }
        }
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
            throw ShareRequestHandlerError.invalidShareURL
        }
        return url
    }
}

private enum ShareRequestHandlerError: LocalizedError {
    case noFiles
    case invalidShareURL
    case failedToLaunchToolkit

    var errorDescription: String? {
        switch self {
        case .noFiles:
            return "Toolkit could not read any files from the share request."
        case .invalidShareURL:
            return "Toolkit could not prepare the share request."
        case .failedToLaunchToolkit:
            return "Toolkit could not open the main app to finish sharing."
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
