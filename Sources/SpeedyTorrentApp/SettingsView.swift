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
            } header: {
                Text("Defaults for New Torrents")
            } footer: {
                Text("Each torrent can override these in its own settings (right-click → Settings…).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Speed Limits") {
                limitField("Download limit", value: $downloadRateLimitKiB)
                limitField("Upload limit", value: $uploadRateLimitKiB)
            }

            Section("Network") {
                TextField("Listening port", value: $listenPort, format: .number.grouping(.never))
                    .frame(width: 220)
                Text("Port and peer-count changes take effect after relaunching the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Max peers per torrent", value: $maxPeers, format: .number)
                    .frame(width: 220)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() {
                downloadDirectory = url.path
            }
        }
    }

    private var abbreviatedPath: String {
        (downloadDirectory as NSString).abbreviatingWithTildeInPath
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
