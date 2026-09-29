import Foundation

/// Talks to the MagicBoxie device's plain HTTP transport (magicboxie_device.views.web_service),
/// used by dev mode to exercise the real device (library scan, mpv control) over the
/// phone's WiFi/localhost connection instead of BLE.
struct DeviceMovie: Decodable {
    let id: Int
    let title: String
    let durationSeconds: Int
    let needsTranscoding: Bool

    enum CodingKeys: String, CodingKey {
        case id, title
        case durationSeconds = "duration_seconds"
        case needsTranscoding = "needs_transcoding"
    }
}

struct DeviceStatus: Decodable {
    let status: String
    let movieID: Int?
    let positionSeconds: Int
    /// The movie HomeServerSync is currently downloading from MagicBoxie-web,
    /// if any - nil the rest of the time (device is idle, or the movie
    /// still playing/paused, are unrelated to this).
    let syncingMovieTitle: String?
    let updateStatus: String?
    /// The SoC's own thermal sensor - see util.cpu_temperature_celsius on
    /// the device side. nil there (and here) if the sensor isn't readable,
    /// which shouldn't be mistaken for "the device is fine."
    let cpuTemperatureCelsius: Double?
    /// vcgencmd get_throttled's "right now" bits - nil if vcgencmd isn't
    /// available (see util.get_throttle_status), not "false."
    let underVoltage: Bool?
    let throttled: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case movieID = "movie_id"
        case positionSeconds = "position_seconds"
        case syncingMovieTitle = "syncing_movie_title"
        case updateStatus = "update_status"
        case cpuTemperatureCelsius = "cpu_temperature_celsius"
        case underVoltage = "under_voltage"
        case throttled
    }
}

struct DeviceVersion: Decodable {
    let apiVersion: Int
    let ipAddress: String

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case ipAddress = "ip_address"
    }
}

enum DeviceOpcode: String {
    case play, pause, stop, seek
    case selectMovie = "select_movie"
}

final class DeviceHTTPClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetchMovies() async throws -> [DeviceMovie] {
        let (data, _) = try await session.data(from: baseURL.appendingPathComponent("api/movies"))
        return try JSONDecoder().decode([DeviceMovie].self, from: data)
    }

    func fetchStatus() async throws -> DeviceStatus {
        let (data, _) = try await session.data(from: baseURL.appendingPathComponent("api/status"))
        return try JSONDecoder().decode(DeviceStatus.self, from: data)
    }

    func fetchVersion() async throws -> DeviceVersion {
        let (data, _) = try await session.data(from: baseURL.appendingPathComponent("api/version"))
        return try JSONDecoder().decode(DeviceVersion.self, from: data)
    }

    func sendCommand(_ opcode: DeviceOpcode, argument: Int? = nil) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/command"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["opcode": opcode.rawValue]
        if let argument {
            body["argument"] = argument
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await session.data(for: request)
    }

    /// Permanently removes a movie from the device (source file, any
    /// transcoded copy, thumbnail, metadata) - see the device's
    /// DELETE /api/movies/{id}.
    func deleteMovie(id: Int) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/movies/\(id)"))
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    /// Pushes a phone-fetched "official" poster (from MagicBoxie-web) back to the
    /// device so it can serve it to other devices that connect later, even
    /// with no internet access of their own.
    func uploadThumbnail(movieID: Int, imageData: Data) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/movies/\(movieID)/thumbnail"))
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = imageData
        _ = try await session.data(for: request)
    }

    /// Uploads a whole video file (e.g. shared in from Photos/Dropbox/Files)
    /// so the device adds it to its library. Streams from disk rather than
    /// loading the file into memory first - these can be multi-gigabyte files.
    func uploadMovie(filename: String, fileURL: URL) async throws -> DeviceMovie {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/movies"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(DeviceMovie.self, from: data)
    }
}
