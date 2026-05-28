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
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(nowPlaying.title.isEmpty ? "No media title" : nowPlaying.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if !displaySecondaryText.isEmpty {
                            Text(displaySecondaryText)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 18) {
                    Spacer(minLength: 0)

                    controlButton(
                        systemImage: model.shouldSeekInsteadOfSkip ? "gobackward.10" : "backward.fill",
                        help: model.shouldSeekInsteadOfSkip ? "Back 10 seconds" : "Previous"
                    ) {
                        model.previousOrSeekBackward()
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

                    controlButton(
                        systemImage: model.shouldSeekInsteadOfSkip ? "goforward.10" : "forward.fill",
                        help: model.shouldSeekInsteadOfSkip ? "Forward 10 seconds" : "Next"
                    ) {
                        model.nextOrSeekForward()
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
        if !nowPlaying.artist.isEmpty {
            return nowPlaying.artist
        }

        return nowPlaying.appName
    }

    private var displaySecondaryText: String {
        if !nowPlaying.album.isEmpty {
            return nowPlaying.album
        }

        return displaySubtitle
    }

    @ViewBuilder
    private var artworkView: some View {
        Button {
            model.openNowPlayingApp()
        } label: {
            Group {
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
        }
        .buttonStyle(.plain)
        .help("Open current media app")
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
}

struct MediaControlsMenuBarView: View {
    @ObservedObject var model: MediaControlsModel
    let menuBarHeight: CGFloat
    private let artworkInset: CGFloat = 3

    var body: some View {
        HStack(spacing: 10) {
            artworkView

            controlButton(
                systemImage: model.shouldSeekInsteadOfSkip ? "gobackward.10" : "backward.fill",
                help: model.shouldSeekInsteadOfSkip ? "Back 10 seconds" : "Previous"
            ) {
                model.previousOrSeekBackward()
            }

            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause" : "Play")

            controlButton(
                systemImage: model.shouldSeekInsteadOfSkip ? "goforward.10" : "forward.fill",
                help: model.shouldSeekInsteadOfSkip ? "Forward 10 seconds" : "Next"
            ) {
                model.nextOrSeekForward()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: menuBarHeight)
        .background(
            RoundedRectangle(cornerRadius: max(8, (menuBarHeight / 2) - 1), style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: max(8, (menuBarHeight / 2) - 1), style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: max(8, (menuBarHeight / 2) - 1), style: .continuous))
    }

    private var artworkSize: CGFloat {
        max(menuBarHeight - (artworkInset * 2), 18)
    }

    @ViewBuilder
    private var artworkView: some View {
        Button {
            model.openNowPlayingApp()
        } label: {
            Group {
                if let artwork = model.nowPlaying.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: artworkSize, height: artworkSize)
                        .clipShape(RoundedRectangle(cornerRadius: max(6, artworkSize * 0.28), style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: max(6, artworkSize * 0.28), style: .continuous)
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
                                .font(.system(size: max(9, artworkSize * 0.42), weight: .semibold))
                                .foregroundStyle(.white.opacity(0.76))
                        )
                        .frame(width: artworkSize, height: artworkSize)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Open current media app")
    }

    private func controlButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
