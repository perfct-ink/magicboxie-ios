import SwiftUI

struct PlayerControlsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @EnvironmentObject private var artworkStore: MovieArtworkStore
    let movie: Movie
    @State private var showingNowPlaying = false

    private var isLoading: Bool {
        bleManager.pendingMovie?.id == movie.id
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Opens the full player with scrubbing and queue controls.
                Button {
                    showingNowPlaying = true
                } label: {
                    HStack(spacing: 12) {
                        ThumbnailImage(
                            primaryURL: AppConfig.deviceHTTPBaseURL.appendingPathComponent("api/movies/\(movie.id)/thumbnail"),
                            fallbackURL: artworkStore.artwork(for: movie.title)?.posterURL
                        )
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("NOW PLAYING")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1.1)
                                .foregroundStyle(Color.appAccent)
                            Text(movie.title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                if isLoading {
                    ProgressView()
                } else {
                    Button {
                        switch bleManager.playbackState.status {
                        case .playing:
                            bleManager.pause()
                        case .paused:
                            bleManager.play()
                        case .stopped:
                            // Nothing's loaded on the device once truly
                            // stopped (e.g. this movie reached its natural
                            // end) - a bare play() would be a no-op, so
                            // re-select and start it again from scratch.
                            bleManager.playNow(movie)
                        }
                    } label: {
                        Image(systemName: bleManager.playbackState.status == .playing ? "pause.fill" : "play.fill")
                    }
                    .tint(.appAccent)
                }

                if !bleManager.queue.isEmpty {
                    Button {
                        bleManager.skipToNext()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            // A count badge, not just the bare skip icon - the
                            // queue itself is otherwise only visible after
                            // opening the full Now Playing screen, so there was
                            // no way to tell "something's queued" (let alone
                            // how much) from the mini player alone.
                            .overlay(alignment: .topTrailing) {
                                Text("\(bleManager.queue.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(Color.appAccent, in: Circle())
                                    .offset(x: 8, y: -8)
                            }
                    }
                    .tint(.primary)
                }
            }
            HStack(spacing: 12) {
                Button {
                    bleManager.skipBackwardOneMinute()
                } label: {
                    Image(systemName: "gobackward.60")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back 1 minute")

                ProgressView(
                    value: isLoading ? 0 : max(0, min(Double(bleManager.playbackState.positionSeconds), Double(movie.durationSeconds))),
                    total: max(1, Double(movie.durationSeconds))
                )
                .progressViewStyle(.linear)
                .accessibilityLabel("Playback progress")

                Button {
                    bleManager.skipForwardOneMinute()
                } label: {
                    Image(systemName: "goforward.60")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Forward 1 minute")
            }
            .tint(.appAccent)
            .disabled(isLoading || bleManager.playbackState.status == .stopped)
        }
        .font(.system(size: 22))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .background(Color.appElevatedSurface.opacity(0.92))
        // .sheet, not .fullScreenCover: fullScreenCover has no built-in
        // interactive dismiss at all (no swipe-down-to-close gesture,
        // system or otherwise) - .presentationDetents([.large]) gets the
        // same effectively-full-screen look while keeping the sheet's
        // native drag-to-dismiss, the same way Apple Music/Podcasts' own
        // now-playing screen works.
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView(movie: movie)
                .environmentObject(bleManager)
                .environmentObject(artworkStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Consume each playback request once so returning to Movies does not reopen the player.
        .onAppear {
            if bleManager.consumeNowPlayingPresentation() { showingNowPlaying = true }
        }
        // Single-parameter form - this project targets iOS 16, and the
        // two-parameter onChange(of:initial:_:) needs 17.
        .onChange(of: movie.id) { _ in
            if bleManager.consumeNowPlayingPresentation() { showingNowPlaying = true }
        }
    }
}

#Preview {
    PlayerControlsView(movie: Movie(id: 0, title: "Star Wars", durationSeconds: 7620))
        .environmentObject(BLEManager())
        .environmentObject(MovieArtworkStore())
}
