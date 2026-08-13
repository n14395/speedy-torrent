import SwiftUI
import TorrentEngine

@main
struct SwiftTorrentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = SessionStore()

    init() {
        // When launched via `swift run` there is no app bundle, so AppKit
        // starts us as a background process. Promote to a regular app so the
        // window and menu bar appear during development.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate()
        }
    }

    var body: some Scene {
        Window("SwiftTorrent", id: "main") {
            TorrentListView()
                .environment(store)
                .frame(minWidth: 720, minHeight: 360)
                .onAppear {
                    store.start()
                    appDelegate.store = store
                }
                .onOpenURL { url in
                    store.handleOpenedURL(url)
                }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// Handles .torrent document opens from Finder/Dock and flushes engine state
/// (resume data, tracker "stopped" announces) before the process exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: SessionStore?

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                self.store?.handleOpenedURL(url)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task { @MainActor in
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running in the menu bar
    }
}
