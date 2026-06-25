import Foundation

@MainActor
final class PhoneIntegrationFeature: AppFeature {
    let id = "phone-integration"
    let controller = PhoneBridgeController()

    func start() {
        controller.start()
    }

    func stop() {
        controller.stop()
    }
}
