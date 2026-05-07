import Foundation

struct WritingFixRule: Identifiable, Codable, Equatable {
    var id: UUID
    var trigger: String
    var prompt: String

    init(id: UUID = UUID(), trigger: String, prompt: String) {
        self.id = id
        self.trigger = trigger
        self.prompt = prompt
    }
}
