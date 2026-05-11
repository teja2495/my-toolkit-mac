import Combine
import Foundation

struct CornerTodoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var isCompleted: Bool

    init(id: UUID = UUID(), title: String, isCompleted: Bool = false) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
    }
}

@MainActor
final class CornerNotesStore: ObservableObject {
    @Published var todos: [CornerTodoItem] {
        didSet { saveTodos() }
    }

    @Published var note: String {
        didSet { UserDefaults.standard.set(note, forKey: Self.noteKey) }
    }

    private static let todosKey = "cornerNotesTodos"
    private static let noteKey = "cornerNotesNote"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.todosKey),
           let decodedTodos = try? JSONDecoder().decode([CornerTodoItem].self, from: data) {
            todos = decodedTodos
        } else {
            todos = []
        }

        note = UserDefaults.standard.string(forKey: Self.noteKey) ?? ""
    }

    func addTodo(title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        todos.append(CornerTodoItem(title: trimmedTitle))
    }

    func deleteTodo(id: CornerTodoItem.ID) {
        todos.removeAll { $0.id == id }
    }

    func toggleTodo(id: CornerTodoItem.ID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].isCompleted.toggle()
    }

    private func saveTodos() {
        guard let data = try? JSONEncoder().encode(todos) else { return }
        UserDefaults.standard.set(data, forKey: Self.todosKey)
    }
}
