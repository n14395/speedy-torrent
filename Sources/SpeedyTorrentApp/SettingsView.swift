import SwiftUI
import TorrentEngine

struct SettingsView: View {
    @Environment(SessionStore.self) private var store

    @AppStorage(Defaults.downloadDirectory) private var downloadDirectory = ""
    @AppStorage(Defaults.listenPort) private var listenPort = 6881
    @AppStorage(Defaults.sequentialDownload) private var sequentialDownload = false
    @AppStorage(Defaults.downloadRateLimitKiB) private var downloadRateLimitKiB = 0
    @AppStorage(Defaults.uploadRateLimitKiB) private var uploadRateLimitKiB = 0
    @AppStorage(Defaults.maxPeers) private var maxPeers = 40
    @AppStorage(Defaults.encryptionPolicy) private var encryptionPolicy = EncryptionPolicy.preferred.rawValue
    @AppStorage(Defaults.seedRatioLimit) private var seedRatioLimit = 0.0
    @AppStorage(Defaults.seedTimeLimitMinutes) private var seedTimeLimitMinutes = 0
    @AppStorage(Defaults.maxActiveDownloads) private var maxActiveDownloads = 0
    @AppStorage(Defaults.autoStartTorrents) private var autoStartTorrents = false
    @AppStorage(Defaults.keepRunningInMenuBar) private var keepRunningInMenuBar = true
    @AppStorage(Defaults.menuBarShowsIcon) private var menuBarShowsIcon = true
    @AppStorage(Defaults.menuBarShowsDownloadRate) private var menuBarShowsDownloadRate = true
    @AppStorage(Defaults.menuBarShowsUploadRate) private var menuBarShowsUploadRate = true

    @State private var showingFolderPicker = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Download folder") {
                    HStack {
                        Text(downloadDirectory.isEmpty ? "~/Downloads" : abbreviatedPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { showingFolderPicker = true }
                    }
                }
                Toggle(isOn: $sequentialDownload) {
                    Text("Sequential download")
                    Text("Fetch pieces in file order — useful for previewing media early. Slightly worse for swarm health.")
                }
                .onChange(of: sequentialDownload) { store.applySettings() }
                Toggle(isOn: $autoStartTorrents) {
                    Text("Start torrents automatically")
                    Text("Skip the window that opens when you add a torrent — it starts immediately with these settings and every file selected.")
                }
            } header: {
                Text("Defaults for New Torrents")
            } footer: {
                Text("Each torrent can override these in the inspector's Files tab (select it and press the sidebar button).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Speed Limits") {
                limitField("Download limit", value: $downloadRateLimitKiB)
                limitField("Upload limit", value: $uploadRateLimitKiB)
            }

            Section {
                LabeledContent("Stop seeding at ratio") {
                    HStack(spacing: 6) {
                        TextField("", value: $seedRatioLimit, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { store.applySettings() }
                        Text("0 = unlimited").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: seedRatioLimit) { store.applySettings() }
                LabeledContent("Stop seeding after") {
                    HStack(spacing: 6) {
                        TextField("", value: $seedTimeLimitMinutes, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { store.applySettings() }
                        Text("minutes (0 = unlimited)").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: seedTimeLimitMinutes) { store.applySettings() }
                LabeledContent("Max active downloads") {
                    HStack(spacing: 6) {
                        TextField("", value: $maxActiveDownloads, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { store.applySettings() }
                        Text("0 = unlimited").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: maxActiveDownloads) { store.applySettings() }
            } header: {
                Text("Seeding")
            } footer: {
                Text("A finished torrent stops seeding once it reaches either limit; resuming it manually keeps it seeding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Network") {
                TextField("Listening port", value: $listenPort, format: .number.grouping(.never))
                    .frame(width: 220)
                Text("Port and peer-count changes take effect after relaunching the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Max peers per torrent", value: $maxPeers, format: .number)
                    .frame(width: 220)
                LabeledContent("Router port mapping") {
                    Text(store.portMappingStatus.summary)
                        .foregroundStyle(portMappingColor)
                }
                Picker("Encryption", selection: $encryptionPolicy) {
                    Text("Off").tag(EncryptionPolicy.disabled.rawValue)
                    Text("Prefer").tag(EncryptionPolicy.preferred.rawValue)
                    Text("Require").tag(EncryptionPolicy.required.rawValue)
                }
                .frame(width: 260)
                Text("MSE/PE obfuscates peer connections to resist ISP throttling and reach peers that require it. Changes apply after relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $keepRunningInMenuBar) {
                    Text("Keep running in the menu bar after closing the window")
                    Text("Transfers carry on in the background. Turn this off to quit SpeedyTorrent when you close its window.")
                }
                LabeledContent("Menu bar shows") {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Icon", isOn: $menuBarShowsIcon)
                            .disabled(menuBarShowsIcon && !menuBarShowsDownloadRate && !menuBarShowsUploadRate)
                        Toggle("Download speed", isOn: $menuBarShowsDownloadRate)
                        Toggle("Upload speed", isOn: $menuBarShowsUploadRate)
                    }
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Speeds appear only while something is transferring; the icon returns if you turn everything else off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Integration") {
                LabeledContent("Opens .torrent and magnet links") {
                    if store.isDefaultHandler {
                        Label("SpeedyTorrent", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 8) {
                            Text("Another app").foregroundStyle(.secondary)
                            Button("Make Default") { store.makeDefaultHandler() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { store.refreshDefaultHandlerStatus() }
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() {
                downloadDirectory = url.path
            }
        }
    }

    private var abbreviatedPath: String {
        (downloadDirectory as NSString).abbreviatingWithTildeInPath
    }

    private var portMappingColor: Color {
        switch store.portMappingStatus {
        case .mapped: .green
        case .failed: .secondary
        default: .secondary
        }
    }

    private func limitField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: value, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { store.applySettings() }
                Text("KiB/s (0 = unlimited)")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: value.wrappedValue) { store.applySettings() }
    }
}
