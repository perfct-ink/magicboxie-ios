import SwiftUI

struct MovieLibraryView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @EnvironmentObject private var artworkStore: MovieArtworkStore
    @EnvironmentObject private var webClient: MagicBoxieWebClient

    @Binding var path: [Movie]
    @AppStorage("moviesListView") private var showsList = false
    @State private var refreshSpin = 0.0

    var body: some View {
        VStack(spacing: 0) {
            if let message = bleManager.deviceUpdateStatus {
                ProgressView(message)
                    .padding()
            }
            if bleManager.connectionState == .connected || !bleManager.movies.isEmpty {
                HStack {
                    Picker("Movie view", selection: $showsList) {
                        Text("Netflix").tag(false)
                        Text("List").tag(true)
                    }
                    .pickerStyle(.segmented)
                    refreshButton
                        .disabled(bleManager.connectionState != .connected)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            if bleManager.connectionState != .connected, !bleManager.movies.isEmpty {
                VStack(spacing: 8) {
                    ConnectionStatusView()
                    Text("Last known movies on device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            ScrollView {
                if bleManager.connectionState == .connected || !bleManager.movies.isEmpty {
                    if showsList {
                        MovieShelf(title: "Movies", movies: bleManager.movies,
                                   onSelect: { path.append($0) }, isList: true)
                            .padding(.vertical, 16)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            ForEach(MovieCategory.genreSections(for: bleManager.movies, genres: genreNames), id: \.genre) { section in
                                MovieShelf(
                                    title: section.genre,
                                    movies: section.movies,
                                    onSelect: { path.append($0) }
                                )
                            }
                            ForEach(MovieCategory.sections(for: bleManager.movies), id: \.category.rawValue) { section in
                                MovieShelf(
                                    title: section.category.rawValue,
                                    movies: section.movies,
                                    onSelect: { path.append($0) }
                                )
                            }
                        }
                        .padding(.vertical, 16)
                    }
                }
            }
            .refreshable {
                await refresh()
            }
            .task {
                // Kicks off the same bulk MagicBoxie-web fetch each
                // poster's own .task below already triggers lazily (see
                // MovieArtworkStore.fetchIfNeeded) - but genre rows are
                // evaluated synchronously during this view's own body, so
                // waiting on a POSTER to scroll into view first would leave
                // them empty on first launch even when a home server
                // session is already available. A no-op if already fetched
                // or not logged in.
                guard webClient.isAuthenticated, webClient.movies.isEmpty else { return }
                await webClient.fetchMovies()
            }
            .overlay {
                // Not connected: explain why and offer a way to connect,
                // rather than just an empty screen. Connected but genuinely
                // empty: a plain, simpler message - there's no connection
                // problem to explain or retry there.
                if bleManager.connectionState != .connected && bleManager.movies.isEmpty {
                    ConnectionStatusView()
                } else if bleManager.movies.isEmpty {
                    // BLE alone can list movies (see refreshLibraryViaBLE),
                    // but WiFi/HTTP is the primary, uncapped source - an
                    // empty list while wifiBaseURL is still nil is far more
                    // likely to mean the device's WiFi address was never
                    // resolved (see BLEManager.setWiFiBaseURL) than a
                    // genuinely empty library, so say so specifically
                    // instead of leaving that to guesswork.
                    if bleManager.wifiBaseURL == nil {
                        Text("Device WiFi is not connected")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No movies found on the device")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Keep playback controls available without adding navigation or
            // promotional chrome to the movie list itself.
            if bleManager.connectionState == .connected, let displayedMovie = bleManager.currentMovie {
                PlayerControlsView(movie: displayedMovie)
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .onChange(of: bleManager.connectionState) { state in
            if state != .connected { path.removeAll() }
        }
    }

    /// bleManager.refreshLibrary() isn't itself awaitable - the BLE read
    /// result arrives later via a delegate callback that updates
    /// bleManager.movies asynchronously, not as a direct response .refreshable
    /// can await. A short fixed delay just keeps the pull-to-refresh spinner
    /// on screen long enough for that to land in the common case (local BLE
    /// reads are near-instant) without adding continuation-based plumbing
    /// for what's a cosmetic concern, not a functional one - the list
    /// updates reactively off bleManager.movies regardless of when the
    /// spinner itself dismisses.
    private func refresh() async {
        guard bleManager.connectionState == .connected else { return }
        bleManager.refreshLibrary()
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    /// Looked up directly against webClient.movies (the whole bulk-fetched
    /// MagicBoxie-web library) rather than artworkStore.artworkByTitle -
    /// the latter only ever gets populated per-title, lazily, as each
    /// poster's own .task happens to run, which would leave genre rows
    /// missing titles whose poster hasn't rendered yet. The bulk fetch
    /// itself is the same one both this and every poster's lazy lookup
    /// share (see MovieArtworkStore.fetchIfNeeded and this view's own
    /// .task above).
    private func genreNames(for movie: Movie) -> [String] {
        webClient.movies.first { $0.name == movie.title }?.genreNames ?? []
    }

    private var refreshButton: some View {
        Button {
            bleManager.refreshLibrary()
            withAnimation(.easeInOut(duration: 0.5)) { refreshSpin += 360 }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .rotationEffect(.degrees(refreshSpin))
        }
    }

}

private struct MovieShelf: View {
    @EnvironmentObject private var bleManager: BLEManager
    @EnvironmentObject private var artworkStore: MovieArtworkStore
    @EnvironmentObject private var webClient: MagicBoxieWebClient

    let title: String
    let movies: [Movie]
    let onSelect: (Movie) -> Void

    var isList = false

    @State private var pendingDelete: Movie?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            if isList {
                LazyVStack(spacing: 8) { movieItems }
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) { movieItems }
                        .padding(.horizontal, 16)
                }
            }
        }
        .alert(
            "Delete \u{201C}\(pendingDelete?.title ?? "")\u{201D}?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                guard let movie = pendingDelete else { return }
                Task { await delete(movie) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the movie from the device. It won\u{2019}t be downloaded again automatically.")
        }
    }

    private var movieItems: some View {
                    ForEach(movies) { movie in
                        Button {
                            onSelect(movie)
                        } label: {
                            if isList {
                                HStack(spacing: 12) {
                                    ThumbnailImage(primaryURL: thumbnailURL(for: movie), fallbackURL: artworkStore.artwork(for: movie.title)?.posterURL)
                                        .frame(width: 40, height: 60)
                                        .clipped()
                                    Text(movie.title).foregroundStyle(.primary)
                                    Spacer()
                                    if bleManager.isMovieLoading(movie) { ProgressView().accessibilityLabel("Loading") }
                                    if (webClient.isDownloadedToPhone(title: movie.title) || bleManager.isDownloadedToPhone(title: movie.title)) {
                                        Image(systemName: "iphone")
                                            .accessibilityLabel("Downloaded to iPhone")
                                    }
                                }
                                .padding(.vertical, 6)
                            } else {
                            PosterCard(
                                title: movie.title,
                                primaryURL: thumbnailURL(for: movie),
                                fallbackURL: artworkStore.artwork(for: movie.title)?.posterURL,
                                isTranscoding: bleManager.transcodingMovieID == movie.id,
                                needsTranscoding: movie.needsTranscoding,
                                isLoading: bleManager.isMovieLoading(movie),
                                isDownloaded: (webClient.isDownloadedToPhone(title: movie.title) || bleManager.isDownloadedToPhone(title: movie.title))
                            )
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDelete = movie
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(bleManager.connectionState != .connected)
                        }
                        .task {
                            guard let artwork = await artworkStore.fetchIfNeeded(for: movie.title) else { return }
                            await bleManager.pushThumbnailToDeviceIfNeeded(movie: movie, artwork: artwork)
                        }
                    }
    }

    /// Deletes from the device first, then - only once that's actually
    /// confirmed to have happened - tells MagicBoxie-web this movie is no
    /// longer wanted here, so home-sync doesn't just pull it straight back
    /// down on the next check-in. Matched by title since Movie (the
    /// device's own id space) and RemoteMovie (MagicBoxie-web's) don't share
    /// an id scheme - same matching already used elsewhere (e.g.
    /// RemoteLibraryView's alreadyOnDevice check).
    private func delete(_ movie: Movie) async {
        guard await bleManager.deleteMovie(movie) else { return }
        if let remoteMatch = webClient.movies.first(where: { $0.name == movie.title }) {
            await webClient.setSyncEnabled(itemID: remoteMatch.id, enabled: false)
        }
    }

    private func thumbnailURL(for movie: Movie) -> URL? {
        let baseURL = bleManager.wifiBaseURL
            ?? (AppConfig.mode == .directAPI ? AppConfig.deviceHTTPBaseURL : nil)
        return baseURL?.appendingPathComponent("api/movies/\(movie.id)/thumbnail")
    }
}

#Preview {
    MovieLibraryView(path: .constant([]))
        .environmentObject(BLEManager())
        .environmentObject(MovieArtworkStore())
        .environmentObject(MagicBoxieWebClient())
}
