import Foundation
import Network

enum PhoneBridgeProtocol {
    static let version = 1
    static let serviceType = "_tk-toolkit-phone._tcp"

    static let pairHello = "pair.hello"
    static let pairChallenge = "pair.challenge"
    static let pairDecision = "pair.decision"
    static let pairComplete = "pair.complete"
    static let error = "error"
    static let listFiles = "files.list"
    static let listFilesResult = "files.list.result"
}

struct PhoneTrustedDevice: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var publicKeyBase64: String
    var pairedAt: Date
    var lastSeenAt: Date
}

struct DiscoveredPhoneDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

struct PendingPhonePairing: Identifiable, Equatable {
    let id: String
    let deviceId: String
    let deviceName: String
    let verificationCode: String
}

enum PhoneConnectionState: Equatable {
    case idle
    case browsing
    case pairing
    case connected(String)
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .browsing: return "Looking for Android phones"
        case .pairing: return "Pairing"
        case .connected(let name): return "Connected to \(name)"
        case .error(let message): return message
        }
    }
}

enum PhoneFileCategory: String, CaseIterable, Identifiable {
    case photosVideos = "photos_videos"
    case documents
    case music
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photosVideos: return "Photos & Videos"
        case .documents: return "Documents"
        case .music: return "Music"
        case .other: return "Other"
        }
    }
}

struct PhoneFileItem: Identifiable, Equatable {
    let id: String
    let filename: String
    let documentURI: String
    let size: Int64
    let modifiedDate: Date
    let mimeType: String
    let thumbnailData: Data?
}
