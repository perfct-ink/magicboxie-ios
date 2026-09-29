import SwiftUI

struct MovieDetailView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss
    let movie: Movie
    let artwork: RemoteMovie?

    private let headerHeight: CGFloat = 380

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                    .padding(.bottom, 4)

                VStack(alignment: .leading, spacing: 16) {
                    if movie.durationSeconds > 0 {
                        Text("\(movie.durationSeconds / 60) min")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let overview = artwork?.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.body)
                    }

                    HStack(spacing: 12) {
                        Button {
                            bleManager.playNow(movie)
                            dismiss()
                        } label: {
                            Label("Play Now", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.appAccent)

                        Button {
                            bleManager.enqueue(movie)
                            dismiss()
                        } label: {
                            Label("Add to Queue", systemImage: "text.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                    .disabled(bleManager.connectionState != .connected)
                }
                .padding(.horizontal)
            }
            .padding(.bottom)
        }
        .ignoresSafeArea(edges: .top)
        .background(Color.appBackground.ignoresSafeArea())
    }

    /// Full-bleed backdrop (falling back to the poster, then the device's own
    /// thumbnail) with the title sitting on a bottom gradient, matching the
    /// hero banner's treatment on the library screen. A fixed height (rather
    /// than .aspectRatio + .frame(maxWidth:)) is what actually bounds this
    /// inside a ScrollView: with height otherwise unconstrained,
    /// ThumbnailImage's internal .fill aspect ratio has nothing to fit within
    /// and blows up to an enormous cropped size instead of a sensible banner.
    /// The GeometryReader (rather than .frame(maxWidth: .infinity) directly
    /// on the image) is what makes the width behave - reading the
    /// container's actual resolved width and applying it explicitly
    /// sidesteps AsyncImage's own internal sizing preferences, which
    /// otherwise bled past the screen edges.
    private var header: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                ThumbnailImage(
                    primaryURL: artwork?.backdropURL
                        ?? AppConfig.deviceHTTPBaseURL.appendingPathComponent("api/movies/\(movie.id)/thumbnail"),
                    fallbackURL: artwork?.posterURL,
                    maxPixelSize: 1200
                )
                .frame(width: geo.size.width, height: headerHeight)
                .clipped()

                LinearGradient(
                    colors: [.clear, .clear, Color.appBackground.opacity(0.9), Color.appBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: geo.size.width, height: headerHeight)

                Text(movie.title)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                    .shadow(radius: 6)
                    .padding(.horizontal)
                    .padding(.bottom, 20)
            }
            .frame(width: geo.size.width, height: headerHeight)
        }
        .frame(height: headerHeight)
    }
}

#Preview {
    MovieDetailView(
        movie: Movie(id: 0, title: "Star Wars", durationSeconds: 7620),
        artwork: nil
    )
    .environmentObject(BLEManager())
}
