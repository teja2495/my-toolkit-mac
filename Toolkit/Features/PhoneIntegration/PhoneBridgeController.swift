import Combine
import CryptoKit
import Foundation
import Network
import OSLog

@MainActor
final class PhoneBridgeController: ObservableObject {
    private static let maxFilesPerCategory = 30
    private static let nonDocumentFileExtensions: Set<String> = [
        "apk",
        "avif",
        "bmp",
        "gif",
        "heic",
        "jpeg",
        "jpg",
        "m4a",
        "m4v",
        "mkv",
        "mov",
        "mp3",
        "mp4",
        "png",
        "wav",
        "webm",
        "webp"
    ]

    @Published private(set) var discoveredDevices: [DiscoveredPhoneDevice] = []
    @Published private(set) var trustedDevices: [PhoneTrustedDevice]
    @Published private(set) var pendingPairing: PendingPhonePairing?
    @Published private(set) var connectionState: PhoneConnectionState = .idle
    @Published private(set) var fileItems: [PhoneFileItem] = []
    @Published private(set) var isLoadingFiles: Bool = false
    @Published private(set) var fileBrowserMessage: String = "Pair and connect to an Android phone to browse files."
    @Published var selectedCategory: PhoneFileCategory = .photosVideos {
        didSet {
            refreshVisibleFileItems()
        }
    }

    private let store = PhoneBridgeStore()
    private let crypto = PhoneBridgeCrypto()
    private let queue = DispatchQueue(label: "com.tk.toolkit.phone-bridge", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.tk.toolkit", category: "PhoneBridge")
    private var browser: NWBrowser?
    private var activePairing: ActivePairing?
    private var allDiscoveredDevices: [DiscoveredPhoneDevice] = []
    private var connectedServiceName: String?
    private var fileRequestRetryTask: Task<Void, Never>?
    private var reconnectingServiceNames: Set<String> = []
    private var cachedFileItemsByCategory: [PhoneFileCategory: [PhoneFileItem]] = [:]
    private var queuedFileCategories: [PhoneFileCategory] = []
    private var activeFileRequestCategory: PhoneFileCategory?
    private var activeFileTransfers: [String: ActiveFileTransfer] = [:]

    init() {
        trustedDevices = store.trustedDevices()
    }

    func start() {
        guard browser == nil else { return }
        logger.debug("Starting phone bridge browser")
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: PhoneBridgeProtocol.serviceType, domain: nil),
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
                let advertisedDeviceId: String?
                if case let .bonjour(txtRecord) = result.metadata {
                    advertisedDeviceId = txtRecord.dictionary["deviceId"]
                } else {
                    advertisedDeviceId = nil
                }
                return DiscoveredPhoneDevice(
                    id: advertisedDeviceId ?? name,
                    name: name,
                    endpoint: result.endpoint,
                    advertisedDeviceId: advertisedDeviceId
                )
            }
            Task { @MainActor in
                self?.allDiscoveredDevices = devices.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                self?.reconnectingServiceNames.formIntersection(Set(devices.map(\.name)))
                self?.logger.debug("Discovered devices count=\(devices.count)")
                self?.refreshDiscoveredDevices()
                self?.attemptAutoReconnectIfPossible()
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
        reconnectingServiceNames = []
        cachedFileItemsByCategory = [:]
        queuedFileCategories = []
        activeFileRequestCategory = nil
        activeFileTransfers = [:]
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
                    self?.reconnectingServiceNames.remove(device.name)
                    self?.refreshDiscoveredDevices()
                    self?.connectionState = .error(error.localizedDescription)
                    self?.attemptAutoReconnectIfPossible()
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
        refreshFiles()
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
        reconnectingServiceNames.remove(activePairing.serviceName)
        connectionState = .browsing
        attemptAutoReconnectIfPossible()
    }

    func removeTrustedDevice(id: String) {
        store.removeTrustedDevice(id: id)
        trustedDevices = store.trustedDevices()
        reconnectingServiceNames.removeAll()
        attemptAutoReconnectIfPossible()
    }

