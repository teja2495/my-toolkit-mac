import AppKit
import Foundation

@MainActor
final class TextExpanderFeature: AppFeature {
    let id = "text-expander"
    var entries: [TextExpanderEntry] = []

    private let resolver = FocusedTextInputResolver()
    private let keyboardBuffer = KeyboardTextBuffer.shared
    private var pollTimer: Timer?
    private var isExpanding = false

    func start() {
        guard pollTimer == nil else { return }
        keyboardBuffer.start()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkAndExpand()
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
        isExpanding = false
    }

    private func checkAndExpand() {
        guard !isExpanding else { return }
        let input = resolver.focusedTextInput()
        let text = input.flatMap { resolver.text(in: $0) } ?? keyboardBuffer.currentLine
        guard let match = matchedEntry(in: text) else { return }

        isExpanding = true
        let replacement = match.entry.expansion + " "
        if let input, resolver.text(in: input) != nil {
            _ = resolver.replaceSuffix(in: input, suffixLength: match.triggerLength, with: replacement)
        } else {
            _ = resolver.replaceFocusedSuffix(suffixLength: match.triggerLength, with: replacement)
        }
        keyboardBuffer.replaceSuffix(length: match.triggerLength, with: replacement)
        isExpanding = false
    }

    private func matchedEntry(in text: String) -> (entry: TextExpanderEntry, triggerLength: Int)? {
        let candidates = entries
            .filter { !$0.shortcut.isEmpty && !$0.expansion.isEmpty }
            .sorted { $0.shortcut.count > $1.shortcut.count }

        for candidate in candidates {
            let trigger = candidate.shortcut + " "
            guard text.hasSuffix(trigger) else { continue }

            let prefix = String(text.dropLast(trigger.count))
            // Word-boundary check: the shortcut must start at the beginning of text
            // or be preceded by whitespace/punctuation to avoid partial-word matches.
            guard prefix.isEmpty || isWordBoundary(prefix.last!) else { continue }

            return (candidate, trigger.count)
        }

        return nil
    }

    private func isWordBoundary(_ char: Character) -> Bool {
        char.isWhitespace || char.isPunctuation
    }
}
