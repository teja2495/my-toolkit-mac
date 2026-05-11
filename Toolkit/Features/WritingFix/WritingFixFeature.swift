import AppKit
import Foundation

@MainActor
final class WritingFixFeature: AppFeature {
    let id = "writing-fix"
    var rules: [WritingFixRule] = [] {
        didSet {
            guard pollTimer != nil else { return }
            let oldIDs = Set(oldValue.map(\.id))
            for rule in rules where !oldIDs.contains(rule.id) {
                registerShortcutHandler(for: rule)
            }
        }
    }

    private let resolver = FocusedTextInputResolver()
    private let corrector = GrammarTypoCorrector()
    private let keyboardBuffer = KeyboardTextBuffer.shared

    private var pollTimer: Timer?
    private var isFixing = false

    func start() {
        guard pollTimer == nil else { return }
        keyboardBuffer.start()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.updateFocusedInput()
            }
        }

        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }

        for rule in rules {
            registerShortcutHandler(for: rule)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        keyboardBuffer.stop()
        isFixing = false
    }

    private func registerShortcutHandler(for rule: WritingFixRule) {
        let ruleID = rule.id
        KeyboardShortcuts.onKeyDown(for: rule.shortcutName) { [weak self] in
            Task { @MainActor in
                guard let self,
                      let currentRule = self.rules.first(where: { $0.id == ruleID })
                else { return }
                await self.triggerFixViaShortcut(for: currentRule)
            }
        }
    }

    private func triggerFixViaShortcut(for rule: WritingFixRule) async {
        guard !isFixing else { return }
        guard let input = resolver.focusedTextInput() else { return }

        let selected = resolver.selectedText(in: input)
        let hasSelection = selected.map { !$0.isEmpty } ?? false

        let textToFix: String
        let useSelection: Bool

        if hasSelection, let sel = selected {
            textToFix = sel
            useSelection = true
        } else if let full = resolver.text(in: input), !full.isEmpty {
            textToFix = full
            useSelection = false
        } else {
            return
        }

        isFixing = true

        do {
            let corrected = try await corrector.correctedText(for: textToFix, promptTemplate: rule.prompt)
            if useSelection {
                _ = resolver.replaceSelectedText(in: input, with: corrected)
            } else {
                _ = resolver.replaceText(in: input, with: corrected)
            }
            keyboardBuffer.replaceLine(with: corrected)
        } catch {
            NSLog("Writing fix shortcut failed: %@", error.localizedDescription)
        }

        isFixing = false
    }

    private func updateFocusedInput() async {
        guard !isFixing else { return }
        let input = resolver.focusedTextInput()
        let axText = input.flatMap { resolver.text(in: $0) }
        let originalText = axText ?? keyboardBuffer.currentLine
        guard let match = matchedRule(in: originalText, usesKeyboardReplacement: axText == nil),
              !match.textToFix.isEmpty
        else { return }

        isFixing = true

        do {
            let correctedText = try await corrector.correctedText(
                for: match.textToFix,
                promptTemplate: match.rule.prompt
            )
            if let input, input.canSetValue {
                _ = resolver.replaceText(in: input, with: correctedText)
                keyboardBuffer.replaceLine(with: correctedText)
            } else if let input {
                _ = resolver.replaceSuffix(in: input, suffixLength: match.suffixLength, with: correctedText)
                keyboardBuffer.replaceLine(with: correctedText)
            } else {
                _ = resolver.replaceFocusedSuffix(suffixLength: match.suffixLength, with: correctedText)
                keyboardBuffer.replaceLine(with: correctedText)
            }
        } catch {
            NSLog("Writing fix failed: %@", error.localizedDescription)
        }

        isFixing = false
    }

    private func matchedRule(
        in text: String,
        usesKeyboardReplacement: Bool
    ) -> (rule: WritingFixRule, textToFix: String, suffixLength: Int)? {
        let searchableText: String
        if usesKeyboardReplacement, let lineStart = text.lastIndex(of: "\n") {
            searchableText = String(text[text.index(after: lineStart)...])
        } else {
            searchableText = text
        }

        let candidates = rules
            .map { rule in
                let normalizedTrigger = rule.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                return (rule: rule, trigger: normalizedTrigger)
            }
            .filter { !$0.trigger.isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }

        for candidate in candidates where searchableText.hasSuffix(candidate.trigger) {
            let fixedText = String(searchableText.dropLast(candidate.trigger.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (candidate.rule, fixedText, searchableText.count)
        }

        return nil
    }
}
