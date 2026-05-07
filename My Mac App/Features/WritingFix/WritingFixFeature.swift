import AppKit
import Foundation

@MainActor
final class WritingFixFeature: AppFeature {
    let id = "writing-fix"
    var rules: [WritingFixRule] = []

    private let resolver = FocusedTextInputResolver()
    private let corrector = GrammarTypoCorrector()

    private var pollTimer: Timer?
    private var isFixing = false

    func start() {
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

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isFixing = false
    }

    private func updateFocusedInput() async {
        guard !isFixing else { return }
        guard let input = resolver.focusedTextInput() else { return }
        guard let originalText = resolver.text(in: input),
              let match = matchedRule(in: originalText),
              !match.textToFix.isEmpty
        else { return }

        isFixing = true

        do {
            let correctedText = try await corrector.correctedText(
                for: match.textToFix,
                promptTemplate: match.rule.prompt
            )
            _ = resolver.replaceText(in: input, with: correctedText)
        } catch {
            NSLog("Writing fix failed: %@", error.localizedDescription)
        }

        isFixing = false
    }

    private func matchedRule(in text: String) -> (rule: WritingFixRule, textToFix: String)? {
        let candidates = rules
            .map { rule in
                let normalizedTrigger = rule.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                return (rule: rule, trigger: normalizedTrigger)
            }
            .filter { !$0.trigger.isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }

        for candidate in candidates where text.hasSuffix(candidate.trigger) {
            let fixedText = String(text.dropLast(candidate.trigger.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            return (candidate.rule, fixedText)
        }

        return nil
    }
}
