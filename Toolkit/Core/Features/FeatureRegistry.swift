import Foundation

@MainActor
final class FeatureRegistry {
    private let features: [AppFeature]

    init(features: [AppFeature]) {
        self.features = features
    }

    func startAll() {
        features.forEach { $0.start() }
    }

    func stopAll() {
        features.forEach { $0.stop() }
    }
}
