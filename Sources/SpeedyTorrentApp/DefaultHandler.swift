import AppKit
import UniformTypeIdentifiers

/// Whether LaunchServices routes `.torrent` files and `magnet:` links to this
/// app, and how to claim them. Both are declared in the bundle's Info.plist;
/// being *declared* only makes the app eligible, not the default.
enum DefaultHandler {
    /// The UTI the bundle declares for .torrent files.
    private static let torrentTypeIdentifier = "org.bittorrent.torrent"
    private static let magnetScheme = "magnet"

    /// A syntactically valid magnet link, used only to ask LaunchServices who
    /// would open one.
    private static let magnetProbe = URL(
        string: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000"
    )

    private static var torrentType: UTType? {
        UTType(torrentTypeIdentifier) ?? UTType(filenameExtension: "torrent")
    }

    /// False when another app owns the type, or when nothing does.
    static var handlesTorrentFiles: Bool {
        guard let torrentType,
              let handler = NSWorkspace.shared.urlForApplication(toOpen: torrentType)
        else { return false }
        return isSelf(handler)
    }

    static var handlesMagnetLinks: Bool {
        guard let magnetProbe,
              let handler = NSWorkspace.shared.urlForApplication(toOpen: magnetProbe)
        else { return false }
        return isSelf(handler)
    }

    static var handlesEverything: Bool { handlesTorrentFiles && handlesMagnetLinks }

    /// Only meaningful for a real app bundle — a `swift run` build isn't
    /// registered with LaunchServices and can't be anyone's default.
    static var isRegisterableBundle: Bool { Bundle.main.bundleIdentifier != nil }

    /// Claims whichever of the two this app doesn't already own. macOS asks
    /// the user to confirm some of these changes itself; returns the first
    /// error, or nil when everything succeeded.
    static func claimAll() async -> Error? {
        let app = Bundle.main.bundleURL
        var failure: Error?
        if let torrentType, !handlesTorrentFiles {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: torrentType)
            } catch {
                failure = error
            }
        }
        if !handlesMagnetLinks {
            do {
                try await NSWorkspace.shared.setDefaultApplication(
                    at: app, toOpenURLsWithScheme: magnetScheme
                )
            } catch {
                failure = failure ?? error
            }
        }
        return failure
    }

    enum PromptChoice {
        case claim, later, never
    }

    /// Asks (as a sheet on the main window) whether to take over the
    /// handlers. Does nothing when no window is open to attach to — the
    /// prompt simply waits for the next launch.
    @MainActor
    static func presentPrompt(completion: @escaping (PromptChoice) -> Void) {
        guard let window = NSApplication.shared.windows.first(where: {
            $0.isVisible && $0.canBecomeMain
        }) else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Open Torrents with SpeedyTorrent?"
        alert.informativeText = promptMessage()
        alert.addButton(withTitle: "Use SpeedyTorrent")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: completion(.claim)
            case .alertThirdButtonReturn: completion(.never)
            default: completion(.later)
            }
        }
    }

    /// Explains what is currently missing, naming the apps that hold the
    /// handlers instead (e.g. "…open in Transmission").
    static func promptMessage() -> String {
        var clauses: [String] = []
        if !handlesTorrentFiles {
            let handler = torrentType.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            clauses.append(".torrent files" + holder(of: handler))
        }
        if !handlesMagnetLinks {
            let handler = magnetProbe.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            clauses.append("magnet links" + holder(of: handler))
        }
        guard !clauses.isEmpty else {
            return "SpeedyTorrent already opens .torrent files and magnet links."
        }
        let subject = clauses.joined(separator: ", and ")
        return "Right now \(subject). Make SpeedyTorrent the default so double-clicking "
            + "a torrent or clicking a magnet link opens it here."
    }

    /// " open in Transmission" / " aren't handled by any app".
    private static func holder(of handler: URL?) -> String {
        guard let handler else { return " aren't handled by any app" }
        return " open in \(FileManager.default.displayName(atPath: handler.path))"
    }

    /// Matches on bundle identifier so another copy of SpeedyTorrent (say, the
    /// one in /Applications while a dev build runs) still counts as us.
    private static func isSelf(_ handler: URL) -> Bool {
        if let theirs = Bundle(url: handler)?.bundleIdentifier,
           let ours = Bundle.main.bundleIdentifier {
            return theirs == ours
        }
        return handler.resolvingSymlinksInPath().standardizedFileURL
            == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }
}
