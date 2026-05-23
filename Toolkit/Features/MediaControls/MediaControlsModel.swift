import AppKit
import Combine
import Foundation

@MainActor
final class MediaControlsModel: ObservableObject {
    @Published var nowPlaying: MediaNowPlayingInfo = .empty
    @Published var scrubberPosition: Double = 0
    @Published var isScrubbing = false
    @Published private(set) var isPlaybackActive = false

    private let client: MediaRemoteClient
    private var previousInfo: MediaNowPlayingInfo = .empty
    private var previousSampleDate: Date?

    init(client: MediaRemoteClient) {
        self.client = client
    }

    var hasMedia: Bool {
        nowPlaying.hasContent || isPlaybackActive
    }

    var isPlaying: Bool {
        isPlaybackActive
    }

    func receive(_ info: MediaNowPlayingInfo) {
        isPlaybackActive = detectActivePlayback(for: info)
        previousInfo = info
        previousSampleDate = Date()
        nowPlaying = info
        if !isScrubbing {
            scrubberPosition = estimatedPosition(at: Date(), for: info)
        }
    }

    func refresh(completion: (() -> Void)? = nil) {
        client.fetchNowPlaying { [weak self] info in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receive(info)
                completion?()
            }
        }
    }

    func togglePlayPause() {
        nowPlaying = nowPlaying.withTimeline(
            elapsedTime: estimatedPosition(),
            timestamp: Date(),
            playbackRate: nowPlaying.playbackRate,
            isPlaying: !isPlaybackActive
        )
        scrubberPosition = nowPlaying.elapsedTime
        isPlaybackActive.toggle()
        client.togglePlayPause()
        refreshSoon()
    }

    func pause() {
        client.pause()
        refreshSoon()
    }

    func previousTrack() {
        client.previousTrack()
        refreshSoon()
    }

    func nextTrack() {
        client.nextTrack()
        refreshSoon()
    }

    func seek(to position: Double) {
        scrubberPosition = min(max(position, 0), max(nowPlaying.duration, 0))
        client.seek(to: position)
        refreshSoon()
    }

    func estimatedPosition(at date: Date = Date()) -> Double {
        estimatedPosition(at: date, for: nowPlaying)
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh()
        }
    }

    private func detectActivePlayback(for info: MediaNowPlayingInfo) -> Bool {
        if info.isPlaying || info.playbackRate > 0 { return true }
        guard info.hasContent else { return false }
        guard previousInfo.hasContent, isSameMedia(info, previousInfo) else { return false }
        guard let previousSampleDate else { return false }

        let sampleDelta = Date().timeIntervalSince(previousSampleDate)
        guard sampleDelta > 0.25, sampleDelta < 4 else { return false }

        let elapsedDelta = info.elapsedTime - previousInfo.elapsedTime
        return elapsedDelta > 0.2
    }

    private func isSameMedia(_ lhs: MediaNowPlayingInfo, _ rhs: MediaNowPlayingInfo) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.appName == rhs.appName
    }

    private func estimatedPosition(at date: Date, for info: MediaNowPlayingInfo) -> Double {
        guard info.duration > 0 else { return 0 }
        guard !isScrubbing else { return scrubberPosition }

        var elapsed = info.elapsedTime
        if isPlaybackActive, info.timestamp > .distantPast {
            elapsed += max(0, date.timeIntervalSince(info.timestamp)) * max(info.playbackRate, 1)
        }
        return min(max(elapsed, 0), info.duration)
    }
}
