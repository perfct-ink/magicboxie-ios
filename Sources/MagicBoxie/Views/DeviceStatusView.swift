import SwiftUI

/// Everything about the physical device in one place: Bluetooth connection
/// status/control (absorbed from the old Settings > Device Bluetooth
/// screen), a WiFi reachability check (absorbed from Settings > Device
/// WiFi), and sync status sourced from MagicBoxie-web (when the device last
/// checked in, which movies are flagged to sync to it, and - live - what
/// it's downloading right now).
struct DeviceStatusView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @EnvironmentObject private var webClient: MagicBoxieWebClient
    @State private var isRefreshing = false
    @State private var showingShutdownConfirmation = false
    @State private var showingWiFiProvisioning = false
    @State private var wifiTestState: WiFiTestState = .idle

    private enum WiFiTestState: Equatable {
        case idle
        case testing
        case success(movieCount: Int)
        case failure(String)
    }

    /// Ordered last_seen_at desc by the server - the most recently-checked-in
    /// device is what this single-device-oriented product cares about, even
    /// though the schema (and this list) technically supports more than one.
    private var lastCheckIn: RemoteDevice? {
        webClient.devices.first
    }

    private var syncedMovies: [RemoteMovie] {
        webClient.movies.filter { $0.syncEnabled }
    }

    var body: some View {
        List {
            bluetoothSection
            if let message = bleManager.deviceUpdateStatus {
                Section {
                    ProgressView(message)
                }
            }
            wifiSection
            if webClient.isAuthenticated {
                deviceInfoSection
                syncedMoviesSection
            } else {
                mediaLibraryPromptSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Device")
        .refreshable { await refresh() }
        .task { await refresh() }
        .alert("Power Off Device?", isPresented: $showingShutdownConfirmation) {
            Button("Power Off", role: .destructive) {
                bleManager.shutdownDevice()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The device will shut down completely. There's no way to turn it back on remotely - you'll need to physically power-cycle it.")
        }
        .sheet(isPresented: $showingWiFiProvisioning) {
            WiFiProvisioningSheet()
                .environmentObject(bleManager)
        }
    }

    // MARK: - Bluetooth

    @ViewBuilder
    private var bluetoothSection: some View {
        Section {
            if bleManager.connectionState == .connected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Movies on Device", value: "\(bleManager.movies.count)")
                apiCompatibilityWarning
                bluetoothResetWarning
            } else {
                ConnectionStatusView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        } header: {
            Text("Bluetooth")
        }
        .listRowBackground(Color.appElevatedSurface)

        if bleManager.connectionState == .connected, AppConfig.mode == .bluetooth {
            Section {
                Button("Forget Device", role: .destructive) {
                    bleManager.forgetDevice()
                }
            } footer: {
                Text("Clears this app's own connection info and rescans. If problems persist, also use iOS Settings ▸ Bluetooth ▸ MagicBoxieDevice ▸ Forget This Device.")
            }
            .listRowBackground(Color.appElevatedSurface)
        }
    }

    /// Warns when this app build and the connected device disagree on the
    /// wire protocol (BLEManager.apiCompatibility) - most likely direction
    /// in practice is the device being ahead, since redeploying it is a
    /// much lighter operation than shipping a new build of this app to a
    /// physical phone.
    @ViewBuilder
    private var apiCompatibilityWarning: some View {
        switch bleManager.apiCompatibility {
        case .compatible:
            EmptyView()
        case .appOutdated:
            compatibilityWarning("This device has been updated - download a new version of MagicBoxie to keep using all of its features.")
        case .deviceOutdated:
            compatibilityWarning("This device is running older software than this app expects - redeploy the latest version to it.")
        }
    }

    /// Shown after BLEManager has already tried to self-recover once (see
    /// its handleReadFailure) and it didn't help - the one case that
    /// genuinely needs the user, since iOS's own system-level per-
    /// peripheral cache is outside any app's reach to clear itself. Most
    /// often follows the device's BLE service having been redeployed/
    /// restarted while this phone was already connected.
    @ViewBuilder
    private var bluetoothResetWarning: some View {
        if bleManager.needsBluetoothReset {
            compatibilityWarning("Bluetooth connection needs a reset: go to Settings ▸ Bluetooth ▸ MagicBoxieDevice ▸ Forget This Device, then reconnect.")
        }
    }

    private func compatibilityWarning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
    }

    // MARK: - WiFi

    /// Address/reachability are read-only here - BLE always carries
    /// commands regardless of what this shows, see
    /// BLEManager.uploadMovieIfNeeded/pushThumbnailToDeviceIfNeeded for
    /// WiFi's actual job (bulk data only). "Join a Different Network" is
    /// the one WiFi control path this has: for switching the device onto a
    /// network with no BLE connection needed once it's provisioned - e.g.
    /// an iPhone's Personal Hotspot in a car, where there's no home WiFi to
    /// fall back on.
    private var wifiSection: some View {
        Section {
            if let url = bleManager.wifiBaseURL {
                LabeledContent("Address", value: url.absoluteString)
            } else {
                Text("Device not yet discovered on WiFi")
                    .foregroundStyle(.secondary)
            }

            wifiTestResult

            Button("Test Connection") {
                Task { await testWiFiConnection() }
            }
            .disabled(bleManager.wifiBaseURL == nil || wifiTestState == .testing)

            if AppConfig.mode == .bluetooth {
                Button("Join a Different Network…") {
                    showingWiFiProvisioning = true
                }
            }
        } header: {
            Text("WiFi")
        }
        .listRowBackground(Color.appElevatedSurface)
    }

    @ViewBuilder
    private var wifiTestResult: some View {
        switch wifiTestState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .success(let count):
            Label("Connected — \(count) movie(s) found", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }

    private func testWiFiConnection() async {
        guard let url = bleManager.wifiBaseURL else { return }
        wifiTestState = .testing
        do {
            let movies = try await DeviceHTTPClient(baseURL: url).fetchMovies()
            wifiTestState = .success(movieCount: movies.count)
        } catch {
            wifiTestState = .failure(error.localizedDescription)
        }
    }

    // MARK: - Device info / sync (MagicBoxie-web)

    private var deviceInfoSection: some View {
        Section {
            if let ip = bleManager.deviceIPAddress {
                LabeledContent("IP Address", value: ip)
            }
            temperatureRow
            throttleWarnings
            if let title = bleManager.syncingMovieTitle {
                LabeledContent("Downloading", value: title)
            } else if let lastCheckIn {
                if let date = lastCheckIn.lastSeenAt {
                    LabeledContent("Last Checked In", value: date.formatted(.relative(presentation: .named)))
                }
            } else {
                Text("No device has checked in yet")
                    .foregroundStyle(.secondary)
            }
            if AppConfig.mode == .bluetooth {
                Button("Power Off Device", role: .destructive) {
                    showingShutdownConfirmation = true
                }
            }
        } header: {
            Text("Device")
        }
        .listRowBackground(Color.appElevatedSurface)
    }

    /// Color-coded by rough Pi Zero W heat stage - real hardware
    /// thresholds (Raspberry Pi's own soft/hard throttle points sit around
    /// 80-85°C), not arbitrary ones: comfortable idle temps stay green,
    /// getting warm under load is yellow, actually hot is orange, and
    /// anywhere near where throttling actually kicks in is red.
    @ViewBuilder
    private var temperatureRow: some View {
        if let temp = bleManager.cpuTemperatureCelsius {
            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.0f°C", temp))
                    .fontWeight(.semibold)
                    .foregroundStyle(Self.temperatureColor(for: temp))
            }
        }
    }

    private static func temperatureColor(for celsius: Double) -> Color {
        switch celsius {
        case ..<50: return .green
        case 50..<65: return .yellow
        case 65..<80: return .orange
        default: return .red
        }
    }

    /// vcgencmd get_throttled's "right now" bits - both nil (device hasn't
    /// reported yet, or vcgencmd isn't available) and false are silent;
    /// only an actual true shows anything, since these are meant to be
    /// alarming when they appear, not routine status.
    @ViewBuilder
    private var throttleWarnings: some View {
        if bleManager.underVoltage == true {
            compatibilityWarning("Under-voltage detected - check the power supply and cable.")
        }
        if bleManager.throttled == true {
            compatibilityWarning("Device is currently throttled (thermal or power) - performance may be reduced.")
        }
    }

    private var syncedMoviesSection: some View {
        Section {
            if syncedMovies.isEmpty && isRefreshing {
                ProgressView()
            } else if syncedMovies.isEmpty {
                Text("No movies are set to sync to a device")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(syncedMovies) { movie in
                    HStack {
                        Text(movie.name)
                        Spacer()
                        if bleManager.movies.contains(where: { $0.title == movie.name }) {
                            Label("On device", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                        } else if bleManager.syncingMovieTitle == movie.name {
                            ProgressView()
                        } else {
                            Label("Waiting to sync", systemImage: "clock")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Syncing to Device")
        }
        .listRowBackground(Color.appElevatedSurface)
    }

    private var mediaLibraryPromptSection: some View {
        Section {
            Text("Connect from the Media Library tab to see sync status.")
                .foregroundStyle(.secondary)
        } header: {
            Text("Syncing to Device")
        }
        .listRowBackground(Color.appElevatedSurface)
    }

    private func refresh() async {
        isRefreshing = true
        bleManager.refreshLibrary()
        async let devices: () = webClient.fetchDevices()
        async let movies: () = webClient.fetchMovies()
        async let deviceInfo: () = bleManager.refreshDeviceInfo()
        _ = await (devices, movies, deviceInfo)
        isRefreshing = false
    }
}

/// Sends new WiFi credentials to the device over BLE (see
/// BLEManager.provisionWiFi) - the one form in this app for joining the
/// device to a network (e.g. an iPhone's Personal Hotspot in a car) with
/// no phone-side network switching or SSH access needed.
private struct WiFiProvisioningSheet: View {
    @EnvironmentObject private var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss

    @State private var ssid = ""
    @State private var password = ""
    @State private var didSend = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Network Name", text: $ssid)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("The device will try to join this network - it can take several seconds (scanning, connecting, getting an address). Check the WiFi section here again shortly to see if it worked.")
                }

                if didSend {
                    Section {
                        Label("Sent to the device", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Join a Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        guard bleManager.provisionWiFi(ssid: ssid, password: password) else { return }
                        didSend = true
                        // A brief confirmation beat before closing, rather
                        // than dismissing instantly - the write itself is
                        // near-instant, but the device joining the network
                        // is not, so this at least confirms the credentials
                        // actually reached it before this screen goes away.
                        Task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            dismiss()
                        }
                    }
                    .disabled(ssid.trimmingCharacters(in: .whitespaces).isEmpty || didSend)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        DeviceStatusView()
            .environmentObject(BLEManager())
            .environmentObject(MagicBoxieWebClient())
    }
}
