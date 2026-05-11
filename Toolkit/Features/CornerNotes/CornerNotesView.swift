import AppKit
import SwiftUI

struct CornerNotesView: View {
    @ObservedObject var store: CornerNotesStore
    let onPinToggle: (Bool) -> Void
    let onClose: () -> Void

    @AppStorage("cornerNotesFontSize") private var fontSize: Double = 14
    @AppStorage("cornerNotesPinned") private var isPinned: Bool = false

    @State private var newTodoTitle = ""
    @State private var hoveredTodoID: UUID?
    @State private var addHovered = false
    @FocusState private var inputFocused: Bool

    private static let amber = Color(red: 0.93, green: 0.62, blue: 0.27)

    var body: some View {
        ZStack {
            backgroundLayer

            HStack(spacing: 0) {
                checklistPane
                    .frame(minWidth: 290, idealWidth: 330, maxWidth: 380)

                divider

                notePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 380)
        .background(fontSizeShortcuts)
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            pinButton
        }
        .onAppear {
            onPinToggle(isPinned)
        }
    }

    private var pinButton: some View {
        Button(action: {
            isPinned.toggle()
            onPinToggle(isPinned)
        }) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isPinned ? Self.amber : Color.secondary.opacity(0.45))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isPinned ? 0.08 : 0.0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin window" : "Keep window on top")
        .padding(.top, 14)
        .padding(.trailing, 14)
        .animation(.easeInOut(duration: 0.15), value: isPinned)
    }

    private var fontSizeShortcuts: some View {
        Group {
            Button("") { fontSize = min(fontSize + 1, 28) }
                .keyboardShortcut("=", modifiers: [.command, .shift])
            Button("") { fontSize = max(fontSize - 1, 10) }
                .keyboardShortcut("-", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    // MARK: - Background

    private static let darkBackground = Color(red: 0.118, green: 0.118, blue: 0.125)

    private var backgroundLayer: some View {
        Self.darkBackground.ignoresSafeArea()
    }

    // MARK: - Checklist pane

    private var checklistPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            checklistHeader
                .padding(.horizontal, 26)
                .padding(.top, 26)
                .padding(.bottom, 18)

            inputRow
                .padding(.horizontal, 22)
                .padding(.bottom, 14)

            ZStack {
                if store.todos.isEmpty {
                    emptyTodoState
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    todoList
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.28), value: store.todos.isEmpty)

        }
        .background(Color.black.opacity(0.12))
    }

    private var checklistHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(.primary)

                Spacer()
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 0) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(inputFocused ? Self.amber : .secondary.opacity(0.55))
                .padding(.leading, 14)
                .padding(.trailing, 8)

            TextField(
                "",
                text: $newTodoTitle,
                prompt: Text("New task")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary.opacity(0.55))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($inputFocused)
            .onSubmit(addTodo)
            .padding(.vertical, 11)

            if !newTodoTitle.isEmpty {
                Button(action: addTodo) {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Self.amber)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(Self.amber.opacity(addHovered ? 0.28 : 0.18))
                        )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .onHover { addHovered = $0 }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            inputFocused ? Self.amber.opacity(0.55) : Color.primary.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
        .animation(.easeInOut(duration: 0.18), value: inputFocused)
        .animation(.snappy, value: newTodoTitle.isEmpty)
    }

    private var emptyTodoState: some View {
        VStack(spacing: 14) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Self.amber.opacity(0.10))
                    .frame(width: 56, height: 56)
                Image(systemName: "leaf")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Self.amber.opacity(0.85))
            }

            VStack(spacing: 4) {
                Text("A clear slate.")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .italic()
                    .foregroundStyle(.primary.opacity(0.85))

                Text("What deserves your attention?")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary.opacity(0.85))
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var todoList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.todos) { todo in
                    todoRow(for: todo)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(OverlayScrollSetter())
        }
        .scrollContentBackground(.hidden)
    }

    private func todoRow(for todo: CornerTodoItem) -> some View {
        TodoRow(
            todo: todo,
            accent: Self.amber,
            fontSize: fontSize,
            isHovered: hoveredTodoID == todo.id,
            onToggle: { toggleTodo(id: todo.id) },
            onDelete: { deleteTodo(id: todo.id) }
        )
        .onHover { hovering in
            if hovering {
                hoveredTodoID = todo.id
            } else if hoveredTodoID == todo.id {
                hoveredTodoID = nil
            }
        }
    }

    private func toggleTodo(id: UUID) {
        withAnimation(.smooth(duration: 0.22)) {
            store.toggleTodo(id: id)
        }
    }

    private func deleteTodo(id: UUID) {
        withAnimation(.snappy) {
            store.deleteTodo(id: id)
        }
    }

    // MARK: - Note pane

    private var notePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            noteHeader
                .padding(.horizontal, 34)
                .padding(.top, 26)
                .padding(.bottom, 18)

            ZStack(alignment: .topLeading) {
                if store.note.isEmpty {
                    Text("Begin writing…")
                        .font(.system(size: fontSize).italic())
                        .foregroundStyle(.secondary.opacity(0.45))
                        .padding(.horizontal, 38)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }

                CornerTextEditor(text: $store.note, fontSize: fontSize, lineSpacing: 7)
                    .padding(.bottom, 8)
            }

        }
    }

    private var noteHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Note")
                .font(.system(size: 30, weight: .semibold, design: .serif))

            Spacer()
        }
    }

    // MARK: - Divider

    private var divider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.0),
                        Color.primary.opacity(0.10),
                        Color.primary.opacity(0.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1)
    }

    // MARK: - Helpers

    private func addTodo() {
        let trimmed = newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.snappy(duration: 0.25)) {
            store.addTodo(title: trimmed)
        }
        newTodoTitle = ""
    }
}

