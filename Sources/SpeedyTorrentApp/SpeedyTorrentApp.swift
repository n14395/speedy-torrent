import SwiftUI
import TorrentEngine

@main
struct SpeedyTorrentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = SessionStore()
    /// Owned here rather than by the list, because the main menu acts on it
    /// too and commands are built outside the view tree.
    @State private var listState = ListState()

    init() {
        // When launched via `swift run` there is no app bundle, so AppKit
        // starts us as a background process. Promote to a regular app so the
        // window and menu bar appear during development.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate()
        }
        #if SPARKLE
        SparkleUpdater.start()
        #endif
    }

    var body: some Scene {
        Window("SpeedyTorrent", id: "main") {
            TorrentListView()
                .environment(store)
                .environment(listState)
                .frame(minWidth: 720, minHeight: 360)
                .onAppear {
                    store.start()
                    appDelegate.store = store
                }
                .onOpenURL { url in
                    store.handleOpenedURL(url)
                }
        }
        .commands { TorrentCommands(store: store, listState: listState) }

        Window("Statistics", id: "stats") {
            StatisticsView()
                .environment(store)
        }
        .windowResizability(.contentSize)
        // Declared here rather than on the main window; see `WindowCommands`.
        .commands { WindowCommands() }

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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: SessionStore?
    private var terminationReplied = false

    /// Drops the Help menu. Its one stock item opens a help book this app does
    /// not ship, and emptying the command group leaves the menu itself behind
    /// with nothing in it — worse than the dead item it replaced.
    ///
    /// This sticks only because `SpeedyTorrentApp.body` reads no `@Observable`
    /// property: the body is evaluated once, so SwiftUI never rebuilds the menu
    /// bar and never puts Help back. Reading one there — `store.snapshots`,
    /// say, rather than passing `store` along — brings the menu back within the
    /// second. Menu *items* stay live regardless; SwiftUI refreshes those when
    /// a menu opens, which is why the commands read the store directly.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let menu = NSApp.mainMenu,
              let index = menu.items.firstIndex(where: { $0.submenu?.title == "Help" })
        else { return }
        menu.removeItem(at: index)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                self.store?.handleOpenedURL(url)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        // Flush resume data and say goodbye to trackers…
        Task { @MainActor in
            await store.shutdown()
            self.replyToTerminate(sender)
        }
        // …but quit regardless if that takes too long. Waiting on the network
        // here is what used to make Cmd-Q look like it did nothing.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.replyToTerminate(sender)
        }
        return .terminateLater
    }

    private func replyToTerminate(_ sender: NSApplication) {
        guard !terminationReplied else { return }
        terminationReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Off = closing the last window quits; on = keep seeding in the menu bar.
        !UserDefaults.standard.bool(forKey: Defaults.keepRunningInMenuBar)
    }
}
