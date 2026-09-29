import SwiftUI

/// Browse movies on MagicBoxie-web (the home server) and download them
/// straight to the device: a two-hop flow (server -> phone -> device) that
/// reuses BLEManager.uploadMovieIfNeeded for the second hop, the same path
/// the Share Extension already uses.
struct RemoteLibraryView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @EnvironmentObject private var webClient: MagicBoxieWebClient
    @AppStorage(AppConfig.magicBoxWebURLDefaultsKey) private var serverURLOverride = ""

    @State private var showsDownloads = false
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var isRefreshing = false
    @State private var rowStatus: [String: RowStatus] = [:]

    // Not private: RemoteMovieDetailView (a separate file, reached by
    // tapping a row) needs this same type to show a matching action state.
    enum RowStatus: Equatable {
        case downloading
        case sending
        case done
        /// Downloaded to the phone but the device isn't reachable yet -
        /// BLEManager.flushPendingUploads sends it on automatically the
        /// next time the device shows up, with no further action needed
        /// here (though this @State-backed status itself won't reflect
        /// that later success unless this view still happens to be open).
        case queued
        case failed
    }

    var body: some View {
        Group {
            if webClient.isAuthenticated || showsDownloads {
                libraryList
            } else {
                VStack {
                    if !webClient.downloadedPhoneMovies.isEmpty {
                        Button("View iPhone Downloads") { showsDownloads = true }
                            .padding()
                    }
                    loginForm
                }
            }
        }
        .navigationTitle("Cloud Library")
        .task {
            if webClient.isAuthenticated {
                await refresh()
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
    }

    private var loginForm: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    Image("MBMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityLabel("MagicBoxie")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section {
                TextField(AppConfig.magicBoxWebBaseURL.absoluteString, text: $serverURLOverride)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("MagicBoxie-web password", text: $password)
                    .textContentType(.password)
                Button {
                    Task {
                        isLoggingIn = true
                        webClient.updateBaseURL(AppConfig.magicBoxWebBaseURL)
                        await webClient.login(password: password)
                        isLoggingIn = false
                        if webClient.isAuthenticated {
                            password = ""
                            await refresh()
                        }
                    }
                } label: {
                    if isLoggingIn {
                        ProgressView()
                    } else {
                        Text("Connect")
                    }
                }
                .tint(.appAccent)
                .disabled(password.isEmpty || isLoggingIn)
            } header: {
                Text("Server")
            } footer: {
                if let error = webClient.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
    }

    private var displayedMovies: [RemoteMovie] {
        showsDownloads
            ? webClient.downloadedPhoneMovies
            : webClient.movies
    }

    private var libraryList: some View {
        List {
            ForEach(displayedMovies) { movie in
                MovieRow(
                    movie: movie,
                    status: rowStatus[movie.id],
                    alreadyOnDevice: bleManager.connectionState == .connected && bleManager.movies.contains { $0.title == movie.name },
                    isDownloaded: webClient.isDownloadedToPhone(movie) || bleManager.isDownloadedToPhone(title: movie.name),
                    onDownload: { Task { await downloadAndSend(movie) } }
                )
                .listRowBackground(Color.appElevatedSurface)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Library", selection: $showsDownloads) {
                Text("Media Server").tag(false)
                Text("iPhone Downloads").tag(true)
            }
            .pickerStyle(.segmented)
            .padding()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if displayedMovies.isEmpty {
                if isRefreshing {
                    ProgressView()
                } else {
                    Text(showsDownloads ? "No movies downloaded to iPhone yet" : "No movies on MagicBoxie-web yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Sign Out") { webClient.logout() }
                    .tint(.appAccent)
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        await webClient.fetchMovies()
        isRefreshing = false
    }

    private func downloadAndSend(_ movie: RemoteMovie) async {
        rowStatus[movie.id] = .downloading
        do {
            let fileURL = try await webClient.downloadMovie(movie)
            rowStatus[movie.id] = .sending
            // Always stages through BLEManager's pending-uploads directory
            // rather than uploading directly: if the device isn't reachable
            // right now, the movie stays there (safe from the OS purging a
            // temp file mid-wait) and BLEManager sends it on automatically
            // the next time the device is - no separate "is it reachable"
            // check needed here, and no race between checking and acting.
            await bleManager.queueForDeviceUpload(fileURL: fileURL)
            rowStatus[movie.id] = bleManager.movies.contains { $0.title == movie.name } ? .done : .queued
        } catch {
            rowStatus[movie.id] = .failed
        }
    }

    private struct MovieRow: View {
        @EnvironmentObject private var webClient: MagicBoxieWebClient
        let movie: RemoteMovie
        let status: RowStatus?
        let alreadyOnDevice: Bool
        let isDownloaded: Bool
        let onDownload: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                // Only the thumbnail/title portion navigates - trailingControl
                // stays a sibling outside the NavigationLink (its own
                // .buttonStyle(.borderless) below is what keeps its tap from
                // also triggering the navigation) so the download button
                // keeps working independently of tapping through to Detail.
                NavigationLink {
                    RemoteMovieDetailView(
                        movie: movie,
                        status: status,
                        alreadyOnDevice: alreadyOnDevice,
                        onDownload: onDownload
                    )
                } label: {
                    HStack(spacing: 12) {
                        ThumbnailImage(primaryURL: movie.posterURL, fallbackURL: nil)
                            .frame(width: 40, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                        VStack(alignment: .leading) {
                            HStack {
                                Text(movie.name)
                                if isDownloaded {
                                    Image(systemName: "iphone")
                                        .accessibilityLabel("Downloaded to iPhone")
                                }
                            }
                            HStack(spacing: 4) {
                                if let year = movie.productionYear {
                                    Text(String(year))
                                }
                                if movie.durationMinutes > 0 {
                                    Text("\u{00B7} \(movie.durationMinutes) min")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    // Otherwise a NavigationLink's label tints with the
                    // accent color - this keeps the row's plain-text look.
                    .foregroundStyle(.primary)
                }
                Spacer()
                PhoneDownloadButton(movie: movie)
                trailingControl
            }
        }

        @ViewBuilder
        private var trailingControl: some View {
            switch status {
            case .downloading:
                ProgressView()
            case .sending:
                ProgressView().accessibilityLabel("Sending to device")
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .queued:
                // Re-checked live (rather than trusting the stale .queued
                // status forever) since BLEManager.flushPendingUploads can
                // finish this in the background, with nothing to tell this
                // view's own rowStatus about it directly.
                if alreadyOnDevice {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary)
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case nil:
                if alreadyOnDevice {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                } else if movie.isReady {
                    Button(action: onDownload) {
                        Image(systemName: "tv.badge.wifi")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Send to MagicBoxie")
                    .tint(.appAccent)
                } else {
                    Text(movie.status.replacingOccurrences(of: "_", with: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RemoteLibraryView()
            .environmentObject(BLEManager())
            .environmentObject(MagicBoxieWebClient())
    }
}
