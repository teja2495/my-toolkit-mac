import Combine
import CryptoKit
import Foundation
import Network
import OSLog

@MainActor
final class PhoneBridgeController: ObservableObject {
    @Published private(set) var discoveredDevices: [DiscoveredPhoneDevice] = []
    @Published private(set) var trustedDevices: [PhoneTrustedDevice]
    @Published private(set) var pendingPairing: PendingPhonePairing?
    @Published private(set) var connectionState: PhoneConnectionState = .idle
    @Published private(set) var fileItems: [PhoneFileItem] = []
    @Published private(set) var isLoadingFiles: Bool = false
    @Published private(set) var fileBrowserMessage: String = "Pair and connect to an Android phone to browse files."
    @Published var selectedCategory: PhoneFileCategory = .photosVideos {
        didSet {
            requestFilesIfPossible()
        }
    }
    @Published var searchText: String = ""
    @Published var sortLabel: String = "Modified"

    private let store = PhoneBridgeStore()
    private let crypto = PhoneBridgeCrypto()
    private let queue = DispatchQueue(label: "com.tk.toolkit.phone-bridge", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.tk.toolkit", category: "PhoneBridge")
    private var browser: NWBrowser?
    private var activePairing: ActivePairing?
    private var allDiscoveredDevices: [DiscoveredPhoneDevice] = []
    private var connectedServiceName: String?
    private var fileRequestRetryTask: Task<Void, Never>?

    init() {
        trustedDevices = store.trustedDevices()
    }

    func start() {
        guard browser == nil else { return }
        logger.debug("Starting phone bridge browser")
        let browser = NWBrowser(
            for: .bonjour(type: PhoneBridgeProtocol.serviceType, domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.logger.debug("Browser ready")
                    self?.connectionState = .browsing
                case .failed(let error):
                    self?.logger.error("Browser failed: \(error.localizedDescription, privacy: .public)")
                    self?.connectionState = .error(error.localizedDescription)
                case .cancelled:
                    self?.logger.debug("Browser cancelled")
                    self?.connectionState = .idle
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results.compactMap { result -> DiscoveredPhoneDevice? in
                guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint else {
                    return nil
                }
                return DiscoveredPhoneDevice(id: name, name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                self?.allDiscoveredDevices = devices.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                self?.logger.debug("Discovered devices count=\(devices.count)")
                self?.refreshDiscoveredDevices()
            }
        }
        self.browser = browser
        connectionState = .browsing
        browser.start(queue: queue)
    }

    func stop() {
        logger.debug("Stopping phone bridge browser and active pairing")
        browser?.cancel()
        browser = nil
        activePairing?.connection.cancel()
        activePairing = nil
        pendingPairing = nil
        fileRequestRetryTask?.cancel()
        fileRequestRetryTask = nil
        fileItems = []
        fileBrowserMessage = "Pair and connect to an Android phone to browse files."
        isLoadingFiles = false
        connectedServiceName = nil
        allDiscoveredDevices = []
        discoveredDevices = []
        connectionState = .idle
    }

    func pair(with device: DiscoveredPhoneDevice) {
        logger.debug("Pair requested for service=\(device.name, privacy: .public)")
        activePairing?.connection.cancel()
        pendingPairing = nil
        connectionState = .pairing

        let connection = NWConnection(to: device.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in
                    self?.logger.debug("Connection ready for service=\(device.name, privacy: .public)")
                    self?.sendPairHello(to: connection, discoveredServiceName: device.name)
                }
            case .failed(let error):
                Task { @MainActor in
                    self?.logger.error("Connection failed for service=\(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self?.activePairing = nil
                    self?.pendingPairing = nil
                    self?.connectedServiceName = nil
                    self?.refreshDiscoveredDevices()
                    self?.connectionState = .error(error.localizedDescription)
                }
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func approvePendingPairing() {
        guard let activePairing else { return }
        sendEncrypted(
            ["type": PhoneBridgeProtocol.pairDecision, "approved": true],
            pairing: activePairing
        )
        pendingPairing = nil
        connectionState = .pairing
        receiveEncryptedMessages(pairing: activePairing)
        requestFilesIfPossible(forceRetry: true)
    }

    func rejectPendingPairing() {
        guard let activePairing else { return }
        sendEncrypted(
            ["type": PhoneBridgeProtocol.pairDecision, "approved": false],
            pairing: activePairing
        )
        activePairing.connection.cancel()
        self.activePairing = nil
        pendingPairing = nil
        connectionState = .browsing
    }

    func removeTrustedDevice(id: String) {
        store.removeTrustedDevice(id: id)
        trustedDevices = store.trustedDevices()
    }

    func refreshFiles() {
        requestFilesIfPossible(forceRetry: true)
    }

    private func sendPairHello(to connection: NWConnection, discoveredServiceName: String) {
        do {
            let identity = try crypto.getOrCreateIdentityKey()
            let publicKey = crypto.publicKeyBase64(identity.publicKey)
            let payload: [String: Any] = [
                "type": PhoneBridgeProtocol.pairHello,
                "protocolVersion": PhoneBridgeProtocol.version,
                "deviceId": store.deviceId(),
                "deviceName": Host.current().localizedName ?? "Mac",
                "platform": "macos",
                "publicKey": publicKey
            ]
            logger.debug("Sending pair.hello to service=\(discoveredServiceName, privacy: .public)")
            try sendFrame(json: payload, connection: connection)
            receivePairChallenge(
                connection: connection,
                identity: identity,
                localPublicKeyBase64: publicKey,
                discoveredServiceName: discoveredServiceName
            )
        } catch {
            Task { @MainActor in
                connectionState = .error(error.localizedDescription)
            }
        }
    }

    private func receivePairChallenge(
        connection: NWConnection,
        identity: P256.KeyAgreement.PrivateKey,
        localPublicKeyBase64: String,
        discoveredServiceName: String
    ) {
        receiveFrame(connection: connection) { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let data = try result.get()
                    let json = try Self.jsonObject(from: data)
                    guard json["type"] as? String == PhoneBridgeProtocol.pairChallenge,
                          let remotePublicKeyBase64 = json["publicKey"] as? String,
                          let saltBase64 = json["salt"] as? String,
                          let salt = Data(base64Encoded: saltBase64),
                          let deviceId = json["deviceId"] as? String else {
                        throw PhoneBridgeControllerError.invalidPairingResponse
                    }
                    let deviceName = json["deviceName"] as? String ?? "Android Phone"
                    self.logger.debug("Received pair.challenge from deviceId=\(deviceId, privacy: .public) name=\(deviceName, privacy: .public)")
                    let remotePublicKey = try self.crypto.publicKey(fromBase64: remotePublicKeyBase64)
                    let sessionKey = try self.crypto.deriveSessionKey(
                        localPrivateKey: identity,
                        remotePublicKey: remotePublicKey,
                        salt: salt
                    )
                    let code = self.crypto.verificationCode(
                        localPublicKeyBase64: localPublicKeyBase64,
                        remotePublicKeyBase64: remotePublicKeyBase64
                    )
                    let pairing = ActivePairing(
                        id: UUID().uuidString,
                        connection: connection,
                        sessionKey: sessionKey,
                        deviceId: deviceId,
                        deviceName: deviceName,
                        remotePublicKeyBase64: remotePublicKeyBase64,
                        serviceName: discoveredServiceName
                    )
                    self.activePairing = pairing
                    self.pendingPairing = PendingPhonePairing(
                        id: pairing.id,
                        deviceId: deviceId,
                        deviceName: deviceName,
                        verificationCode: code
                    )
                    self.connectionState = .pairing
                } catch {
                    connection.cancel()
                    self.connectionState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func receiveEncryptedMessages(pairing: ActivePairing) {
        receiveFrame(connection: pairing.connection) { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let encrypted = try result.get()
                    let decrypted = try self.crypto.decrypt(encrypted, key: pairing.sessionKey)
                    let json = try Self.jsonObject(from: decrypted)
                    if json["type"] as? String == PhoneBridgeProtocol.pairComplete {
                        self.logger.debug("Received pair.complete from deviceId=\(pairing.deviceId, privacy: .public)")
                        let now = Date()
                        let trusted = PhoneTrustedDevice(
                            id: pairing.deviceId,
                            name: pairing.deviceName,
                            publicKeyBase64: pairing.remotePublicKeyBase64,
                            pairedAt: now,
                            lastSeenAt: now
                        )
                        self.store.saveTrustedDevice(trusted)
                        self.trustedDevices = self.store.trustedDevices()
                        self.connectedServiceName = pairing.serviceName
                        self.refreshDiscoveredDevices()
                        self.connectionState = .connected(pairing.deviceName)
                        self.fileBrowserMessage = "Loading files from \(pairing.deviceName)..."
                        self.requestFilesIfPossible(forceRetry: true)
                    } else if json["type"] as? String == PhoneBridgeProtocol.listFilesResult {
                        self.fileRequestRetryTask?.cancel()
                        self.fileRequestRetryTask = nil
                        let count = (json["files"] as? [[String: Any]] ?? []).count
                        self.logger.debug("Received files.list.result from deviceId=\(pairing.deviceId, privacy: .public) count=\(count)")
                        self.handleListFilesResult(json)
                    } else if json["type"] as? String == PhoneBridgeProtocol.error {
                        self.fileRequestRetryTask?.cancel()
                        self.fileRequestRetryTask = nil
                        self.logger.error("Received bridge error from deviceId=\(pairing.deviceId, privacy: .public): \((json["message"] as? String) ?? "unknown", privacy: .public)")
                        self.isLoadingFiles = false
                        self.fileItems = []
                        self.fileBrowserMessage = (json["message"] as? String) ?? "Android reported a file browsing error."
                    }
                    self.receiveEncryptedMessages(pairing: pairing)
                } catch {
                    self.logger.error("Receive/decrypt failed for deviceId=\(pairing.deviceId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    pairing.connection.cancel()
                    self.activePairing = nil
                    self.pendingPairing = nil
                    self.connectedServiceName = nil
                    self.fileRequestRetryTask?.cancel()
                    self.fileRequestRetryTask = nil
                    self.fileItems = []
                    self.isLoadingFiles = false
                    self.refreshDiscoveredDevices()
                    self.connectionState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func sendEncrypted(_ payload: [String: Any], pairing: ActivePairing) {
        do {
            if let type = payload["type"] as? String {
                logger.debug("Sending encrypted message type=\(type, privacy: .public) to deviceId=\(pairing.deviceId, privacy: .public)")
            }
            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            let encrypted = try crypto.encrypt(jsonData, key: pairing.sessionKey)
            sendFrame(data: encrypted, connection: pairing.connection)
        } catch {
            logger.error("Failed to send encrypted message to deviceId=\(pairing.deviceId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            connectionState = .error(error.localizedDescription)
        }
    }

    private func sendFrame(json: [String: Any], connection: NWConnection) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        sendFrame(data: data, connection: connection)
    }

    private func sendFrame(data: Data, connection: NWConnection) {
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        connection.send(content: header + data, completion: .contentProcessed { _ in })
    }

    private func receiveFrame(
        connection: NWConnection,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let header, header.count == 4 else {
                completion(.failure(PhoneBridgeControllerError.connectionClosed))
                return
            }
            let size = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard size > 0, size <= 2 * 1024 * 1024 else {
                completion(.failure(PhoneBridgeControllerError.invalidFrameSize))
                return
            }
            connection.receive(minimumIncompleteLength: Int(size), maximumLength: Int(size)) { body, _, _, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let body, body.count == Int(size) else {
                    completion(.failure(PhoneBridgeControllerError.connectionClosed))
                    return
                }
                completion(.success(body))
            }
        }
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhoneBridgeControllerError.invalidJSON
        }
        return object
    }

    private func requestFilesIfPossible(forceRetry: Bool = false) {
        guard let activePairing else { return }
        let canRequestFiles: Bool
        switch connectionState {
        case .connected, .pairing:
            canRequestFiles = true
        default:
            canRequestFiles = false
        }
        guard canRequestFiles else { return }
        let category = selectedCategory
        if forceRetry {
            fileRequestRetryTask?.cancel()
            fileRequestRetryTask = nil
        }
        isLoadingFiles = true
        fileBrowserMessage = "Loading \(category.title.lowercased()) from \(activePairing.deviceName)..."
        logger.debug("Requesting files category=\(category.rawValue, privacy: .public) from deviceId=\(activePairing.deviceId, privacy: .public)")
        sendEncrypted(
            [
                "type": PhoneBridgeProtocol.listFiles,
                "category": category.rawValue,
                "pageSize": 100,
                "pageToken": 0
            ],
            pairing: activePairing
        )
        guard forceRetry else { return }
        fileRequestRetryTask = Task { [weak self] in
            for attempt in 1...2 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, let retryPairing = self.activePairing else { return }
                    let canRetry: Bool
                    switch self.connectionState {
                    case .connected, .pairing:
                        canRetry = true
                    default:
                        canRetry = false
                    }
                    guard canRetry else { return }
                    guard self.isLoadingFiles else { return }
                    self.logger.debug("Retrying files.list attempt=\(attempt) category=\(category.rawValue, privacy: .public) deviceId=\(retryPairing.deviceId, privacy: .public)")
                    self.sendEncrypted(
                        [
                            "type": PhoneBridgeProtocol.listFiles,
                            "category": category.rawValue,
                            "pageSize": 100,
                            "pageToken": 0
                        ],
                        pairing: retryPairing
                    )
                }
            }
        }
    }

    private func handleListFilesResult(_ json: [String: Any]) {
        isLoadingFiles = false
        let files = (json["files"] as? [[String: Any]] ?? []).compactMap { item -> PhoneFileItem? in
            guard
                let id = item["id"] as? String,
                let filename = item["filename"] as? String,
                let documentURI = item["documentUri"] as? String,
                let sizeNumber = item["size"] as? NSNumber,
                let modifiedNumber = item["modifiedDate"] as? NSNumber,
                let mimeType = item["mimeType"] as? String
            else {
                return nil
            }
            let thumbnailData: Data?
            if let thumbnailBase64 = item["thumbnail"] as? String {
                thumbnailData = Data(base64Encoded: thumbnailBase64)
            } else {
                thumbnailData = nil
            }
            return PhoneFileItem(
                id: id,
                filename: filename,
                documentURI: documentURI,
                size: sizeNumber.int64Value,
                modifiedDate: Date(timeIntervalSince1970: modifiedNumber.doubleValue / 1000),
                mimeType: mimeType,
                thumbnailData: thumbnailData
            )
        }
        fileItems = files
        logger.debug("Rendered file items count=\(files.count)")
        if files.isEmpty {
            fileBrowserMessage = "No files found in \(selectedCategory.title)."
        } else {
            fileBrowserMessage = ""
        }
    }

    private func refreshDiscoveredDevices() {
        discoveredDevices = allDiscoveredDevices.filter { device in
            guard let connectedServiceName else { return true }
            return device.name != connectedServiceName
        }
    }

}

private struct ActivePairing {
    let id: String
    let connection: NWConnection
    let sessionKey: SymmetricKey
    let deviceId: String
    let deviceName: String
    let remotePublicKeyBase64: String
    let serviceName: String
}

enum PhoneBridgeControllerError: Error {
    case invalidPairingResponse
    case invalidFrameSize
    case invalidJSON
    case connectionClosed
}
