//
//  ContentView.swift
//  My Mac App
//
//  Created by Teja Karlapudi on 4/28/26.
//

import SwiftUI

struct ContentView: View {
    private struct WritingFixRuleDraft {
        var trigger: String
        var prompt: String
    }

    @ObservedObject var bootstrapper: AppBootstrapper
    @State private var editingWritingFixRuleID: UUID?
    @State private var writingFixRuleDrafts: [UUID: WritingFixRuleDraft] = [:]
    @FocusState private var focusedWritingFixTriggerID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Text("My Mac App")
                        .font(.largeTitle)
                        .bold()

                    Spacer()

                    Button {
                        guard !bootstrapper.accessibilityPermissionManager.isTrusted else { return }
                        bootstrapper.requestAccessibilityAccess()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shield.fill")
                                .foregroundStyle(
                                    bootstrapper.accessibilityPermissionManager.isTrusted
                                        ? Color.green
                                        : Color.orange
                                )
                            if !bootstrapper.accessibilityPermissionManager.isTrusted {
                                Text("Grant Permission")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(
                        bootstrapper.accessibilityPermissionManager.isTrusted
                            ? "Accessibility permission granted"
                            : "Grant accessibility permission"
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Features")
                        .font(.title3)
                        .bold()

                    ForEach(bootstrapper.availableFeatures) { feature in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(feature.title)
                                        .font(.headline)
                                    Text(feature.summary)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle(isOn: Binding(
                                    get: { feature.isEnabled },
                                    set: { _ in bootstrapper.toggleFeature(id: feature.id) }
                                )) {
                                    EmptyView()
                                }
                                .toggleStyle(.switch)
                                .disabled(!bootstrapper.accessibilityPermissionManager.isTrusted && feature.requiresAccessibilityAccess)
                            }

                            if feature.id == "dock-window-hover", feature.isEnabled {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Popup delay")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(Int((bootstrapper.dockHoverPopupDelay * 1000).rounded())) ms")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }

                                    Slider(
                                        value: $bootstrapper.dockHoverPopupDelay,
                                        in: 0...1.5,
                                        step: 0.05
                                    )
                                }
                                .padding(.top, 8)
                            }

                            if feature.id == "writing-fix", feature.isEnabled {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(bootstrapper.writingFixRules) { rule in
                                        VStack(alignment: .leading, spacing: 4) {
                                            if editingWritingFixRuleID == rule.id {
                                                Text("Trigger")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)

                                                TextField("Enter trigger word", text: triggerDraftBinding(for: rule.id))
                                                    .textFieldStyle(.roundedBorder)
                                                    .font(.caption.monospaced())
                                                    .focused($focusedWritingFixTriggerID, equals: rule.id)
                                                    .onAppear {
                                                        focusedWritingFixTriggerID = rule.id
                                                    }

                                                Text("Prompt")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)

                                                TextEditor(text: promptDraftBinding(for: rule.id))
                                                    .font(.caption.monospaced())
                                                    .frame(minHeight: 90)
                                                    .padding(4)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 6)
                                                            .stroke(Color.secondary.opacity(0.25))
                                                    )

                                                Text("Use {{text}} to position the input text. If omitted, it is appended.")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                Text("Trigger")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Text(triggerDraftBinding(for: rule.id).wrappedValue)
                                                    .font(.caption.monospaced())
                                                    .frame(maxWidth: .infinity, alignment: .leading)

