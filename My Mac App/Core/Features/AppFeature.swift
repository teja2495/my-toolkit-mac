import Foundation

@MainActor
protocol AppFeature: AnyObject {
    var id: String { get }
    func start()
    func stop()
}
