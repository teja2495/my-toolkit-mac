import SwiftUI

struct StatusDot: View {
    enum State {
        case active
        case inactive
        case warning
    }

    let state: State

    private var color: Color {
        switch state {
        case .active: return Color.green
        case .inactive: return Color.secondary.opacity(0.45)
        case .warning: return Color.orange
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 3)
                    .blur(radius: 0.5)
                    .opacity(state == .active ? 1 : 0)
            )
    }
}
