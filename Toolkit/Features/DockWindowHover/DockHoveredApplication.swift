import Foundation

struct DockHoveredApplication: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let bundleURL: URL?
    let displayName: String
    let dockItemFrame: CGRect

    static func == (lhs: DockHoveredApplication, rhs: DockHoveredApplication) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier
            && lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}

/// Editors that share the VS Code project popup (folder search, pins, git actions).
/// Projects open in whichever editor's Dock icon was hovered.
enum ProjectEditorBundle {
    static let identifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
    ]

    static func contains(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return identifiers.contains(bundleIdentifier)
    }
}
