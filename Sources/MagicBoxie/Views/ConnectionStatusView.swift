import SwiftUI

/// Connection state + a connect/retry action, shared between the Movies
/// view (shown inline whenever there's nothing else to display) and the
/// full-screen Settings > Connect to Device screen. Renders nothing for
/// .connected - callers show their own content for that case instead,
/// since what belongs there differs (a movie grid vs. a device summary).
struct ConnectionStatusView: View {
    @EnvironmentObject private var bleManager: BLEManager

    var body: some View {
        switch bleManager.connectionState {
        case .disconnected:
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Not connected to MagicBoxie")
                    .foregroundStyle(.secondary)
                Button(AppConfig.mode == .directAPI ? "Connect to Server" : "Scan for MagicBoxie") {
                    bleManager.retry()
                }
                .buttonStyle(.borderedProminent)
                .tint(.appAccent)
            }
        case .scanning:
            VStack(spacing: 12) {
                ProgressView()
                Text("Scanning for MagicBoxie…")
                    .foregroundStyle(.secondary)
            }
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text(AppConfig.mode == .bluetooth ? "Scanning for MagicBoxie…" : "Connecting…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Retry") { bleManager.retry() }
                    .buttonStyle(.borderedProminent)
                    .tint(.appAccent)
            }
        case .connected:
            EmptyView()
        }
    }
}

#Preview {
    ConnectionStatusView()
        .environmentObject(BLEManager())
}
