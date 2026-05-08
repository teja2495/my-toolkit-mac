import Foundation

extension KeyboardShortcuts.Name {
    static func writingFix(ruleID: UUID) -> Self {
        .init("writingFix-\(ruleID.uuidString)")
    }
}

struct WritingFixRule: Identifiable, Codable, Equatable {
    var id: UUID
    var trigger: String
    var prompt: String

    init(id: UUID = UUID(), trigger: String, prompt: String) {
        self.id = id
        self.trigger = trigger
        self.prompt = prompt
    }

    var shortcutName: KeyboardShortcuts.Name { .writingFix(ruleID: id) }
}