// MARK: - Todo Row

private struct TodoRow: View {
    let todo: CornerTodoItem
    let accent: Color
    let fontSize: Double
    let isHovered: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            todo.isCompleted ? accent : Color.secondary.opacity(0.45),
                            lineWidth: 1.5
                        )
                        .frame(width: 18, height: 18)

                    Circle()
                        .fill(accent)
                        .frame(width: 18, height: 18)
                        .scaleEffect(todo.isCompleted ? 1 : 0.001)
                        .opacity(todo.isCompleted ? 1 : 0)

                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(todo.isCompleted ? 1 : 0)
                        .scaleEffect(todo.isCompleted ? 1 : 0.5)
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.65), value: todo.isCompleted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(todo.title)
                .font(.system(size: fontSize))
                .foregroundStyle(todo.isCompleted ? Color.secondary.opacity(0.6) : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.smooth, value: todo.isCompleted)

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Delete")
                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - AppKit helpers

private struct CornerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let lineSpacing: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 32, height: 4)
        applyStyle(to: textView)
        textView.string = text
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            let sel = textView.selectedRange()
            textView.string = text
            let safeLoc = min(sel.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
        }
        if context.coordinator.lastFontSize != fontSize || context.coordinator.lastLineSpacing != lineSpacing {
            applyStyle(to: textView)
            context.coordinator.lastFontSize = fontSize
            context.coordinator.lastLineSpacing = lineSpacing
        }
    }

    private func applyStyle(to textView: NSTextView) {
        let font = NSFont.systemFont(ofSize: fontSize)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        textView.font = font
        textView.defaultParagraphStyle = style
        textView.typingAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.labelColor]
        if let storage = textView.textStorage, storage.length > 0 {
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: range)
            storage.addAttribute(.paragraphStyle, value: style, range: range)
            storage.endEditing()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CornerTextEditor
        var lastFontSize: Double = 0
        var lastLineSpacing: CGFloat = 0
        init(_ parent: CornerTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

private struct OverlayScrollSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguringView { ConfiguringView() }
    func updateNSView(_ nsView: ConfiguringView, context: Context) {}

    class ConfiguringView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configure()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        private func configure() {
            var v: NSView? = superview
            while let candidate = v {
                if let scrollView = candidate as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.autohidesScrollers = true
                    return
                }
                v = candidate.superview
            }
        }
    }
}

struct CornerNotesView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CornerNotesView(store: previewStore(), onPinToggle: { _ in }, onClose: {})
                .frame(width: 720, height: 440)
                .preferredColorScheme(.dark)

            CornerNotesView(store: previewStore(), onPinToggle: { _ in }, onClose: {})
                .frame(width: 720, height: 440)
                .preferredColorScheme(.light)
        }
    }

    @MainActor static func previewStore() -> CornerNotesStore {
        let store = CornerNotesStore()
        if store.todos.isEmpty {
            store.addTodo(title: "Draft proposal")
            store.addTodo(title: "Review pull requests")
            store.addTodo(title: "Email Anna about the launch")
        }
        return store
    }
}
