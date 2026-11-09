import AppKit
import Combine
import CryptoKit
import Foundation

struct ClipboardHistoryItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    let id: UUID
    let kind: Kind
    var text: String?
    var imageFileName: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var contentHash: String
    var copiedAt: Date
    var sourceAppName: String?
    var isPinned: Bool
    /// User-chosen name shown in the list instead of the content preview.
    var customTitle: String?

    init(
        id: UUID,
        kind: Kind,
        text: String? = nil,
        imageFileName: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        contentHash: String,
        copiedAt: Date,
        sourceAppName: String?,
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFileName = imageFileName
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.contentHash = contentHash
        self.copiedAt = copiedAt
        self.sourceAppName = sourceAppName
        self.isPinned = isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        copiedAt = try container.decode(Date.self, forKey: .copiedAt)
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
    }

    var previewLines: String {
        guard let text else { return "" }
        let lines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0) }
            .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        return lines.prefix(2).joined(separator: "\n")
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardHistoryItem] = []

    static let maxItems = 100

    private let directoryURL: URL
    private let imagesURL: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directoryURL = base.appendingPathComponent("Toolkit/ClipboardHistory", isDirectory: true)
        imagesURL = directoryURL.appendingPathComponent("Images", isDirectory: true)
        indexURL = directoryURL.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        load()
    }

    func addText(_ text: String, sourceAppName: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let hash = Self.hash(Data(text.utf8))
        if bumpExisting(hash: hash, sourceAppName: sourceAppName) { return }
        insert(
            ClipboardHistoryItem(
                id: UUID(),
                kind: .text,
                text: text,
                contentHash: hash,
                copiedAt: Date(),
                sourceAppName: sourceAppName
            )
        )
    }

    func addImage(pngData: Data, size: CGSize, sourceAppName: String?) {
        let hash = Self.hash(pngData)
        if bumpExisting(hash: hash, sourceAppName: sourceAppName) { return }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        do {
            try pngData.write(to: imagesURL.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return
        }
        insert(
            ClipboardHistoryItem(
                id: id,
                kind: .image,
                imageFileName: fileName,
                imageWidth: Int(size.width),
                imageHeight: Int(size.height),
                contentHash: hash,
                copiedAt: Date(),
                sourceAppName: sourceAppName
            )
        )
    }

    func image(for item: ClipboardHistoryItem) -> NSImage? {
        guard let url = imageURL(for: item) else { return nil }
        return NSImage(contentsOf: url)
    }

    func imageURL(for item: ClipboardHistoryItem) -> URL? {
        guard let fileName = item.imageFileName else { return nil }
        return imagesURL.appendingPathComponent(fileName)
    }

    func delete(id: ClipboardHistoryItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        removeImageFile(for: items[index])
        items.remove(at: index)
        save()
    }

    func clearAll() {
        items.forEach(removeImageFile(for:))
        items.removeAll()
        save()
    }

    func togglePin(id: ClipboardHistoryItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        trimToLimit()
        save()
    }

    /// Sets the list title for an item; an empty name restores the content preview.
    func rename(id: ClipboardHistoryItem.ID, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmed.isEmpty ? nil : trimmed
        guard items[index].customTitle != newTitle else { return }
        items[index].customTitle = newTitle
        save()
    }

    /// Moves an item to the top without changing its content (used after re-copying it).
    func promote(id: ClipboardHistoryItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.copiedAt = Date()
        items.insert(item, at: 0)
        save()
    }

    private func bumpExisting(hash: String, sourceAppName: String?) -> Bool {
        guard let index = items.firstIndex(where: { $0.contentHash == hash }) else { return false }
        var item = items.remove(at: index)
        item.copiedAt = Date()
        item.sourceAppName = sourceAppName ?? item.sourceAppName
        items.insert(item, at: 0)
        save()
        return true
    }

    private func insert(_ item: ClipboardHistoryItem) {
        items.insert(item, at: 0)
        trimToLimit()
        save()
    }

    /// Items are kept newest-first, so the oldest unpinned item is the last unpinned one.
    /// Each insert adds one item, so this normally evicts at most one entry.
    private func trimToLimit() {
        while items.count > Self.maxItems,
              let oldestUnpinned = items.lastIndex(where: { !$0.isPinned }) {
            removeImageFile(for: items[oldestUnpinned])
            items.remove(at: oldestUnpinned)
        }
    }

    private func removeImageFile(for item: ClipboardHistoryItem) {
        guard let url = imageURL(for: item) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data) else {
            return
        }
        items = decoded.filter { item in
            guard item.kind == .image else { return true }
            guard let url = imageURL(for: item) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        let countBeforeTrim = items.count
        trimToLimit()
        if items.count != countBeforeTrim { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
