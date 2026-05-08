import AppKit
import Foundation

@MainActor
final class WritingFixFeature: AppFeature {
    let id = "writing-fix"
    var rules: [WritingFixRule] = []

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
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        keyboardBuffer.stop()
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