                                                Text("Prompt")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Text(promptDraftBinding(for: rule.id).wrappedValue)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(3)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }

                                            HStack {
                                                if editingWritingFixRuleID == rule.id {
                                                    Button("Save") {
                                                        saveRule(id: rule.id)
                                                        editingWritingFixRuleID = nil
                                                        focusedWritingFixTriggerID = nil
                                                    }
                                                    .disabled(!isRuleDirty(rule))

                                                    Button("Cancel") {
                                                        resetRuleDraft(id: rule.id)
                                                        editingWritingFixRuleID = nil
                                                        focusedWritingFixTriggerID = nil
                                                    }
                                                } else {
                                                    Button("Edit") {
                                                        editingWritingFixRuleID = rule.id
                                                        focusedWritingFixTriggerID = rule.id
                                                    }
                                                }

                                                Spacer()

                                                if bootstrapper.writingFixRules.count > 1 {
                                                    Button(role: .destructive) {
                                                        deleteWritingFixRule(id: rule.id)
                                                    } label: {
                                                        Image(systemName: "trash")
                                                            .font(.caption)
                                                    }
                                                    .buttonStyle(.plain)
                                                    .help("Remove custom trigger")
                                                }
                                            }
                                        }
                                        .padding(8)
                                        .background(Color.secondary.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }

                                    Button {
                                        let newRule = WritingFixRule(
                                            trigger: "newfix",
                                            prompt: GrammarTypoCorrector.defaultPromptTemplate
                                        )
                                        bootstrapper.writingFixRules.append(newRule)
                                        writingFixRuleDrafts[newRule.id] = WritingFixRuleDraft(
                                            trigger: newRule.trigger,
                                            prompt: newRule.prompt
                                        )
                                        editingWritingFixRuleID = newRule.id
                                        focusedWritingFixTriggerID = newRule.id
                                    } label: {
                                        Label("Add custom prompt/trigger", systemImage: "plus")
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.top, 8)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .onAppear {
            syncWritingFixRuleDrafts()
        }
        .onChange(of: bootstrapper.writingFixRules) {
            syncWritingFixRuleDrafts()
        }
    }

    private func triggerDraftBinding(for ruleID: UUID) -> Binding<String> {
        Binding(
            get: {
                writingFixRuleDrafts[ruleID]?.trigger
                    ?? bootstrapper.writingFixRules.first(where: { $0.id == ruleID })?.trigger
                    ?? ""
            },
            set: { newValue in
                guard var draft = writingFixRuleDrafts[ruleID] else { return }
                draft.trigger = newValue
                writingFixRuleDrafts[ruleID] = draft
            }
        )
    }

    private func promptDraftBinding(for ruleID: UUID) -> Binding<String> {
        Binding(
            get: {
                writingFixRuleDrafts[ruleID]?.prompt
                    ?? bootstrapper.writingFixRules.first(where: { $0.id == ruleID })?.prompt
                    ?? ""
            },
            set: { newValue in
                guard var draft = writingFixRuleDrafts[ruleID] else { return }
                draft.prompt = newValue
                writingFixRuleDrafts[ruleID] = draft
            }
        )
    }

    private func deleteWritingFixRule(id: UUID) {
        bootstrapper.writingFixRules.removeAll { $0.id == id }
        writingFixRuleDrafts[id] = nil
        if editingWritingFixRuleID == id {
            editingWritingFixRuleID = nil
        }
        if focusedWritingFixTriggerID == id {
            focusedWritingFixTriggerID = nil
        }
    }

    private func syncWritingFixRuleDrafts() {
        let validRuleIDs = Set(bootstrapper.writingFixRules.map(\.id))
        writingFixRuleDrafts = writingFixRuleDrafts.filter { validRuleIDs.contains($0.key) }

        for rule in bootstrapper.writingFixRules where writingFixRuleDrafts[rule.id] == nil {
            writingFixRuleDrafts[rule.id] = WritingFixRuleDraft(
                trigger: rule.trigger,
                prompt: rule.prompt
            )
        }
    }

    private func isRuleDirty(_ rule: WritingFixRule) -> Bool {
        guard let draft = writingFixRuleDrafts[rule.id] else { return false }
        return draft.trigger != rule.trigger || draft.prompt != rule.prompt
    }

    private func saveRule(id: UUID) {
        guard let draft = writingFixRuleDrafts[id] else { return }
        guard let index = bootstrapper.writingFixRules.firstIndex(where: { $0.id == id }) else { return }
        bootstrapper.writingFixRules[index].trigger = draft.trigger
        bootstrapper.writingFixRules[index].prompt = draft.prompt
    }

    private func resetRuleDraft(id: UUID) {
        guard let rule = bootstrapper.writingFixRules.first(where: { $0.id == id }) else { return }
        writingFixRuleDrafts[id] = WritingFixRuleDraft(trigger: rule.trigger, prompt: rule.prompt)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(bootstrapper: AppBootstrapper())
    }
}
