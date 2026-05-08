import AppKit
import Foundation

@MainActor
final class KeyboardTextBuffer {
    static let shared = KeyboardTextBuffer()

    private var monitor: Any?
    private var retainCount = 0
    private var line = ""
    private let maxLength = 512

    var currentLine: String {
        line
    }

    func start() {
        retainCount += 1
        guard monitor == nil else { return }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.record(event)
            }
        }
    }

    func stop() {
        retainCount = max(0, retainCount - 1)
        guard retainCount == 0, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        line = ""
    }

    func replaceSuffix(length: Int, with replacement: String) {
        guard length >= 0, length <= line.count else { return }
        line = String(line.dropLast(length)) + replacement
        trimIfNeeded()
    }

    func replaceLine(with replacement: String) {
        line = replacement
        trimIfNeeded()
    }

    private func record(_ event: NSEvent) {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else { return }

        switch event.keyCode {
        case 36, 53:
            line = ""
            return
        case 51:
            if !line.isEmpty {
                line.removeLast()
            }
            return
        case 123, 124, 125, 126:
            line = ""
            return
        default:
            break
        }

        guard let characters = event.characters, !characters.isEmpty else { return }
        guard characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }

        line += characters
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        if line.count > maxLength {
            line = String(line.suffix(maxLength))
        }
    }
}
