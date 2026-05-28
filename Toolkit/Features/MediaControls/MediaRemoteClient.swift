import AppKit
import Darwin
import Foundation

struct MediaNowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var appName: String
    var bundleIdentifier: String
    var duration: TimeInterval
    var elapsedTime: TimeInterval
    var timestamp: Date
    var playbackRate: Double
    var isPlaying: Bool
    var artwork: NSImage?

    var hasContent: Bool {
        !title.isEmpty || !artist.isEmpty || !album.isEmpty || !appName.isEmpty || duration > 0
    }

    static let empty = MediaNowPlayingInfo(
        title: "",
        artist: "",
        album: "",
        appName: "",
        bundleIdentifier: "",
        duration: 0,
        elapsedTime: 0,
        timestamp: .distantPast,
        playbackRate: 0,
        isPlaying: false,
        artwork: nil
    )

    static func == (lhs: MediaNowPlayingInfo, rhs: MediaNowPlayingInfo) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.appName == rhs.appName
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.duration == rhs.duration
            && lhs.elapsedTime == rhs.elapsedTime
            && lhs.timestamp == rhs.timestamp
            && lhs.playbackRate == rhs.playbackRate
            && lhs.isPlaying == rhs.isPlaying
    }

    func withTimeline(
        elapsedTime: TimeInterval,
        timestamp: Date,
        playbackRate: Double,
        isPlaying: Bool
    ) -> MediaNowPlayingInfo {
        var copy = self
        copy.elapsedTime = max(0, min(elapsedTime, max(duration, 0)))
        copy.timestamp = timestamp
        copy.playbackRate = playbackRate
        copy.isPlaying = isPlaying
        return copy
    }
}