    func refreshFiles() {
        let categories = orderedRefreshCategories()
        for (index, category) in categories.enumerated() {
            enqueueFileRequest(
                for: category,
                prioritize: index == 0,
                forceRetry: true
            )
        }
    }

    func requestLocalFileURL(
        for file: PhoneFileItem,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let activePairing else {
            completion(.failure(PhoneBridgeControllerError.noActiveConnection))
            return
        }

        let requestID = UUID().uuidString
        activeFileTransfers[requestID] = ActiveFileTransfer(
            file: file,
            completion: completion
        )
        sendEncrypted(
            [
                "type": PhoneBridgeProtocol.readFile,
                "requestId": requestID,
                "documentUri": file.documentURI
            ],
            pairing: activePairing
        )
    }

    func isTrustedDiscoveredDevice(_ device: DiscoveredPhoneDevice) -> Bool {
        if let advertisedDeviceId = device.advertisedDeviceId {
            return trustedDevices.contains { $0.id == advertisedDeviceId }
        }
        return trustedDevices.contains { $0.name == device.name }
    }

    func trustedDeviceName(for device: DiscoveredPhoneDevice) -> String? {
        if let advertisedDeviceId = device.advertisedDeviceId,
           let trustedDevice = trustedDevices.first(where: { $0.id == advertisedDeviceId }) {
            return trustedDevice.name
        }
        return trustedDevices.first(where: { $0.name == device.name })?.name
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
                    self.connectionState = .pairing
                    if self.shouldAutoApproveTrustedDevice(
                        deviceId: deviceId,
                        remotePublicKeyBase64: remotePublicKeyBase64
                    ) {
                        self.logger.debug("Auto-approving trusted deviceId=\(deviceId, privacy: .public)")
                        self.pendingPairing = nil
                        self.sendEncrypted(
                            ["type": PhoneBridgeProtocol.pairDecision, "approved": true],
                            pairing: pairing
                        )
                        self.receiveEncryptedMessages(pairing: pairing)
                        self.refreshFiles()
                    } else {
                        self.pendingPairing = PendingPhonePairing(
                            id: pairing.id,
                            deviceId: deviceId,
                            deviceName: deviceName,
                            verificationCode: code
                        )
                    }
                } catch {
                    self.reconnectingServiceNames.remove(discoveredServiceName)
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
                        self.reconnectingServiceNames.remove(pairing.serviceName)
                        self.refreshDiscoveredDevices()
                        self.connectionState = .connected(pairing.deviceName)
                        self.fileBrowserMessage = "Loading files from \(pairing.deviceName)..."
                        self.refreshFiles()
                    } else if json["type"] as? String == PhoneBridgeProtocol.listFilesResult {
                        self.fileRequestRetryTask?.cancel()
                        self.fileRequestRetryTask = nil
                        let count = (json["files"] as? [[String: Any]] ?? []).count
                        self.logger.debug("Received files.list.result from deviceId=\(pairing.deviceId, privacy: .public) count=\(count)")
                        self.handleListFilesResult(json)
                    } else if json["type"] as? String == PhoneBridgeProtocol.readFileResult {
                        self.handleReadFileResult(json)
                    } else if json["type"] as? String == PhoneBridgeProtocol.error {
                        if self.handleFileTransferErrorIfNeeded(json) {
                            self.receiveEncryptedMessages(pairing: pairing)
                            return
                        }
                        self.fileRequestRetryTask?.cancel()
                        self.fileRequestRetryTask = nil
                        self.logger.error("Received bridge error from deviceId=\(pairing.deviceId, privacy: .public): \((json["message"] as? String) ?? "unknown", privacy: .public)")
                        self.isLoadingFiles = false
                        self.activeFileRequestCategory = nil
                        self.fileItems = []
                        self.fileBrowserMessage = (json["message"] as? String) ?? "Android reported a file browsing error."
                        self.processQueuedFileRequestsIfPossible()
                    }
                    self.receiveEncryptedMessages(pairing: pairing)
                } catch {
                    self.logger.error("Receive/decrypt failed for deviceId=\(pairing.deviceId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    pairing.connection.cancel()
                    self.activePairing = nil
                    self.pendingPairing = nil
                    self.connectedServiceName = nil
                    self.reconnectingServiceNames.remove(pairing.serviceName)
                    self.fileRequestRetryTask?.cancel()
                    self.fileRequestRetryTask = nil
                    self.fileItems = []
                    self.cachedFileItemsByCategory = [:]
                    self.queuedFileCategories = []
                    self.activeFileRequestCategory = nil
                    let activeTransfers = self.activeFileTransfers
                    self.activeFileTransfers = [:]
                    self.isLoadingFiles = false
                    self.refreshDiscoveredDevices()
                    self.connectionState = .error(error.localizedDescription)
                    activeTransfers.values.forEach { transfer in
                        transfer.completion(.failure(error))
                    }
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
        let categories = requestedCategories(for: selectedCategory)
        for (index, category) in categories.enumerated() {
            enqueueFileRequest(
                for: category,
                prioritize: index == 0,
                forceRetry: forceRetry
            )
        }
    }

    private func handleListFilesResult(_ json: [String: Any]) {
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
            let thumbnailData = decodeThumbnailData(from: item["thumbnail"])
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
        let responseCategory = category(from: json) ?? activeFileRequestCategory ?? selectedCategory
        cachedFileItemsByCategory[responseCategory] = limitedFiles(files, for: responseCategory)
        refreshVisibleFileItems()
        logger.debug("Rendered file items count=\(files.count) category=\(responseCategory.rawValue, privacy: .public)")
        activeFileRequestCategory = nil
        isLoadingFiles = false
        processQueuedFileRequestsIfPossible()
    }

    private func decodeThumbnailData(from value: Any?) -> Data? {
        guard let value else { return nil }

        if let data = value as? Data {
            return data
        }

        if let string = value as? String {
            return decodeThumbnailData(from: string)
        }

        if let dictionary = value as? [String: Any] {
            if let string = dictionary["base64"] as? String {
                return decodeThumbnailData(from: string)
            }
            if let string = dictionary["data"] as? String {
                return decodeThumbnailData(from: string)
            }
        }

        return nil
    }

    private func decodeThumbnailData(from string: String) -> Data? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let payload: String
        if let commaIndex = trimmed.firstIndex(of: ","), trimmed[..<commaIndex].contains("base64") {
            payload = String(trimmed[trimmed.index(after: commaIndex)...])
        } else {
            payload = trimmed
        }

        if let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) {
            return data
        }

        let normalized = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - (normalized.count % 4)) % 4
        let padded = normalized + String(repeating: "=", count: padding)
        return Data(base64Encoded: padded, options: [.ignoreUnknownCharacters])
    }

    private func refreshDiscoveredDevices() {
        discoveredDevices = allDiscoveredDevices.filter { device in
            guard let connectedServiceName else { return true }
            return device.name != connectedServiceName
        }
    }

    private func enqueueFileRequest(
        for category: PhoneFileCategory,
        prioritize: Bool = false,
        forceRetry: Bool = false
    ) {
        guard canRequestFiles else { return }
        if forceRetry {
            fileRequestRetryTask?.cancel()
            fileRequestRetryTask = nil
            cachedFileItemsByCategory[category] = nil
        }
        if activeFileRequestCategory == category {
            sendActiveFileRequest(forceRetry: forceRetry)
            return
        }
        queuedFileCategories.removeAll { $0 == category }
        if prioritize {
            queuedFileCategories.insert(category, at: 0)
        } else {
            queuedFileCategories.append(category)
        }
        processQueuedFileRequestsIfPossible(forceRetry: forceRetry)
    }

    private func processQueuedFileRequestsIfPossible(forceRetry: Bool = false) {
        guard canRequestFiles else { return }
        guard activeFileRequestCategory == nil else { return }
        guard !queuedFileCategories.isEmpty else {
            refreshVisibleFileItems()
            return
        }
        activeFileRequestCategory = queuedFileCategories.removeFirst()
        sendActiveFileRequest(forceRetry: forceRetry)
    }

    private func sendActiveFileRequest(forceRetry: Bool) {
        guard let activePairing, let category = activeFileRequestCategory else { return }
        if forceRetry {
            fileRequestRetryTask?.cancel()
            fileRequestRetryTask = nil
        }
        let pageSize = Self.maxFilesPerCategory
        isLoadingFiles = true
        if category == selectedCategory {
            fileBrowserMessage = "Loading \(category.title.lowercased()) from \(activePairing.deviceName)..."
        }
        logger.debug("Requesting files category=\(category.rawValue, privacy: .public) from deviceId=\(activePairing.deviceId, privacy: .public)")
        sendEncrypted(
            [
                "type": PhoneBridgeProtocol.listFiles,
                "category": category.rawValue,
                "pageSize": pageSize,
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
                    guard self.canRequestFiles else { return }
                    guard self.isLoadingFiles else { return }
                    guard self.activeFileRequestCategory == category else { return }
                    self.logger.debug("Retrying files.list attempt=\(attempt) category=\(category.rawValue, privacy: .public) deviceId=\(retryPairing.deviceId, privacy: .public)")
                    self.sendEncrypted(
                        [
                            "type": PhoneBridgeProtocol.listFiles,
                            "category": category.rawValue,
                            "pageSize": pageSize,
                            "pageToken": 0
                        ],
                        pairing: retryPairing
                    )
                }
            }
        }
    }

    private var canRequestFiles: Bool {
        switch connectionState {
        case .connected, .pairing:
            return activePairing != nil
        default:
            return false
        }
    }

    private func refreshVisibleFileItems() {
        let visibleFiles: [PhoneFileItem]
        switch selectedCategory {
        case .documents:
            visibleFiles = mergedFiles(
                cachedFileItemsByCategory[.documents] ?? [],
                cachedFileItemsByCategory[.music] ?? []
            )
        default:
            visibleFiles = cachedFileItemsByCategory[selectedCategory] ?? []
        }
        fileItems = visibleFiles
        if visibleFiles.isEmpty {
            if canRequestFiles && activeFileRequestCategory == nil {
                if hasCachedFileItems(for: selectedCategory) {
                    fileBrowserMessage = "No files found in \(selectedCategory.title)."
                } else {
                    fileBrowserMessage = "Tap refresh to load \(selectedCategory.title.lowercased())."
                }
            } else if !canRequestFiles {
                fileBrowserMessage = "Pair and connect to an Android phone to browse files."
            }
        } else {
            fileBrowserMessage = ""
        }
    }

    private func limitedFiles(_ files: [PhoneFileItem], for category: PhoneFileCategory) -> [PhoneFileItem] {
        files.filter { file in
            switch category {
            case .documents:
                return isDocumentFile(file)
            default:
                return true
            }
        }
        .sorted { $0.modifiedDate > $1.modifiedDate }
        .prefix(Self.maxFilesPerCategory)
        .map { $0 }
    }

    private func handleReadFileResult(_ json: [String: Any]) {
        guard let requestID = json["requestId"] as? String,
              var transfer = activeFileTransfers[requestID] else { return }
        guard let chunkIndex = json["chunkIndex"] as? Int,
              let totalChunks = json["totalChunks"] as? Int,
              let dataString = json["data"] as? String,
              let chunkData = Data(base64Encoded: dataString, options: [.ignoreUnknownCharacters]) else {
            finishFileTransfer(
                requestID: requestID,
                result: .failure(PhoneBridgeControllerError.invalidFileTransferResponse)
            )
            return
        }
        guard chunkIndex == transfer.nextChunkIndex, totalChunks > 0 else {
            finishFileTransfer(
                requestID: requestID,
                result: .failure(PhoneBridgeControllerError.invalidFileTransferResponse)
            )
            return
        }

        transfer.buffer.append(chunkData)
        transfer.nextChunkIndex += 1
        activeFileTransfers[requestID] = transfer

        if transfer.nextChunkIndex == totalChunks {
            do {
                let url = try writeTransferredFileToDisk(file: transfer.file, data: transfer.buffer)
                finishFileTransfer(requestID: requestID, result: .success(url))
            } catch {
                finishFileTransfer(requestID: requestID, result: .failure(error))
            }
        }
    }

    private func requestedCategories(for selectedCategory: PhoneFileCategory) -> [PhoneFileCategory] {
        switch selectedCategory {
        case .documents:
            return [.documents, .music]
        default:
            return [selectedCategory]
        }
    }

    private func orderedRefreshCategories() -> [PhoneFileCategory] {
        var orderedCategories: [PhoneFileCategory] = []
        for category in PhoneFileCategory.allCases.flatMap(requestedCategories(for:)) {
            if !orderedCategories.contains(category) {
                orderedCategories.append(category)
            }
        }
        return orderedCategories
    }

    private func hasCachedFileItems(for category: PhoneFileCategory) -> Bool {
        switch category {
        case .documents:
            return cachedFileItemsByCategory[.documents] != nil || cachedFileItemsByCategory[.music] != nil
        default:
            return cachedFileItemsByCategory[category] != nil
        }
    }

    private func mergedFiles(_ first: [PhoneFileItem], _ second: [PhoneFileItem]) -> [PhoneFileItem] {
        let merged = Dictionary(
            uniqueKeysWithValues: (first + second).map { ($0.id, $0) }
        )
        return merged.values
            .sorted { $0.modifiedDate > $1.modifiedDate }
            .prefix(Self.maxFilesPerCategory)
            .map { $0 }
    }

    private func handleFileTransferErrorIfNeeded(_ json: [String: Any]) -> Bool {
        guard let requestID = json["requestId"] as? String,
              activeFileTransfers[requestID] != nil else {
            return false
        }
        let message = (json["message"] as? String) ?? "Unable to open file from Android."
        finishFileTransfer(
            requestID: requestID,
            result: .failure(PhoneBridgeControllerError.remoteFileTransferFailed(message))
        )
        return true
    }

    private func finishFileTransfer(requestID: String, result: Result<URL, Error>) {
        guard let transfer = activeFileTransfers.removeValue(forKey: requestID) else { return }
        transfer.completion(result)
    }

    private func writeTransferredFileToDisk(file: PhoneFileItem, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolkitPhonePreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(file.filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func normalizedExtension(for file: PhoneFileItem) -> String {
        URL(fileURLWithPath: file.filename).pathExtension.lowercased()
    }

    private func isDocumentFile(_ file: PhoneFileItem) -> Bool {
        if file.mimeType.hasPrefix("image/") || file.mimeType.hasPrefix("video/") || file.mimeType.hasPrefix("audio/") {
            return false
        }
        return !Self.nonDocumentFileExtensions.contains(normalizedExtension(for: file))
    }

    private func category(from json: [String: Any]) -> PhoneFileCategory? {
        guard let rawValue = json["category"] as? String else { return nil }
        return PhoneFileCategory(rawValue: rawValue)
    }

    private func attemptAutoReconnectIfPossible() {
        guard activePairing == nil else { return }
        guard pendingPairing == nil else { return }
        guard connectedServiceName == nil else { return }

        let trustedDeviceIds = Set(trustedDevices.map(\.id))
        let trustedNames = Set(trustedDevices.map(\.name))
        guard !trustedDeviceIds.isEmpty || !trustedNames.isEmpty else { return }

        guard let trustedDevice = allDiscoveredDevices.first(where: {
            !reconnectingServiceNames.contains($0.name) && (
                ($0.advertisedDeviceId.map { trustedDeviceIds.contains($0) } ?? false) ||
                trustedNames.contains($0.name)
            )
        }) else { return }

        logger.debug("Attempting auto-reconnect for service=\(trustedDevice.name, privacy: .public)")
        reconnectingServiceNames.insert(trustedDevice.name)
        pair(with: trustedDevice)
    }

    private func shouldAutoApproveTrustedDevice(
        deviceId: String,
        remotePublicKeyBase64: String
    ) -> Bool {
        trustedDevices.contains {
            $0.id == deviceId && $0.publicKeyBase64 == remotePublicKeyBase64
        }
    }

}

private struct ActiveFileTransfer {
    let file: PhoneFileItem
    let completion: (Result<URL, Error>) -> Void
    var buffer = Data()
    var nextChunkIndex = 0
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
    case noActiveConnection
    case invalidFileTransferResponse
    case remoteFileTransferFailed(String)
}
