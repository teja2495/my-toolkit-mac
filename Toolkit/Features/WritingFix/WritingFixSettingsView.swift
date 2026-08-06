import SwiftUI

struct WritingFixSettingsView: View {
    private struct WritingFixRuleDraft {
        var trigger: String
        var prompt: String
        var provider: WritingFixProvider
    }

    @ObservedObject var bootstrapper: AppBootstrapper

    @State private var editingRuleID: UUID?
    @State private var ruleDrafts: [UUID: WritingFixRuleDraft] = [:]
    @State private var systemPromptDraft = ""
    @State private var apiKeyDraft = ""
    @State private var isResettingAPIKey = false
    @State private var apiKeyMessage: String?
    @State private var apiKeyMessageIsError = false
    @State private var pendingRule: WritingFixRule?
    @State private var ruleValidationErrors: [UUID: String] = [:]
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
            subtitle: "Use a trigger word or keyboard shortcut to rewrite text with Apple Intelligence, ChatGPT, or Codex CLI."
        ) {
            featureToggle
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if !permissionGranted {
                    PermissionRequiredBanner(bootstrapper: bootstrapper)
                }

                chatGPTSettings

                cliSettings

                systemPromptSettings

                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Triggers")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(displayedRules.count)")
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
                            ForEach(displayedRules) { rule in
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
                            .settingsSurface(Capsule(), emphasized: true)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
            }
        }
        .onAppear {
            syncRuleDrafts()
            systemPromptDraft = bootstrapper.writingFixSystemPrompt
        }
        .onChange(of: bootstrapper.writingFixRules) { syncRuleDrafts() }
    }

    private var displayedRules: [WritingFixRule] {
        if let pendingRule {
            return bootstrapper.writingFixRules + [pendingRule]
        }
        return bootstrapper.writingFixRules
    }

    private var chatGPTSettings: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("ChatGPT")
                    .font(.system(size: 13, weight: .semibold))

                Text("The API key is stored in this Mac's Keychain and is only sent to OpenAI when a ChatGPT rule runs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if bootstrapper.hasWritingFixAPIKey, !isResettingAPIKey {
                        Text(bootstrapper.writingFixAPIKeyMask ?? "API key saved")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Reset") {
                            isResettingAPIKey = true
                            apiKeyDraft = ""
                            apiKeyMessage = nil
                        }
                        .controlSize(.small)
                    } else {
                        SecureField("OpenAI API key", text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)

                        Button("Save") {
                            saveAPIKey()
                        }
                        .controlSize(.small)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if bootstrapper.hasWritingFixAPIKey {
                            Button("Cancel") {
                                isResettingAPIKey = false
                                apiKeyDraft = ""
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if let apiKeyMessage {
                    Text(apiKeyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(apiKeyMessageIsError ? Color.red : Color.green)
                }
            }
        }
    }

    private var cliSettings: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Command-line providers")
                    .font(.system(size: 13, weight: .semibold))

                Text("Codex CLI uses Luna with codex exec. Install and sign in to Codex separately; no API key is stored by Rewritely.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemPromptSettings: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("System prompt")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Save") {
                        bootstrapper.writingFixSystemPrompt = systemPromptDraft
                        systemPromptDraft = bootstrapper.writingFixSystemPrompt
                    }
                    .controlSize(.small)
                    .disabled(
                        systemPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                == bootstrapper.writingFixSystemPrompt
                    )
                }

                Text("Shared instructions for every Rewritely item. Add your writing style or skill instructions here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextEditor(text: $systemPromptDraft)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 130)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }
        }
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
            // Trigger row
            HStack(alignment: .center, spacing: 10) {
                Text(isEditing ? "Trigger word (optional)" : "Trigger")
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
                    HStack(spacing: 8) {
                        let trigger = triggerDraftBinding(for: rule.id).wrappedValue

                        if !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(trigger)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.accentColor.opacity(0.12))
                                )
                        }

                        if let shortcut = KeyboardShortcuts.getShortcut(for: rule.shortcutName) {
                            Text(shortcut.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.primary.opacity(0.07))
                                )
                        }
                    }
                }

                Spacer(minLength: 8)

                if isEditing {
                    Button("Save") {
                        if saveRule(id: rule.id) {
                            editingRuleID = nil
                            focusedTriggerID = nil
                        }
                    }
                    .controlSize(.small)

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

            // Shortcut recorder (editing mode only)
            if isEditing {
                HStack(alignment: .center, spacing: 10) {
                    Text("Shortcut")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)

                    KeyboardShortcuts.Recorder("", name: rule.shortcutName) { _ in
                        updateRuleValidation(for: rule.id)
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    Text("Provider")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)

                    Picker("", selection: providerDraftBinding(for: rule.id)) {
                        ForEach(WritingFixProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: rule.provider.iconName)
                        .font(.system(size: 10))
                    Text(rule.provider.title)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }

            // Prompt section
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

            if let validationError = ruleValidationErrors[rule.id] {
                Text(validationError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
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
                updateRuleValidation(for: ruleID)
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

    private func providerDraftBinding(for ruleID: UUID) -> Binding<WritingFixProvider> {
        Binding(
            get: {
                ruleDrafts[ruleID]?.provider
                    ?? bootstrapper.writingFixRules.first(where: { $0.id == ruleID })?.provider
                    ?? .appleIntelligence
            },
            set: { newValue in
                guard var draft = ruleDrafts[ruleID] else { return }
                draft.provider = newValue
                ruleDrafts[ruleID] = draft
            }
        )
    }

    private func addNewRule() {
        let newRule = WritingFixRule(
            trigger: "",
            prompt: "{{text}}"
        )
        pendingRule = newRule
        ruleDrafts[newRule.id] = WritingFixRuleDraft(
            trigger: newRule.trigger,
            prompt: newRule.prompt,
            provider: newRule.provider
        )
        editingRuleID = newRule.id
        focusedTriggerID = newRule.id
    }

    private func deleteRule(id: UUID) {
        if pendingRule?.id == id {
            pendingRule = nil
            KeyboardShortcuts.setShortcut(nil, for: .writingFix(ruleID: id))
        } else {
            bootstrapper.writingFixRules.removeAll { $0.id == id }
            KeyboardShortcuts.setShortcut(nil, for: .writingFix(ruleID: id))
        }
        ruleDrafts[id] = nil
        ruleValidationErrors[id] = nil
        if editingRuleID == id { editingRuleID = nil }
        if focusedTriggerID == id { focusedTriggerID = nil }
    }

    private func syncRuleDrafts() {
        var validRuleIDs = Set(bootstrapper.writingFixRules.map(\.id))
        if let pendingRule {
            validRuleIDs.insert(pendingRule.id)
        }
        ruleDrafts = ruleDrafts.filter { validRuleIDs.contains($0.key) }

        for rule in bootstrapper.writingFixRules where ruleDrafts[rule.id] == nil {
            ruleDrafts[rule.id] = WritingFixRuleDraft(
                trigger: rule.trigger,
                prompt: rule.prompt,
                provider: rule.provider
            )
        }
    }

    private func saveRule(id: UUID) -> Bool {
        guard let draft = ruleDrafts[id] else { return false }
        guard isRuleValid(id: id, trigger: draft.trigger) else {
            ruleValidationErrors[id] = "Add a trigger word or keyboard shortcut."
            return false
        }

        let updatedRule = WritingFixRule(
            id: id,
            trigger: draft.trigger,
            prompt: draft.prompt,
            provider: draft.provider
        )

        if pendingRule?.id == id {
            bootstrapper.writingFixRules.append(updatedRule)
            pendingRule = nil
        } else {
            guard let index = bootstrapper.writingFixRules.firstIndex(where: { $0.id == id }) else {
                return false
            }
            var updatedRules = bootstrapper.writingFixRules
            updatedRules[index] = updatedRule
            bootstrapper.writingFixRules = updatedRules
        }

        ruleValidationErrors[id] = nil
        return true
    }

    private func resetRuleDraft(id: UUID) {
        if pendingRule?.id == id {
            deleteRule(id: id)
            return
        }
        guard let rule = bootstrapper.writingFixRules.first(where: { $0.id == id }) else { return }
        ruleDrafts[id] = WritingFixRuleDraft(
            trigger: rule.trigger,
            prompt: rule.prompt,
            provider: rule.provider
        )
    }

    private func updateRuleValidation(for id: UUID) {
        let trigger = ruleDrafts[id]?.trigger ?? ""
        if isRuleValid(id: id, trigger: trigger) {
            ruleValidationErrors[id] = nil
        } else {
            ruleValidationErrors[id] = "Add a trigger word or keyboard shortcut."
        }
    }

    private func isRuleValid(id: UUID, trigger: String) -> Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || KeyboardShortcuts.getShortcut(for: .writingFix(ruleID: id)) != nil
    }

    private func saveAPIKey() {
        do {
            try bootstrapper.saveWritingFixAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            isResettingAPIKey = false
            apiKeyMessage = "Saved in Keychain."
            apiKeyMessageIsError = false
        } catch {
            apiKeyMessage = error.localizedDescription
            apiKeyMessageIsError = true
        }
    }

}