final class MediaRemoteClient {
    private typealias RegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void
    private typealias GetNowPlayingInfoFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (CFDictionary?) -> Void
    ) -> Void
    private typealias SendCommandFunction = @convention(c) (Int32, CFDictionary?) -> Void
    private typealias SetElapsedTimeFunction = @convention(c) (Double) -> Void
    private typealias GetNowPlayingApplicationIsPlayingFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (ObjCBool) -> Void
    ) -> Void
    private typealias GetNowPlayingApplicationPIDFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (Int32) -> Void
    ) -> Void

    private enum Command {
        static let play: Int32 = 0
        static let pause: Int32 = 1
        static let togglePlayPause: Int32 = 2
        static let nextTrack: Int32 = 4
        static let previousTrack: Int32 = 5
        static let seekToPlaybackPosition: Int32 = 26
    }

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let registerForNowPlayingNotifications: RegisterForNowPlayingNotificationsFunction?
    private let getNowPlayingInfo: GetNowPlayingInfoFunction?
    private let sendCommandFunction: SendCommandFunction?
    private let setElapsedTimeFunction: SetElapsedTimeFunction?
    private let getNowPlayingApplicationIsPlaying: GetNowPlayingApplicationIsPlayingFunction?
    private let getNowPlayingApplicationPID: GetNowPlayingApplicationPIDFunction?
    private var adapterProcess: Process?
    private var adapterReadabilityHandler: ((FileHandle) -> Void)?
    private var adapterPipe: Pipe?
    private var adapterBuffer = ""
    private var adapterNowPlaying: MediaNowPlayingInfo?
    private var onNowPlayingUpdate: ((MediaNowPlayingInfo) -> Void)?
    private let adapterQueue = DispatchQueue(label: "MediaRemoteAdapterCommandQueue", qos: .userInitiated)

    var isAvailable: Bool {
        getNowPlayingInfo != nil
            && sendCommandFunction != nil
            && getNowPlayingApplicationIsPlaying != nil
    }

    init() {
        frameworkHandle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )

        registerForNowPlayingNotifications = Self.loadSymbol(
            "MRMediaRemoteRegisterForNowPlayingNotifications",
            from: frameworkHandle
        )
        getNowPlayingInfo = Self.loadSymbol(
            "MRMediaRemoteGetNowPlayingInfo",
            from: frameworkHandle
        )
        sendCommandFunction = Self.loadSymbol(
            "MRMediaRemoteSendCommand",
            from: frameworkHandle
        )
        setElapsedTimeFunction = Self.loadSymbol(
            "MRMediaRemoteSetElapsedTime",
            from: frameworkHandle
        )
        getNowPlayingApplicationIsPlaying = Self.loadSymbol(
            "MRMediaRemoteGetNowPlayingApplicationIsPlaying",
            from: frameworkHandle
        )
        getNowPlayingApplicationPID = Self.loadSymbol(
            "MRMediaRemoteGetNowPlayingApplicationPID",
            from: frameworkHandle
        )
    }

    deinit {
        stopStreaming()
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    func registerForUpdates(onUpdate: ((MediaNowPlayingInfo) -> Void)? = nil) {
        onNowPlayingUpdate = onUpdate
        registerForNowPlayingNotifications?(DispatchQueue.main)
        startAdapterStream()
    }

    func fetchNowPlaying(completion: @escaping (MediaNowPlayingInfo) -> Void) {
        if let adapterNowPlaying {
            completion(adapterNowPlaying)
            return
        }

        guard let getNowPlayingInfo else {
            completion(.empty)
            return
        }

        getNowPlayingInfo(DispatchQueue.main) { [weak self] rawInfo in
            guard let self else {
                completion(Self.parse(rawInfo, isPlaying: false, applicationPID: 0))
                return
            }

            var didComplete = false
            func completeOnce(isPlaying: Bool, pid: Int32) {
                guard !didComplete else { return }
                didComplete = true
                completion(Self.parse(rawInfo, isPlaying: isPlaying, applicationPID: pid))
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let fallbackInfo = Self.parse(rawInfo, isPlaying: false, applicationPID: 0)
                completeOnce(isPlaying: fallbackInfo.playbackRate > 0, pid: 0)
            }

            self.fetchIsPlaying { isPlaying in
                self.fetchNowPlayingApplicationPID { pid in
                    completeOnce(isPlaying: isPlaying, pid: pid)
                }
            }
        }
    }

    func togglePlayPause() {
        if sendAdapterCommand(.togglePlayPause) { return }
        sendCommandFunction?(Command.togglePlayPause, nil)
    }

    func pause() {
        if sendAdapterCommand(.pause) { return }
        sendCommandFunction?(Command.pause, nil)
    }

    func nextTrack() {
        if sendAdapterCommand(.nextTrack) { return }
        sendCommandFunction?(Command.nextTrack, nil)
    }

    func previousTrack() {
        if sendAdapterCommand(.previousTrack) { return }
        sendCommandFunction?(Command.previousTrack, nil)
    }

    func seek(to position: TimeInterval) {
        let safePosition = max(0, position)

        sendAdapterSeek(to: safePosition)
        if let setElapsedTimeFunction {
            setElapsedTimeFunction(safePosition)
        }

        let options = ["kMRMediaRemoteOptionPlaybackPosition": safePosition] as CFDictionary
        sendCommandFunction?(Command.seekToPlaybackPosition, options)
    }

    func stopStreaming() {
        adapterPipe?.fileHandleForReading.readabilityHandler = nil
        adapterReadabilityHandler = nil
        adapterPipe = nil
        adapterBuffer = ""

        if let adapterProcess, adapterProcess.isRunning {
            adapterProcess.terminate()
        }
        adapterProcess = nil
        onNowPlayingUpdate = nil
    }

    private static func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private enum AdapterCommand: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    @discardableResult
    private func sendAdapterCommand(_ command: AdapterCommand) -> Bool {
        runAdapterCommand(arguments: ["send", String(command.rawValue)])
    }

    @discardableResult
    private func sendAdapterSeek(to position: TimeInterval) -> Bool {
        let micros = max(0, Int64((position * 1_000_000).rounded()))
        return runAdapterCommand(arguments: ["seek", String(micros)])
    }

    @discardableResult
    private func runAdapterCommand(arguments: [String]) -> Bool {
        guard let scriptURL = adapterScriptURL(),
              let frameworkURL = adapterFrameworkURL() else {
            return false
        }

        adapterQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [scriptURL.path, frameworkURL.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }

        return true
    }

    private func fetchIsPlaying(completion: @escaping (Bool) -> Void) {
        guard let getNowPlayingApplicationIsPlaying else {
            completion(false)
            return
        }

        getNowPlayingApplicationIsPlaying(DispatchQueue.main) { isPlaying in
            completion(isPlaying.boolValue)
        }
    }

    private func fetchNowPlayingApplicationPID(completion: @escaping (Int32) -> Void) {
        guard let getNowPlayingApplicationPID else {
            completion(0)
            return
        }

        getNowPlayingApplicationPID(DispatchQueue.main) { pid in
            completion(pid)
        }
    }

    private static func parse(_ rawInfo: CFDictionary?, isPlaying: Bool, applicationPID: Int32) -> MediaNowPlayingInfo {
        let info = rawInfo as NSDictionary?

        let elapsed = doubleValue(value(for: "kMRMediaRemoteNowPlayingInfoElapsedTime", in: info))
        let rate = doubleValue(value(for: "kMRMediaRemoteNowPlayingInfoPlaybackRate", in: info))
        let timestamp = value(for: "kMRMediaRemoteNowPlayingInfoTimestamp", in: info) as? Date
        let adjustedElapsed: TimeInterval
        if rate > 0, let timestamp {
            adjustedElapsed = elapsed + Date().timeIntervalSince(timestamp) * rate
        } else {
            adjustedElapsed = elapsed
        }

        let bundleIdentifier = bundleIdentifier(from: applicationPID)
        let artwork = artworkImage(from: info) ?? appIcon(fromBundleIdentifier: bundleIdentifier)

        return MediaNowPlayingInfo(
            title: stringValue(value(for: "kMRMediaRemoteNowPlayingInfoTitle", in: info)),
            artist: stringValue(value(for: "kMRMediaRemoteNowPlayingInfoArtist", in: info)),
            album: stringValue(value(for: "kMRMediaRemoteNowPlayingInfoAlbum", in: info)),
            appName: appName(from: applicationPID),
            bundleIdentifier: bundleIdentifier,
            duration: max(0, doubleValue(value(for: "kMRMediaRemoteNowPlayingInfoDuration", in: info))),
            elapsedTime: max(0, adjustedElapsed),
            timestamp: timestamp ?? Date(),
            playbackRate: rate,
            isPlaying: isPlaying,
            artwork: artwork
        )
    }

    private static func value(for key: String, in info: NSDictionary?) -> Any? {
        info?.object(forKey: key)
    }

    private static func stringValue(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return 0
    }

    private static func artworkImage(from info: NSDictionary?) -> NSImage? {
        if let data = value(for: "kMRMediaRemoteNowPlayingInfoArtworkData", in: info) as? Data {
            return NSImage(data: data)
        }

        if let image = value(for: "kMRMediaRemoteNowPlayingInfoArtwork", in: info) as? NSImage {
            return image
        }

        return nil
    }

    private func startAdapterStream() {
        guard adapterProcess == nil,
              let scriptURL = adapterScriptURL(),
              let frameworkURL = adapterFrameworkURL() else { return }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            scriptURL.path,
            frameworkURL.path,
            "stream",
            "--debounce=100"
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.adapterPipe?.fileHandleForReading.readabilityHandler = nil
                self?.adapterReadabilityHandler = nil
                self?.adapterPipe = nil
                self?.adapterProcess = nil
            }
        }

        adapterReadabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.consumeAdapterChunk(chunk)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = adapterReadabilityHandler

        do {
            try process.run()
            adapterProcess = process
            adapterPipe = pipe
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            adapterReadabilityHandler = nil
        }
    }

    private func consumeAdapterChunk(_ chunk: String) {
        adapterBuffer.append(chunk)

        while let range = adapterBuffer.range(of: "\n") {
            let line = String(adapterBuffer[..<range.lowerBound])
            adapterBuffer = String(adapterBuffer[range.upperBound...])
            guard let update = decodeAdapterUpdate(line) else { continue }

            let info = parseAdapter(update, previous: adapterNowPlaying)
            adapterNowPlaying = info
            onNowPlayingUpdate?(info)
        }
    }

    private func decodeAdapterUpdate(_ line: String) -> MediaRemoteAdapterUpdate? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MediaRemoteAdapterUpdate.self, from: data)
    }

    private func parseAdapter(
        _ update: MediaRemoteAdapterUpdate,
        previous: MediaNowPlayingInfo?
    ) -> MediaNowPlayingInfo {
        let payload = update.payload
        let usesDiff = update.diff ?? false
        let fallback = usesDiff ? (previous ?? .empty) : .empty
        let bundleIdentifier = payload.parentApplicationBundleIdentifier
            ?? payload.bundleIdentifier
            ?? fallback.bundleIdentifier
        let receivedAt = Date()
        let playbackRate = payload.playbackRate ?? (usesDiff ? fallback.playbackRate : 0)
        let isPlaying = payload.playing ?? (usesDiff ? fallback.isPlaying : playbackRate > 0)
        let playbackStateChanged = usesDiff && payload.playing != nil && payload.playing != fallback.isPlaying
        let elapsedTime = payload.elapsedTime
            ?? (playbackStateChanged ? Self.estimatedElapsed(for: fallback, at: receivedAt) : fallback.elapsedTime)
        let timestamp = payload.timestamp.flatMap(Self.adapterDateFormatter.date(from:))
            ?? (playbackStateChanged ? receivedAt : (usesDiff ? fallback.timestamp : receivedAt))

        return MediaNowPlayingInfo(
            title: payload.title ?? fallback.title,
            artist: payload.artist ?? fallback.artist,
            album: payload.album ?? fallback.album,
            appName: Self.appName(fromBundleIdentifier: bundleIdentifier) ?? fallback.appName,
            bundleIdentifier: bundleIdentifier,
            duration: max(0, payload.duration ?? fallback.duration),
            elapsedTime: max(0, elapsedTime),
            timestamp: timestamp,
            playbackRate: playbackRate,
            isPlaying: isPlaying,
            artwork: Self.artworkImage(fromBase64: payload.artworkData)
                ?? (usesDiff ? fallback.artwork : nil)
                ?? Self.appIcon(fromBundleIdentifier: bundleIdentifier)
        )
    }

    private func adapterScriptURL() -> URL? {
        Bundle.main.url(
            forResource: "mediaremote-adapter",
            withExtension: "pl",
            subdirectory: "Features/MediaControls/mediaremote-adapter"
        ) ?? findBundledResource(named: "mediaremote-adapter.pl")
    }

    private func adapterFrameworkURL() -> URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework")
            ?? Bundle.main.url(
            forResource: "MediaRemoteAdapter",
            withExtension: "framework",
            subdirectory: "Features/MediaControls/mediaremote-adapter"
        ) ?? findBundledResource(named: "MediaRemoteAdapter.framework")
    }

    private func findBundledResource(named name: String) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL,
              let enumerator = FileManager.default.enumerator(
                at: resourceURL,
                includingPropertiesForKeys: nil
              ) else { return nil }

        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    private static func artworkImage(fromBase64 value: String?) -> NSImage? {
        guard let value,
              let data = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return NSImage(data: data)
    }

    private static func appName(from pid: Int32) -> String {
        guard pid > 0,
              let app = NSRunningApplication(processIdentifier: pid) else { return "" }
        return app.localizedName ?? app.bundleIdentifier ?? ""
    }

    private static func bundleIdentifier(from pid: Int32) -> String {
        guard pid > 0,
              let app = NSRunningApplication(processIdentifier: pid) else { return "" }
        return app.bundleIdentifier ?? ""
    }

    private static func appName(fromBundleIdentifier bundleIdentifier: String) -> String? {
        guard !bundleIdentifier.isEmpty else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.localizedName
            ?? Bundle(identifier: bundleIdentifier)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(identifier: bundleIdentifier)?.object(forInfoDictionaryKey: "CFBundleName") as? String
    }

    private static func appIcon(fromBundleIdentifier bundleIdentifier: String) -> NSImage? {
        guard !bundleIdentifier.isEmpty else { return nil }

        if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.icon {
            return icon
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    private static func estimatedElapsed(for info: MediaNowPlayingInfo, at date: Date) -> TimeInterval {
        guard info.isPlaying, info.timestamp > .distantPast else { return info.elapsedTime }
        let elapsed = info.elapsedTime + max(0, date.timeIntervalSince(info.timestamp)) * max(info.playbackRate, 1)
        return min(max(elapsed, 0), max(info.duration, 0))
    }

    private static let adapterDateFormatter = ISO8601DateFormatter()
}

private struct MediaRemoteAdapterUpdate: Decodable {
    let payload: MediaRemoteAdapterPayload
    let diff: Bool?
}

private struct MediaRemoteAdapterPayload: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
}
