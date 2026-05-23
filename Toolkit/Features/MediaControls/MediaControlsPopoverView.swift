import SwiftUI

struct MediaControlsPopoverView: View {
    @ObservedObject var model: MediaControlsModel
    let preferredWidth: CGFloat

    init(model: MediaControlsModel, preferredWidth: CGFloat = 680) {
        self.model = model
        self.preferredWidth = preferredWidth
    }

    private var nowPlaying: MediaNowPlayingInfo {
        model.nowPlaying
    }

    var body: some View {
        HStack(spacing: 22) {
            artworkView

            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(nowPlaying.title.isEmpty ? "No media title" : nowPlaying.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if !displaySubtitle.isEmpty {
                        Text(displaySubtitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }

                TimelineView(.animation(minimumInterval: model.isPlaying ? 0.15 : nil)) { timeline in
                    let currentPosition = model.isScrubbing
                        ? model.scrubberPosition
                        : model.estimatedPosition(at: timeline.date)

                    VStack(spacing: 7) {
                        MediaProgressScrubber(
                            position: currentPosition,
                            duration: nowPlaying.duration,
                            onPositionChanged: { model.scrubberPosition = $0 },
                            onEditingChanged: { isEditing in
                                model.isScrubbing = isEditing
                                if !isEditing {
                                    model.seek(to: model.scrubberPosition)
                                }
                            }
                        )

                        HStack {
                            Text(formatTime(currentPosition))
                            Spacer()
                            Text(formatTime(nowPlaying.duration))
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.14, blue: 0.54))
                    }
                }

                HStack(spacing: 18) {
                    Spacer(minLength: 0)

                    controlButton(systemImage: "backward.fill", help: "Previous") {
                        model.previousTrack()
                    }

                    Button {
                        model.togglePlayPause()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 25, weight: .bold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 38)
                    }
                    .buttonStyle(.plain)
                    .help(model.isPlaying ? "Pause" : "Play")

                    controlButton(systemImage: "forward.fill", help: "Next") {
                        model.nextTrack()
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .frame(width: preferredWidth)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.42), radius: 24, x: 0, y: 16)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var displaySubtitle: String {
        if !nowPlaying.artist.isEmpty, !nowPlaying.album.isEmpty {
            return "\(nowPlaying.artist) · \(nowPlaying.album)"
        }

        if !nowPlaying.artist.isEmpty {
            return nowPlaying.artist
        }

        return nowPlaying.appName
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork = nowPlaying.artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.96, green: 0.05, blue: 0.34),
                            Color(red: 1.0, green: 0.24, blue: 0.52)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.76))
                )
                .frame(width: 116, height: 116)
        }
    }

    private func controlButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 34, height: 32)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainingSeconds))"
        }

        return "\(minutes):\(String(format: "%02d", remainingSeconds))"
    }
}

private struct MediaProgressScrubber: View {
    let position: TimeInterval
    let duration: TimeInterval
    let onPositionChanged: (TimeInterval) -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var isEditing = false

    private let thumbDiameter: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = max(geometry.size.width - thumbDiameter, 1)
            let progress = normalizedProgress
            let thumbOffset = trackWidth * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(duration > 0 ? 0.2 : 0.1))
                    .frame(height: 5)
                    .padding(.horizontal, thumbDiameter / 2)

                Capsule()
                    .fill(.white.opacity(0.88))
                    .frame(width: thumbOffset, height: 5)
                    .padding(.leading, thumbDiameter / 2)

                Circle()
                    .fill(.white.opacity(duration > 0 ? 0.96 : 0.52))
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: thumbOffset)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        onPositionChanged(position(for: value.location.x, trackWidth: trackWidth))
                    }
                    .onEnded { value in
                        guard isEditing else { return }
                        onPositionChanged(position(for: value.location.x, trackWidth: trackWidth))
                        isEditing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: thumbDiameter)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(formatAccessibilityTime(position))
    }

    private var normalizedProgress: CGFloat {
        guard duration > 0, duration.isFinite else { return 0 }
        return CGFloat(min(max(position / duration, 0), 1))
    }

    private func position(for x: CGFloat, trackWidth: CGFloat) -> TimeInterval {
        let progress = min(max((x - thumbDiameter / 2) / trackWidth, 0), 1)
        return TimeInterval(progress) * duration
    }

    private func formatAccessibilityTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 minutes, 0 seconds" }
        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return "\(minutes) minutes, \(remainingSeconds) seconds"
    }
}
