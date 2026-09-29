import SwiftUI

/// Full-screen playback controls, reached by tapping the compact mini
/// player (PlayerControlsView). Has room for the things that don't fit
/// there: a scrubbable progress bar, ±1 minute skip, and previous/next.
struct NowPlayingView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @EnvironmentObject private var artworkStore: MovieArtworkStore
    @Environment(\.dismiss) private var dismiss
    let movie: Movie

    // While dragging the scrubber, the slider shows the drag position
    // instead of the live polled position - otherwise a status update
    // arriving mid-drag would yank the handle out from under your thumb.
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    private var isLoading: Bool {
        bleManager.pendingMovie?.id == movie.id
    }

    private var duration: Double {
        max(1, Double(movie.durationSeconds))
    }

    private var displayedPosition: Double {
        isScrubbing ? scrubPosition : max(0, min(Double(bleManager.playbackState.positionSeconds), duration))
    }

    var body: some View {
        VStack(spacing: 24) {
            // Collapses back to the mini player ONLY - playback keeps going
            // on the device untouched, same as backgrounding any other
            // now-playing screen. Stopping is a separate, explicit action
            // (see stopButton below); this button used to do both, which
            // meant there was no way to just check something else in the
            // app without also killing what's on the TV. Centered (VStack's
            // default alignment) and sitting directly above the artwork
            // with no Spacer in between - a top Spacer here made the gap
            // above it grow/shrink with however much room was left over on
            // screen instead of staying a fixed, predictable distance below
            // the sheet's own system drag indicator (see
            // PlayerControlsView.presentationDragIndicator).
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .padding(.top, 12)

            ThumbnailImage(
                primaryURL: AppConfig.deviceHTTPBaseURL.appendingPathComponent("api/movies/\(movie.id)/thumbnail"),
                fallbackURL: artworkStore.artwork(for: movie.title)?.posterURL
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 32)
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)

            Text(movie.title)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)

            progressBar

            transportControls

            stopButton

            Spacer()

            if !bleManager.queue.isEmpty {
                queueSection
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { displayedPosition },
                    set: { scrubPosition = $0 }
                ),
                in: 0...duration,
                onEditingChanged: { editing in
                    if editing {
                        scrubPosition = displayedPosition
                        isScrubbing = true
                    } else {
                        bleManager.seek(toSeconds: Int(scrubPosition))
                        isScrubbing = false
                    }
                }
            )
            .tint(.appAccent)
            .accessibilityLabel("Playback progress")
            .disabled(isLoading || movie.durationSeconds <= 0 || bleManager.playbackState.status == .stopped)

            HStack {
                Text(Self.formatTime(displayedPosition))
                Spacer()
                Text("-\(Self.formatTime(duration - displayedPosition))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }

    private var transportControls: some View {
        HStack(spacing: 36) {
            Button {
                bleManager.skipToPrevious()
            } label: {
                Image(systemName: "backward.end.fill")
            }

            Button {
                bleManager.skipBackwardOneMinute()
            } label: {
                Image(systemName: "gobackward.60")
            }
            .accessibilityLabel("Back 1 minute")
            .disabled(isLoading || bleManager.playbackState.status == .stopped)

            if isLoading {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                Button {
                    switch bleManager.playbackState.status {
                    case .playing:
                        bleManager.pause()
                    case .paused:
                        bleManager.play()
                    case .stopped:
                        // Reached its natural end - nothing loaded on the
                        // device to resume, so start it over from scratch.
                        bleManager.playNow(movie)
                    }
                } label: {
                    Image(systemName: bleManager.playbackState.status == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 34))
                }
            }

            Button {
                bleManager.skipForwardOneMinute()
            } label: {
                Image(systemName: "goforward.60")
            }
            .accessibilityLabel("Forward 1 minute")
            .disabled(isLoading || bleManager.playbackState.status == .stopped)

            Button {
                bleManager.skipToNext()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(bleManager.queue.isEmpty)
            .opacity(bleManager.queue.isEmpty ? 0.35 : 1)
        }
        .font(.system(size: 22))
        .foregroundStyle(.white)
        .tint(.white)
    }

    /// Unlike the chevron above (which only collapses this screen, leaving
    /// playback running), this is the actual "stop" action: stops playback
    /// (returning the device's own screen to its thumbnail-grid menu, not
    /// just closing this iOS view) and leaves. Explicit dismiss() rather
    /// than relying on stop() clearing currentMovie to implicitly cascade-
    /// dismiss this sheet through its now-gone presenting view, since that
    /// path isn't guaranteed to be immediate - and dismiss() runs before
    /// stop() specifically because stop() clears bleManager.currentMovie,
    /// which is what conditionally mounts PlayerControlsView (the view
    /// that owns this fullScreenCover) in the first place; clearing it
    /// before dismiss() runs yanks the presenting view out from under the
    /// dismissal in the same update cycle, which could leave the cover
    /// stuck on screen with no valid presenter left to animate it away.
    private var stopButton: some View {
        Button(role: .destructive) {
            dismiss()
            bleManager.stop()
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UP NEXT")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            List {
                ForEach(bleManager.queue) { queuedMovie in
                    Text(queuedMovie.title)
                        .foregroundStyle(.white)
                        .listRowBackground(Color.appElevatedSurface)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                bleManager.removeFromQueue(queuedMovie)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: 44 * CGFloat(min(bleManager.queue.count, 3)))
        }
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

#Preview {
    NowPlayingView(movie: Movie(id: 0, title: "Star Wars", durationSeconds: 7620))
        .environmentObject(BLEManager())
        .environmentObject(MovieArtworkStore())
}
