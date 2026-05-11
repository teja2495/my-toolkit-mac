import Foundation

struct DockHoveredApplication: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let displayName: String
    let dockItemFrame: CGRect

    static func == (lhs: DockHoveredApplication, rhs: DockHoveredApplication) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier
    }
}
