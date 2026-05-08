import Foundation

enum SettingsSection: Hashable, Identifiable {
    case feature(String)
    case permissions
    case about

    var id: String {
        switch self {
        case .feature(let id): return "feature.\(id)"
        case .permissions: return "permissions"
        case .about: return "about"
        }
    }
}
