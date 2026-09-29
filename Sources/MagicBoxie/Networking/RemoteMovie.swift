import Foundation

/// A movie as MagicBoxie-web (the home server) reports it -- decoded straight
/// from its Jellyfin-compatible /Users/{id}/Items response. Field names
/// match the wire format (see magicboxie-web's items_controller.go); the
/// MagicBoxie*-prefixed fields are that server's own additive extensions
/// (status/progress/original filename) real Jellyfin has no concept of.
struct RemoteMovie: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let overview: String?
    let productionYear: Int?
    let runTimeTicks: Int64?
    let status: String
    let originalFilename: String
    /// Whether this movie is flagged to sync down to a magicboxie-device Pi
    /// - see magicboxie-web's SetDeviceSync/RegisterDevice and DeviceStatusView.
    /// var, not let: MagicBoxieWebClient.setSyncEnabled updates this in place
    /// on `movies` after a successful call, rather than requiring a full
    /// re-fetch just to reflect its own change.
    var syncEnabled: Bool
    /// Presence (not content) is all that matters - real Jellyfin uses the
    /// tag's value for cache-busting, which this app doesn't need since
    /// AsyncImage keys on the URL and a poster/backdrop change gets a new
    /// magicboxie-web UpdatedAt-derived tag anyway (see items_controller.go).
    private let imageTags: [String: String]?
    private let backdropImageTags: [String]?
    /// TMDB-sourced (see magicboxie-web's internal/services/tmdb), only
    /// present once that server has actually matched the movie - nil (not
    /// an empty array), same "maybe absent" convention as imageTags/
    /// backdropImageTags above, since Go's `omitempty` drops the key
    /// entirely rather than sending `[]`.
    private let genres: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case runTimeTicks = "RunTimeTicks"
        case status = "MagicBoxieStatus"
        case originalFilename = "MagicBoxieOriginalFilename"
        case syncEnabled = "MagicBoxieSyncEnabled"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case genres = "Genres"
    }

    /// Always an array, never nil - callers (see MovieCategory.genreSections)
    /// don't need to know "no genres" and "not matched yet" are the same
    /// wire-level absence.
    var genreNames: [String] { genres ?? [] }

    var isReady: Bool { status == "ready" }

    var durationMinutes: Int {
        guard let ticks = runTimeTicks else { return 0 }
        return Int(ticks / 10_000_000 / 60)
    }

    /// nil when magicboxie-web has no poster for this movie yet, rather than a
    /// URL that would just 404 - callers already fall back gracefully
    /// (see ThumbnailImage), but there's no reason to make them find that
    /// out over the network.
    var posterURL: URL? {
        guard imageTags?["Primary"] != nil else { return nil }
        return AppConfig.magicBoxWebBaseURL.appendingPathComponent("Items/\(id)/Images/Primary")
    }

    /// Wide promotional art used for the hero banner and detail-view header.
    var backdropURL: URL? {
        guard let backdropImageTags, !backdropImageTags.isEmpty else { return nil }
        return AppConfig.magicBoxWebBaseURL.appendingPathComponent("Items/\(id)/Images/Backdrop/0")
    }
}

struct RemoteItemsResponse: Decodable {
    let items: [RemoteMovie]
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}
