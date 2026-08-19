import SwiftUI
import TorrentEngine

/// Settings, on the app's own panel and split across tabs. As one scroll it
/// ran taller than most screens, which made the last section — the one people
/// actually go looking for — the hardest to reach.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TransferSettings()
                .tabItem { Label("Transfers", systemImage: "speedometer") }
            NetworkSettings()
                .tabItem { Label("Network", systemImage: "network") }
            MenuBarSettings()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
        }
        .frame(width: 460)
    }
}

/// The frame every settings tab shares: panel background, one column of cards,
/// and a height that follows its content rather than the tallest tab.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Surface.panel)
        .frame(maxHeight: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(SessionStore.self) private var store
    @AppStorage(Defaults.downloadDirectory) private var downloadDirectory = ""
    @AppStorage(Defaults.sequentialDownload) private var sequentialDownload = false
    @AppStorage(Defaults.autoStartTorrents) private var autoStartTorrents = false
    @State private var showingFolderPicker = false

    var body: some View {
        SettingsPane {
            SurfaceSection(
                title: "Defaults for new torrents",
                footer: "Each torrent can override these in the inspector's Files tab."
            ) {
                SurfaceRow(label: "Download folder") {
                    HStack(spacing: 8) {
                        Text(downloadDirectory.isEmpty ? "~/Downloads" : abbreviatedPath)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        SurfaceButton(title: "Choose…") { showingFolderPicker = true }
                    }
                }
                SurfaceSeparator()
                SurfaceRow(
                    label: "Sequential download",
                    detail: "Fetch pieces in file order — useful for previewing media early. Slightly worse for swarm health."
                ) {
                    Toggle("Sequential download", isOn: $sequentialDownload)
                        .surfaceSwitch()
                        .onChange(of: sequentialDownload) { store.applySettings() }
                }
                SurfaceSeparator()
                SurfaceRow(
                    label: "Start torrents automatically",
                    detail: "Skip the window that opens when you add a torrent — it starts immediately with these settings and every file selected."
                ) {
                    Toggle("Start torrents automatically", isOn: $autoStartTorrents)
                        .surfaceSwitch()
                }
            }

            SurfaceSection(title: "Integration") {
                SurfaceRow(label: "Opens .torrent and magnet links") {
                    if store.isDefaultHandler {
                        Label("SpeedyTorrent", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 8) {
                            Text("Another app")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            SurfaceButton(title: "Make Default") { store.makeDefaultHandler() }
                        }
                    }
                }
            }
        }
        .onAppear { store.refreshDefaultHandlerStatus() }
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() { downloadDirectory = url.path }
        }
    }

    private var abbreviatedPath: String {
        (downloadDirectory as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Transfers

private struct TransferSettings: View {
    @Environment(SessionStore.self) private var store
    @AppStorage(Defaults.downloadRateLimitKiB) private var downloadRateLimitKiB = 0
    @AppStorage(Defaults.uploadRateLimitKiB) private var uploadRateLimitKiB = 0
    @AppStorage(Defaults.seedRatioLimit) private var seedRatioLimit = 0.0
    @AppStorage(Defaults.seedTimeLimitMinutes) private var seedTimeLimitMinutes = 0
    @AppStorage(Defaults.maxActiveDownloads) private var maxActiveDownloads = 0

    var body: some View {
        SettingsPane {
            SurfaceSection(title: "Speed limits", footer: "0 means unlimited.") {
                limitRow("Download limit", value: $downloadRateLimitKiB)
                SurfaceSeparator()
                limitRow("Upload limit", value: $uploadRateLimitKiB)
            }

            SurfaceSection(
                title: "Seeding",
                footer: "A finished torrent stops seeding once it reaches either limit; resuming it manually keeps it seeding. 0 means unlimited."
            ) {
                SurfaceRow(label: "Stop seeding at ratio") {
                    TextField("", value: $seedRatioLimit, format: .number.precision(.fractionLength(0...2)))
                        .surfaceField(width: 76)
                        .onSubmit { store.applySettings() }
                        .onChange(of: seedRatioLimit) { store.applySettings() }
                }
                SurfaceSeparator()
                SurfaceRow(label: "Stop seeding after", detail: "minutes") {
                    TextField("", value: $seedTimeLimitMinutes, format: .number)
                        .surfaceField(width: 76)
                        .onSubmit { store.applySettings() }
                        .onChange(of: seedTimeLimitMinutes) { store.applySettings() }
                }
                SurfaceSeparator()
                SurfaceRow(label: "Max active downloads") {
                    TextField("", value: $maxActiveDownloads, format: .number)
                        .surfaceField(width: 76)
                        .onSubmit { store.applySettings() }
                        .onChange(of: maxActiveDownloads) { store.applySettings() }
                }
            }
        }
    }

    private func limitRow(_ title: String, value: Binding<Int>) -> some View {
        SurfaceRow(label: title, detail: "KiB/s") {
            TextField("", value: value, format: .number)
                .surfaceField(width: 76)
                .onSubmit { store.applySettings() }
                .onChange(of: value.wrappedValue) { store.applySettings() }
        }
    }
}

// MARK: - Network

private struct NetworkSettings: View {
    @Environment(SessionStore.self) private var store
    @AppStorage(Defaults.listenPort) private var listenPort = 6881
    @AppStorage(Defaults.maxPeers) private var maxPeers = 40
    @AppStorage(Defaults.encryptionPolicy) private var encryptionPolicy = EncryptionPolicy.preferred.rawValue

    private let policies = [
        EncryptionPolicy.disabled.rawValue,
        EncryptionPolicy.preferred.rawValue,
        EncryptionPolicy.required.rawValue,
    ]

    var body: some View {
        SettingsPane {
            SurfaceSection(
                title: "Connections",
                footer: "Port and peer-count changes take effect after relaunching the app."
            ) {
                SurfaceRow(label: "Listening port") {
                    TextField("", value: $listenPort, format: .number.grouping(.never))
                        .surfaceField(width: 76)
                }
                SurfaceSeparator()
                SurfaceRow(label: "Max peers per torrent") {
                    TextField("", value: $maxPeers, format: .number)
                        .surfaceField(width: 76)
                }
                SurfaceSeparator()
                SurfaceRow("Router port mapping", store.portMappingStatus.summary)
            }

            SurfaceSection(
                title: "Encryption",
                footer: "MSE/PE obfuscates peer connections to resist ISP throttling and reach peers that require it. Changes apply after relaunch."
            ) {
                PillSegmentedControl(
                    options: policies,
                    title: { policy in
                        switch policy {
                        case EncryptionPolicy.disabled.rawValue: "Off"
                        case EncryptionPolicy.required.rawValue: "Require"
                        default: "Prefer"
                        }
                    },
                    selection: $encryptionPolicy
                )
                .padding(10)
            }
        }
    }
}

// MARK: - Menu bar

private struct MenuBarSettings: View {
    @AppStorage(Defaults.keepRunningInMenuBar) private var keepRunningInMenuBar = true
    @AppStorage(Defaults.menuBarShowsIcon) private var menuBarShowsIcon = true
    @AppStorage(Defaults.menuBarShowsDownloadRate) private var menuBarShowsDownloadRate = true
    @AppStorage(Defaults.menuBarShowsUploadRate) private var menuBarShowsUploadRate = true

    var body: some View {
        SettingsPane {
            SurfaceSection(title: "Background") {
                SurfaceRow(
                    label: "Keep running after closing the window",
                    detail: "Transfers carry on in the background. Turn this off to quit SpeedyTorrent when you close its window."
                ) {
                    Toggle("Keep running", isOn: $keepRunningInMenuBar).surfaceSwitch()
                }
            }

            SurfaceSection(
                title: "Menu bar shows",
                footer: "Speeds appear only while something is transferring; the icon returns if you turn everything else off."
            ) {
                SurfaceRow(label: "Icon") {
                    Toggle("Icon", isOn: $menuBarShowsIcon)
                        .surfaceSwitch()
                        .disabled(menuBarShowsIcon && !menuBarShowsDownloadRate && !menuBarShowsUploadRate)
                }
                SurfaceSeparator()
                SurfaceRow(label: "Download speed") {
                    Toggle("Download speed", isOn: $menuBarShowsDownloadRate).surfaceSwitch()
                }
                SurfaceSeparator()
                SurfaceRow(label: "Upload speed") {
                    Toggle("Upload speed", isOn: $menuBarShowsUploadRate).surfaceSwitch()
                }
            }
        }
    }
}
