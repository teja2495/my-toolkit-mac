import SwiftUI

struct TextExpanderSettingsView: View {
    private struct EntryDraft {
        var shortcut: String
        var expansion: String
    }

    @ObservedObject var bootstrapper: AppBootstrapper

    @State private var editingEntryID: UUID?
    @State private var entryDrafts: [UUID: EntryDraft] = [:]
    @FocusState private var focusedShortcutID: UUID?

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "text-expander" })
    }

    private var permissionGranted: Bool {
        bootstrapper.accessibilityPermissionManager.isTrusted
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "Text Expander",
            subtitle: "Type a shortcut followed by a space to instantly expand it to the full text in any app."
        ) {
            featureToggle
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if !permissionGranted {
                    PermissionRequiredBanner(bootstrapper: bootstrapper)
                }

                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Shortcuts")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(bootstrapper.textExpanderEntries.count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }

                        Text("Each shortcut expands when followed by a space. Shortcuts are case-sensitive.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 8) {
                            ForEach(bootstrapper.textExpanderEntries) { entry in
                                entryRow(for: entry)
                            }
                        }

                        Button {
                            addNewEntry()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Add shortcut")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
            }
        }
        .onAppear { syncDrafts() }
        .onChange(of: bootstrapper.textExpanderEntries) { syncDrafts() }
    }

    @ViewBuilder
    private var featureToggle: some View {
        if let feature {
            FeatureEnableToggle(
                isOn: feature.isEnabled,
                disabled: !permissionGranted
            ) {
                bootstrapper.toggleFeature(id: feature.id)
            }
        }
    }

    @ViewBuilder
    private func entryRow(for entry: TextExpanderEntry) -> some View {
        let isEditing = editingEntryID == entry.id

        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SHORTCUT")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                        TextField("shortcut", text: shortcutDraftBinding(for: entry.id))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.primary.opacity(0.06))
                            )
                            .focused($focusedShortcutID, equals: entry.id)
                            .onAppear { focusedShortcutID = entry.id }
                            .frame(maxWidth: 160)
                    }

                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 18)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("EXPANDS TO")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                        TextEditor(text: expansionDraftBinding(for: entry.id))
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 56, maxHeight: 120)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.primary.opacity(0.06))
                            )
                    }
                    .frame(maxWidth: .infinity)
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") {
                        resetDraft(id: entry.id)
                        editingEntryID = nil
                        focusedShortcutID = nil
                    }
                    .controlSize(.small)

                    Button("Save") {
                        saveEntry(id: entry.id)
                        editingEntryID = nil
                        focusedShortcutID = nil
                    }
                    .controlSize(.small)
                    .disabled(!isDirty(entry))
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    Text(shortcutDraftBinding(for: entry.id).wrappedValue)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.accentColor.opacity(0.12))
                        )

                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)

                    Text(expansionDraftBinding(for: entry.id).wrappedValue)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        editingEntryID = entry.id
                        focusedShortcutID = entry.id
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Edit")

                    Button {
                        deleteEntry(id: entry.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isEditing ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    private func shortcutDraftBinding(for entryID: UUID) -> Binding<String> {
        Binding(
            get: {
                entryDrafts[entryID]?.shortcut
                    ?? bootstrapper.textExpanderEntries.first(where: { $0.id == entryID })?.shortcut
                    ?? ""
            },
            set: { newValue in
                guard var draft = entryDrafts[entryID] else { return }
                draft.shortcut = newValue
                entryDrafts[entryID] = draft
            }
        )
    }

    private func expansionDraftBinding(for entryID: UUID) -> Binding<String> {
        Binding(
            get: {
                entryDrafts[entryID]?.expansion
                    ?? bootstrapper.textExpanderEntries.first(where: { $0.id == entryID })?.expansion
                    ?? ""
            },
            set: { newValue in
                guard var draft = entryDrafts[entryID] else { return }
                draft.expansion = newValue
                entryDrafts[entryID] = draft
            }
        )
    }

    private func addNewEntry() {
        let newEntry = TextExpanderEntry(shortcut: "shortcut", expansion: "expanded text")
        bootstrapper.textExpanderEntries.append(newEntry)
        entryDrafts[newEntry.id] = EntryDraft(shortcut: newEntry.shortcut, expansion: newEntry.expansion)
        editingEntryID = newEntry.id
        focusedShortcutID = newEntry.id
    }

    private func deleteEntry(id: UUID) {
        bootstrapper.textExpanderEntries.removeAll { $0.id == id }
        entryDrafts[id] = nil
        if editingEntryID == id { editingEntryID = nil }
        if focusedShortcutID == id { focusedShortcutID = nil }
    }

    private func syncDrafts() {
        let validIDs = Set(bootstrapper.textExpanderEntries.map(\.id))
        entryDrafts = entryDrafts.filter { validIDs.contains($0.key) }

        for entry in bootstrapper.textExpanderEntries where entryDrafts[entry.id] == nil {
            entryDrafts[entry.id] = EntryDraft(shortcut: entry.shortcut, expansion: entry.expansion)
        }
    }

    private func isDirty(_ entry: TextExpanderEntry) -> Bool {
        guard let draft = entryDrafts[entry.id] else { return false }
        return draft.shortcut != entry.shortcut || draft.expansion != entry.expansion
    }

    private func saveEntry(id: UUID) {
        guard let draft = entryDrafts[id] else { return }
        guard let index = bootstrapper.textExpanderEntries.firstIndex(where: { $0.id == id }) else { return }
        bootstrapper.textExpanderEntries[index].shortcut = draft.shortcut
        bootstrapper.textExpanderEntries[index].expansion = draft.expansion
    }

    private func resetDraft(id: UUID) {
        guard let entry = bootstrapper.textExpanderEntries.first(where: { $0.id == id }) else { return }
        entryDrafts[id] = EntryDraft(shortcut: entry.shortcut, expansion: entry.expansion)
    }
}
