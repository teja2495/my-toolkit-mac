import Foundation

struct TextExpanderEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var shortcut: String
    var expansion: String
}
