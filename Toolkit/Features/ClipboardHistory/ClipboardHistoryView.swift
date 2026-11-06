import AppKit
import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var store: ClipboardHistoryStore
    @ObservedObject var model: ClipboardHistoryViewModel
    let onCopy: (ClipboardHistoryItem) -> Void
    let onPaste: (ClipboardHistoryItem) -> Void
    let onClose: () -> Void

    private static let darkBackground = Color(red: 0.118, green: 0.118, blue: 0.125)
    private static let accent = Color(red: 0.93, green: 0.62, blue: 0.27)

    private var selectedItem: ClipboardHistoryItem? {
        guard let id = model.selectedID else { return nil }
        return store.items.first { $0.id == id }
    }

    private var pinnedItems: [ClipboardHistoryItem] { store.items.filter(\.isPinned) }
    private var recentItems: [ClipboardHistoryItem] { store.items.filter { !$0.isPinned } }

    /// Items in on-screen order: pinned section first, then recent.
    private var displayItems: [ClipboardHistoryItem] { pinnedItems + recentItems }

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Self.darkBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .frame(minWidth: 600, minHeight: 360)
        .onAppear {
            model.keyHandler = { key in handleKey(key) }
        }
        .onChange(of: store.items) {
            if selectedItem == nil {
                model.selectedID = recentItems.first?.id ?? pinnedItems.first?.id
            }
        }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Clipboard History")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 12)

            if store.items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            let pinned = pinnedItems
                            if !pinned.isEmpty {
                                sectionHeader("Pinned", systemImage: "pin.fill")
                                ForEach(pinned) { item in row(for: item) }
                                sectionHeader("Recent", systemImage: "clock")
                                    .padding(.top, 10)
                            }
                            ForEach(recentItems) { item in row(for: item) }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.selectedID) {
                        guard let id = model.selectedID else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.12))
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.1)
        }
        .foregroundStyle(.secondary.opacity(0.8))
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func row(for item: ClipboardHistoryItem) -> some View {
        ClipboardHistoryRow(
            item: item,
            store: store,
            isSelected: item.id == model.selectedID,
            onDelete: { delete(id: item.id) }
        )
        .id(item.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onCopy(item) }
        .onTapGesture {
            model.selectedID = item.id
        }
        .contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin") {
                store.togglePin(id: item.id)
            }
        }
    }

    /// Keys arrive from the panel's event monitor so they work regardless of which view has focus.
    private func handleKey(_ key: ClipboardHistoryViewModel.Key) -> Bool {
        switch key {
        case .up:
            moveSelection(by: -1)
        case .down:
            moveSelection(by: 1)
        case .copy, .paste:
            guard let selectedItem else { return false }
            key == .paste ? onPaste(selectedItem) : onCopy(selectedItem)
        case .delete:
            guard let id = model.selectedID else { return false }
            delete(id: id)
        case .close:
            onClose()
        }
        return true
    }

    private func moveSelection(by offset: Int) {
        let items = displayItems
        guard !items.isEmpty else { return }
        let currentIndex = model.selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
        let nextIndex = min(max(currentIndex + offset, 0), items.count - 1)
        model.selectedID = items[nextIndex].id
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Self.accent.opacity(0.85))
            Text("Nothing copied yet.")
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .italic()
            Text("Text and images you copy will show up here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func delete(id: ClipboardHistoryItem.ID) {
        let items = displayItems
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if model.selectedID == id {
            let nextIndex = index + 1 < items.count ? index + 1 : index - 1
            model.selectedID = nextIndex >= 0 ? items[nextIndex].id : nil
        }
        store.delete(id: id)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(for: item)
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                    .padding(.bottom, 14)

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                switch item.kind {
                case .text:
                    ScrollView {
                        Text(item.text ?? "")
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(24)
                    }
                case .image:
                    if let image = store.image(for: item) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: CGFloat(item.imageWidth ?? 10_000),
                                maxHeight: CGFloat(item.imageHeight ?? 10_000)
                            )
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Image unavailable")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        } else {
            Text("Select an item")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func detailHeader(for item: ClipboardHistoryItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.accent)
            Text(metadata(for: item))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                onCopy(item)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
    }

    private func metadata(for item: ClipboardHistoryItem) -> String {
        var parts: [String] = []
        switch item.kind {
        case .text:
            let text = item.text ?? ""
            parts.append("\(text.count) characters")
            let lineCount = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            if lineCount > 1 { parts.append("\(lineCount) lines") }
        case .image:
            if let width = item.imageWidth, let height = item.imageHeight {
                parts.append("\(width) × \(height)")
            }
        }
        if let app = item.sourceAppName { parts.append(app) }
        parts.append(item.copiedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardHistoryItem
    let store: ClipboardHistoryStore
    let isSelected: Bool
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isDeleteHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if item.kind == .image {
                ClipboardThumbnail(item: item, store: store, size: CGSize(width: 48, height: 40))
            } else {
                ClipboardTextIcon(text: item.text ?? "", isSelected: isSelected)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.kind == .image ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(isDeleteHovered ? Color.red.opacity(0.85) : Color.secondary.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isDeleteHovered = $0 }
            .help("Delete")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.12 : (isHovered ? 0.05 : 0)))
        )
        .onHover { isHovered = $0 }
    }

    private var subtitle: String {
        let time = item.copiedAt.formatted(.relative(presentation: .named))
        guard let app = item.sourceAppName, !app.isEmpty else { return time }
        return "\(time) · \(app)"
    }

    private var title: String {
        switch item.kind {
        case .text:
            return item.previewLines
        case .image:
            guard let width = item.imageWidth, let height = item.imageHeight else { return "Image" }
            return "Image  \(width) × \(height)"
        }
    }
}

/// Leading tile for text rows, sized to match image thumbnails so rows line up.
private struct ClipboardTextIcon: View {
    let text: String
    let isSelected: Bool

    private static let accent = Color(red: 0.93, green: 0.62, blue: 0.27)

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Self.accent.opacity(isSelected ? 0.2 : 0.12))
            .overlay(
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Self.accent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .frame(width: 48, height: 40)
    }

    private var symbolName: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()),
           !trimmed.contains(where: \.isWhitespace) {
            return "link"
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            return "folder"
        }
        if (trimmed.contains("{") && trimmed.contains("}")) || trimmed.contains("=>") || trimmed.contains("();") {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "text.alignleft"
    }
}

private struct ClipboardThumbnail: View {
    let item: ClipboardHistoryItem
    let store: ClipboardHistoryStore
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .task(id: item.id) {
            image = store.image(for: item)
        }
    }
}
