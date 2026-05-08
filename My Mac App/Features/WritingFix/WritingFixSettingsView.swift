import SwiftUI

struct WritingFixSettingsView: View {
    private struct WritingFixRuleDraft {
        var trigger: String
        var prompt: String
    }

    @ObservedObject var bootstrapper: AppBootstrapper

    @State private var editingRuleID: UUID?
    @State private var ruleDrafts: [UUID: WritingFixRuleDraft] = [:]
    @FocusState private var focusedTriggerID: UUID?

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "writing-fix" })
    }

    private var permissionGranted: Bool {
        bootstrapper.accessibilityPermissionManager.isTrusted
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "Rewritely",
            subtitle: "Type a trigger word at the end of any text field. Apple Intelligence rewrites the text in place."
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
                            Text("Triggers")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(bootstrapper.writingFixRules.count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(Color.primary.opacity(0.05))
                                )
                        }

                        Text("Each trigger maps to a custom prompt. Use ")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        + Text("{{text}}")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                        + Text(" to position the input in your prompt.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 10) {
                            ForEach(bootstrapper.writingFixRules) { rule in
                                ruleEditor(for: rule)
                            }
                        }

                        Button {
                            addNewRule()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Add trigger")
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
        .onAppear { syncRuleDrafts() }
        .onChange(of: bootstrapper.writingFixRules) { syncRuleDrafts() }
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
    private func ruleEditor(for rule: WritingFixRule) -> some View {
        let isEditing = editingRuleID == rule.id

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("Trigger")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)

                if isEditing {
                    TextField("trigger", text: triggerDraftBinding(for: rule.id))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .focused($focusedTriggerID, equals: rule.id)
                        .onAppear { focusedTriggerID = rule.id }
                } else {
                    Text(triggerDraftBinding(for: rule.id).wrappedValue)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }

                Spacer(minLength: 8)

                if isEditing {
                    Button("Save") {
                        saveRule(id: rule.id)
                        editingRuleID = nil
                        focusedTriggerID = nil
                    }
                    .controlSize(.small)
                    .disabled(!isRuleDirty(rule))

                    Button("Cancel") {
                        resetRuleDraft(id: rule.id)
                        editingRuleID = nil
                        focusedTriggerID = nil
                    }
                    .controlSize(.small)
                } else {
                    Button {
                        editingRuleID = rule.id
                        focusedTriggerID = rule.id
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Edit")

                    if bootstrapper.writingFixRules.count > 1 {
                        Button {
                            deleteRule(id: rule.id)
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)

                if isEditing {
                    TextEditor(text: promptDraftBinding(for: rule.id))
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 90)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                } else {
                    Text(promptDraftBinding(for: rule.id).wrappedValue)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.04))
                        )
                }
            }
        }
        .padding(14)
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

    private func triggerDraftBinding(for ruleID: UUID) -> Binding<String> {
        Binding(
            get: {
                ruleDrafts[ruleID]?.trigger
                    ?? bootstrapper.writingFixRules.first(where: { $0.id == ruleID })?.trigger
                    ?? ""
            },
            set: { newValue in
                guard var draft = ruleDrafts[ruleID] else { return }
                draft.trigger = newValue
                ruleDrafts[ruleID] = draft
            }
        )
    }

    private func promptDraftBinding(for ruleID: UUID) -> Binding<String> {
        Binding(
            get: {
                ruleDrafts[ruleID]?.prompt
                    ?? bootstrapper.writingFixRules.first(where: { $0.id == ruleID })?.prompt
                    ?? ""
            },
            set: { newValue in
                guard var draft = ruleDrafts[ruleID] else { return }
                draft.prompt = newValue
                ruleDrafts[ruleID] = draft
            }
        )
    }

    private func addNewRule() {
        let newRule = WritingFixRule(
            trigger: "newfix",
            prompt: GrammarTypoCorrector.defaultPromptTemplate
        )
        bootstrapper.writingFixRules.append(newRule)
        ruleDrafts[newRule.id] = WritingFixRuleDraft(
            trigger: newRule.trigger,
            prompt: newRule.prompt
        )
        editingRuleID = newRule.id
        focusedTriggerID = newRule.id
    }

    private func deleteRule(id: UUID) {
        bootstrapper.writingFixRules.removeAll { $0.id == id }
        ruleDrafts[id] = nil
        if editingRuleID == id { editingRuleID = nil }
        if focusedTriggerID == id { focusedTriggerID = nil }
    }

    private func syncRuleDrafts() {
        let validRuleIDs = Set(bootstrapper.writingFixRules.map(\.id))
        ruleDrafts = ruleDrafts.filter { validRuleIDs.contains($0.key) }

        for rule in bootstrapper.writingFixRules where ruleDrafts[rule.id] == nil {
            ruleDrafts[rule.id] = WritingFixRuleDraft(
                trigger: rule.trigger,
                prompt: rule.prompt
            )
        }
    }

    private func isRuleDirty(_ rule: WritingFixRule) -> Bool {
        guard let draft = ruleDrafts[rule.id] else { return false }
        return draft.trigger != rule.trigger || draft.prompt != rule.prompt
    }

    private func saveRule(id: UUID) {
        guard let draft = ruleDrafts[id] else { return }
        guard let index = bootstrapper.writingFixRules.firstIndex(where: { $0.id == id }) else { return }
        bootstrapper.writingFixRules[index].trigger = draft.trigger
        bootstrapper.writingFixRules[index].prompt = draft.prompt
    }

    private func resetRuleDraft(id: UUID) {
        guard let rule = bootstrapper.writingFixRules.first(where: { $0.id == id }) else { return }
        ruleDrafts[id] = WritingFixRuleDraft(trigger: rule.trigger, prompt: rule.prompt)
    }
}
