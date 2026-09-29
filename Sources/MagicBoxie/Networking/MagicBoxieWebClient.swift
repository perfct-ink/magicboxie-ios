import Foundation
import CryptoKit

private struct AuthResponse: Decodable {
    let accessToken: String
    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
    }
}

/// Talks to MagicBoxie-web (the home media server), speaking its
/// Jellyfin-compatible REST API: login, list movies, and download a movie's
/// bytes to disk so it can be handed off to DeviceHTTPClient.uploadMovie
/// for the push-to-device leg. Distinct from DeviceHTTPClient, which talks
/// to the Raspberry Pi device itself.
@MainActor
final class MagicBoxieWebClient: ObservableObject {
    @Published private(set) var isAuthenticated: Bool
    @Published private(set) var movies: [RemoteMovie] = []
    @Published private(set) var devices: [RemoteDevice] = []
    @Published var lastError: String?

    @Published private(set) var phoneDownloads: [String: RemoteMovie] = [:]
    @Published private(set) var downloadingToPhone: Set<String> = []
    @Published private(set) var phoneDownloadErrors: [String: String] = [:]

    private static var downloadsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DownloadedMovies", isDirectory: true)
    }

    private func downloadKey(for movie: RemoteMovie) -> String {
        SHA256.hash(data: Data("\(baseURL.absoluteString)|\(movie.id)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    var downloadedPhoneMovies: [RemoteMovie] {
        phoneDownloads.filter { $0.key == downloadKey(for: $0.value) }
            .map(\.value).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func isDownloadedToPhone(_ movie: RemoteMovie) -> Bool {
        phoneDownloads[downloadKey(for: movie)] != nil
    }

    func isDownloadedToPhone(title: String) -> Bool {
        phoneDownloads.values.contains { $0.name == title }
    }

    func isDownloadingToPhone(_ movie: RemoteMovie) -> Bool {
        downloadingToPhone.contains(downloadKey(for: movie))
    }

    func phoneDownloadError(for movie: RemoteMovie) -> String? {
        phoneDownloadErrors[downloadKey(for: movie)]
    }

    /// Keeps a separate permanent copy; device upload cleanup never removes it.
    func downloadToPhone(_ movie: RemoteMovie) async {
        let key = downloadKey(for: movie)
        guard !downloadingToPhone.contains(key), phoneDownloads[key] == nil else { return }
        downloadingToPhone.insert(key)
        phoneDownloadErrors[key] = nil
        defer { downloadingToPhone.remove(key) }
        let directory = Self.downloadsDirectory.appendingPathComponent(key, isDirectory: true)
        do {
            let temporaryFile = try await downloadMovie(movie)
            defer { try? FileManager.default.removeItem(at: temporaryFile) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excludedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excludedDirectory.setResourceValues(values)
            let file = directory.appendingPathComponent(temporaryFile.lastPathComponent)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            try FileManager.default.moveItem(at: temporaryFile, to: file)
            try JSONEncoder().encode(movie).write(to: directory.appendingPathComponent("movie.json"), options: .atomic)
            phoneDownloads[key] = movie
        } catch {
            try? FileManager.default.removeItem(at: directory)
            phoneDownloadErrors[key] = error.localizedDescription
        }
    }

    private func restorePhoneDownloads() {
        let directories = (try? FileManager.default.contentsOfDirectory(at: Self.downloadsDirectory, includingPropertiesForKeys: nil)) ?? []
        for directory in directories {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("movie.json")),
                  let movie = try? JSONDecoder().decode(RemoteMovie.self, from: data),
                  let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
                  files.contains(where: { $0.lastPathComponent != "movie.json" }) else { continue }
            phoneDownloads[directory.lastPathComponent] = movie
        }
    }

    private var baseURL: URL
    private let session: URLSession
    private static let tokenKey = "magicboxie_web_token"

    private var token: String? {
        didSet {
            if let token {
                KeychainStore.set(token, forKey: Self.tokenKey)
            } else {
                KeychainStore.remove(Self.tokenKey)
            }
        }
    }

    init(baseURL: URL = AppConfig.magicBoxWebBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        let storedToken = KeychainStore.get(Self.tokenKey)
        self.token = storedToken
        self.isAuthenticated = storedToken != nil
        restorePhoneDownloads()
    }

    /// Lets RemoteLibraryView point this client at a user-edited server URL
    /// (see AppConfig.magicBoxWebBaseURL) without tearing down and
    /// recreating the @StateObject that owns it - called right before
    /// `login`, whenever the field may have changed since this instance
    /// was created.
    func updateBaseURL(_ url: URL) {
        baseURL = url
    }

    func login(password: String) async {
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("Users/AuthenticateByName"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "Username": "magicboxie-ios",
                "Pw": password,
            ])

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = "Incorrect password"
                return
            }
            let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
            token = auth.accessToken
            isAuthenticated = true
            lastError = nil
        } catch {
            lastError = "Couldn't reach MagicBoxie-web at \(baseURL.absoluteString)"
        }
    }

    func logout() {
        token = nil
        isAuthenticated = false
        movies = []
        devices = []
    }

    func fetchMovies() async {
        guard let token else { return }

        var components = URLComponents(url: baseURL.appendingPathComponent("Users/1/Items"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "Movie"),
            URLQueryItem(name: "Recursive", value: "true"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                logout()
                return
            }
            let decoded = try JSONDecoder().decode(RemoteItemsResponse.self, from: data)
            movies = decoded.items
            lastError = nil
        } catch {
            lastError = "Couldn't load movies from MagicBoxie-web"
        }
    }

    /// Flags (or unflags) a movie as wanted on a magicboxie-device Pi - see
    /// SetDeviceSync on the server. Used when a movie is deleted from the
    /// device (see BLEManager.deleteMovie/MovieLibraryView), so home-sync
    /// doesn't just download it straight back on the next check-in.
    /// Returns whether it actually happened; @discardableResult since some
    /// callers (e.g. best-effort cleanup after a device-side delete) don't
    /// need to react to failure specially - RemoteLibraryView.syncEnabled
    /// itself stays authoritative on `movies` either way after the next fetch.
    @discardableResult
    func setSyncEnabled(itemID: String, enabled: Bool) async -> Bool {
        guard let token else { return false }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/items/\(itemID)/sync"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": enabled])

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            if let index = movies.firstIndex(where: { $0.id == itemID }) {
                movies[index].syncEnabled = enabled
            }
            return true
        } catch {
            return false
        }
    }

    /// Every magicboxie-device Pi that has ever checked in, and when it last
    /// did - see DeviceStatusView, and ListDevices on the server.
    func fetchDevices() async {
        guard let token else { return }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/devices"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                logout()
                return
            }
            let decoded = try JSONDecoder().decode(RemoteDevicesResponse.self, from: data)
            devices = decoded.devices
        } catch {
            // Best-effort and silent (unlike fetchMovies, doesn't set
            // lastError): this is a secondary status fetch DeviceStatusView
            // shows alongside movies, not something the login form's error
            // footer should get clobbered by.
        }
    }

    /// Downloads a movie to a local temp file, streaming to disk rather than
    /// buffering in memory -- these can be multi-gigabyte files. The caller
    /// (see RemoteLibraryView) hands the resulting URL to
    /// BLEManager.uploadMovieIfNeeded to push it onward to the device.
    func downloadMovie(_ movie: RemoteMovie) async throws -> URL {
        guard let token else { throw URLError(.userAuthenticationRequired) }

        var components = URLComponents(url: baseURL.appendingPathComponent("Videos/\(movie.id)/stream"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "static", value: "true")]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let ext = (movie.originalFilename as NSString).pathExtension
        let filename = movie.name.replacingOccurrences(of: "/", with: "-") + (ext.isEmpty ? ".mp4" : ".\(ext)")
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let destination = temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }
}
