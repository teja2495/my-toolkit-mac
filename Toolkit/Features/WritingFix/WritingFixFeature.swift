import AppKit
import Foundation

@MainActor
final class WritingFixFeature: AppFeature {
    let id = "writing-fix"
    var rules: [WritingFixRule] = [] {
        didSet {
            guard isStarted else { return }
            let oldIDs = Set(oldValue.map(\.id))
            for rule in rules where !oldIDs.contains(rule.id) {
                registerShortcutHandler(for: rule)
            }
            updateAutomaticTriggerMonitoring()
        }
    }
    var systemPrompt = ""

    private let resolver = FocusedTextInputResolver()
    private let corrector = GrammarTypoCorrector()
    private let keyboardBuffer = KeyboardTextBuffer.shared

    private var pollTimer: Timer?
    private var isKeyboardBufferStarted = false
    private var isStarted = false
    private var isFixing = false

    private struct RewriteDisplay {
        let originalText: String
        let replacementRange: Range<String.Index>

        func statusText(for text: String, failed: Bool = false) -> String {
            let title = failed ? "Rewriting failed..." : "Rewriting..."
            return originalText.replacingCharacters(in: replacementRange, with: "\(title)\n\(text)")
        }

        func completedText(with rewrittenText: String) -> String {
            originalText.replacingCharacters(in: replacementRange, with: rewrittenText)
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        updateAutomaticTriggerMonitoring()

        for rule in rules {
            registerShortcutHandler(for: rule)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        pollTimer?.invalidate()
        pollTimer = nil
        if isKeyboardBufferStarted {
            keyboardBuffer.stop()
            isKeyboardBufferStarted = false
        }
        isFixing = false
    }

    private func updateAutomaticTriggerMonitoring() {
        let needsMonitoring = rules.contains {
            !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard needsMonitoring else {
            pollTimer?.invalidate()
            pollTimer = nil
            if isKeyboardBufferStarted {
                keyboardBuffer.stop()
                isKeyboardBufferStarted = false
            }
            return
        }

        if !isKeyboardBufferStarted {
            keyboardBuffer.start()
            isKeyboardBufferStarted = true
        }
        guard pollTimer == nil else { return }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.updateFocusedInput()
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
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
        let input = resolver.focusedTextInput()

        let selected = input.flatMap { resolver.selectedText(in: $0) }
        let hasSelection = selected.map { !$0.isEmpty } ?? false

        let textToFix: String

        if hasSelection, let sel = selected {
            textToFix = sel
        } else if let input, let full = resolver.text(in: input), !full.isEmpty {
            textToFix = full
        } else if let full = await resolver.focusedTextByCopying() {
            textToFix = full
        } else {
            return
        }

        isFixing = true

        let display = shortcutDisplay(for: input, selectedText: textToFix)
        show(display.statusText(for: textToFix), in: input)

        do {
            let corrected = try await corrector.correctedText(
                for: textToFix,
                promptTemplate: rule.prompt,
                provider: rule.provider,
                systemPrompt: systemPrompt
            )
            show(display.completedText(with: corrected), in: input)
        } catch {
            show(display.statusText(for: textToFix, failed: true), in: input)
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

        let display = triggerDisplay(for: originalText, match: match)
        show(display.statusText(for: match.textToFix), in: input)

        do {
            let correctedText = try await corrector.correctedText(
                for: match.textToFix,
                promptTemplate: match.rule.prompt,
                provider: match.rule.provider,
                systemPrompt: systemPrompt
            )
            show(display.completedText(with: correctedText), in: input)
        } catch {
            show(display.statusText(for: match.textToFix, failed: true), in: input)
            NSLog("Writing fix failed: %@", error.localizedDescription)
        }

        isFixing = false
    }

    private func shortcutDisplay(for input: FocusedTextInput?, selectedText: String) -> RewriteDisplay {
        guard
            let input,
            let fullText = resolver.text(in: input),
            let selectedRange = resolver.selectedRange(in: input, text: fullText),
            !selectedRange.isEmpty
        else {
            return RewriteDisplay(
                originalText: selectedText,
                replacementRange: selectedText.startIndex..<selectedText.endIndex
            )
        }

        return RewriteDisplay(originalText: fullText, replacementRange: selectedRange)
    }

    private func triggerDisplay(
        for originalText: String,
        match: (rule: WritingFixRule, textToFix: String, suffixLength: Int)
    ) -> RewriteDisplay {
        let suffixStart = originalText.index(
            originalText.endIndex,
            offsetBy: -min(match.suffixLength, originalText.count)
        )
        return RewriteDisplay(
            originalText: originalText,
            replacementRange: suffixStart..<originalText.endIndex
        )
    }

    private func show(_ text: String, in input: FocusedTextInput?) {
        if let input {
            _ = resolver.replaceText(in: input, with: text)
        } else {
            _ = resolver.replaceFocusedText(with: text)
        }
        keyboardBuffer.replaceLine(with: text)
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
