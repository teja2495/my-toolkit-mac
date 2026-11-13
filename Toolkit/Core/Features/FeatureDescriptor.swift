import Foundation

struct FeatureDescriptor: Identifiable {
    let id: String
    let title: String
    let summary: String
    let requiresAccessibilityAccess: Bool
    var isEnabled: Bool
    var requiresScreenRecordingAccess: Bool = false
    /// SF Symbol shown in the sidebar and on the feature's settings page.
    var systemImage: String = "square.grid.2x2"
}
