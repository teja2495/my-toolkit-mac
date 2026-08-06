import Foundation

enum WritingFixProvider: String, Codable, CaseIterable, Identifiable {
    case appleIntelligence
    case chatGPT
    case codexCLI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleIntelligence:
            return "Apple Intelligence"
        case .chatGPT:
            return "ChatGPT"
        case .codexCLI:
            return "Codex CLI"
        }
    }

    var iconName: String {
        switch self {
        case .appleIntelligence:
            return "apple.intelligence"
        case .chatGPT:
            return "bubble.left.and.bubble.right"
        case .codexCLI:
            return "chevron.left.forwardslash.chevron.right"
        }
    }
}

extension KeyboardShortcuts.Name {
    static func writingFix(ruleID: UUID) -> Self {
        .init("writingFix-\(ruleID.uuidString)")
    }
}

struct WritingFixRule: Identifiable, Codable, Equatable {
    var id: UUID
    var trigger: String
    var prompt: String
    var provider: WritingFixProvider

    init(
        id: UUID = UUID(),
        trigger: String,
        prompt: String,
        provider: WritingFixProvider = .appleIntelligence
    ) {
        self.id = id
        self.trigger = trigger
        self.prompt = prompt
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case trigger
        case prompt
        case provider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        trigger = try container.decode(String.self, forKey: .trigger)
        prompt = try container.decode(String.self, forKey: .prompt)
        provider = try container.decodeIfPresent(WritingFixProvider.self, forKey: .provider)
            ?? .appleIntelligence
    }

    var shortcutName: KeyboardShortcuts.Name { .writingFix(ruleID: id) }
}
