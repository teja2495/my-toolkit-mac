import Foundation

enum MouseButtonAction: String, CaseIterable, Identifiable, Codable {
    case systemDefault
    case copy
    case paste
    case playPause
    case missionControl
    case quitAndReopen

    /// Actions offered for a single click.
    static let singleClickActions: [MouseButtonAction] = [.systemDefault, .copy, .paste, .playPause, .missionControl]
    /// Actions offered for a double click.
    static let doubleClickActions: [MouseButtonAction] = singleClickActions + [.quitAndReopen]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemDefault: return "Default"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .playPause: return "Play / Pause Media"
        case .missionControl: return "Mission Control"
        case .quitAndReopen: return "Quit and Reopen"
        }
    }
}

enum OpenLogiButton: String, CaseIterable, Identifiable {
    case front
    case back
    case scrollWheel
    case middle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .front: return "Front button"
        case .back: return "Back button"
        case .scrollWheel: return "Scroll wheel button"
        case .middle: return "Middle button"
        }
    }

    var description: String {
        switch self {
        case .front: return "Front side button."
        case .back: return "Back side button."
        case .scrollWheel: return "Scroll wheel click."
        case .middle: return "Button near the scroll wheel."
        }
    }

    /// CGEvent mouse button number, or nil for buttons only reachable over HID++.
    var buttonNumber: Int64? {
        switch self {
        case .front: return 4
        case .back: return 3
        case .scrollWheel: return 2
        case .middle: return nil
        }
    }

    init?(buttonNumber: Int64) {
        guard let match = Self.allCases.first(where: { $0.buttonNumber == buttonNumber }) else { return nil }
        self = match
    }
}
