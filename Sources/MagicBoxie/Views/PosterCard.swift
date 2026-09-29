import SwiftUI

/// A single poster in a Netflix-style horizontal shelf: artwork first, with
/// the title kept small underneath rather than overlaid - the library this
/// browses can be entirely offline (BLE-only, no MagicBoxie-web reachable),
/// where artwork is often just the generic clapperboard, so the title can't
/// live only as text baked into a promotional image the way real Netflix
/// rows get away with.
struct PosterCard: View {
    let title: String
    let primaryURL: URL?
    let fallbackURL: URL?
    /// Whether the device is currently re-encoding this movie in its
    /// background transcode worker - see BLEManager.transcodingMovieID.
    var isTranscoding: Bool = false
    /// Whether the device still needs to (re-)encode this movie at all -
    /// true for anything TranscodeService hasn't gotten to yet, including
    /// (but not limited to) the one movie isTranscoding is currently true
    /// for - see Movie.needsTranscoding.
    var needsTranscoding: Bool = false

    var isLoading = false
    var isDownloaded = false

    static let width: CGFloat = 126

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailImage(primaryURL: primaryURL, fallbackURL: fallbackURL)
                .frame(width: Self.width, height: Self.width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if isTranscoding {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(6)
                    } else if needsTranscoding {
                        Image(systemName: "hourglass")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 5, y: 3)

            HStack(spacing: 4) {
                if isLoading { ProgressView().controlSize(.small).accessibilityLabel("Loading") }
                if isDownloaded {
                    Image(systemName: "iphone")
                        .accessibilityLabel("Downloaded to iPhone")
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
            .frame(width: Self.width, alignment: .leading)
        }
    }
}
