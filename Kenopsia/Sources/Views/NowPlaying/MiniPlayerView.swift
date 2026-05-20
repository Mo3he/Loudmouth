import SwiftUI

// MARK: - MiniPlayerView
/// Compact now-playing bar that sits above the tab bar.
struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerViewModel
    @Environment(\.kAccent) var accent

    var body: some View {
        if player.state.status != .stopped {
            HStack(spacing: 14) {
                MiniArtworkView(
                    cacheKey: player.queue.currentTrack?.artworkCacheKey
                        ?? player.state.nowPlayingArtworkCacheKey
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(accent)
                            .frame(width: 5, height: 5)
                            .opacity(player.state.status == .playing ? 1 : 0)
                        Text("NOW PLAYING")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(accent)
                    }
                    Text(player.queue.currentTrack?.title ?? "")
                        .font(.system(.subheadline, design: .default).bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text((player.queue.currentTrack?.artist ?? "").uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 18) {
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.state.status == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(accent)
                            .frame(width: max(0, geo.size.width * CGFloat(player.state.progress)), height: 2)
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
                .padding(.bottom, 7)
            }
            .padding(.horizontal, 10)
            .shadow(color: .black.opacity(0.3), radius: 16, y: 4)
            .onTapGesture { player.showingNowPlaying = true }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring, value: player.state.status)
        }
    }
}

// MARK: - MiniArtworkView
struct MiniArtworkView: View {
    let cacheKey: String?
    @State private var artworkImage: UIImage?

    var body: some View {
        Group {
            if let img = artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.07)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear { loadArtwork() }
        .onChange(of: cacheKey) { _, _ in loadArtwork() }
        .onReceive(NotificationCenter.default.publisher(for: ArtworkCache.artworkDidUpdate)) { notification in
            guard let updatedKey = notification.userInfo?["key"] as? String,
                  updatedKey == cacheKey else { return }
            loadArtwork()
        }
    }

    private func loadArtwork() {
        guard let key = cacheKey else { artworkImage = nil; return }
        artworkImage = ArtworkCache.shared.thumbnailImage(forKey: key)
    }
}

