# SwiftTorrent

A simple, reliable BitTorrent client for macOS, written entirely in Swift — the
protocol engine has zero third-party dependencies.

![status](https://img.shields.io/badge/status-v0.1-blue)

- **Downloads** from `.torrent` files and **magnet links** (BEP 9/10 metadata
  exchange over a built-in mainline **DHT** node, BEP 5)
- **HTTP(S) and UDP trackers** (BEP 3/15/12/23), compact + IPv6 peer lists
- **Seeds** with the classic tit-for-tat choke algorithm
- **Fast resume** — verified pieces are remembered across launches; tampered
  files are detected and re-checked
- **Per-torrent settings** — download location (existing content is moved
  safely when changed), sequential piece order, and **per-file selection**
  (checkbox file tree with tri-state folders, name/size sorting; only wanted
  files are downloaded, and files that share no data with any wanted file are
  never even created on disk). Available both when adding a torrent and after.
- **`.part` files** — in-progress files are written as `<name>.part` and
  renamed to their final name the moment every piece covering them verifies,
  so finished files are obvious at a glance
- **Global speed limits**, defaults for new torrents in Settings,
  per-torrent pause/resume
- Menu bar item with live transfer rates and pause/resume-all
- Registered handler for `magnet:` links and `.torrent` files (drag-and-drop,
  Finder double-click, paste)
- Download-complete notifications

## Layout

| Path | What it is |
|---|---|
| `Sources/TorrentEngine` | The engine library: bencode, metainfo, trackers, peer wire, pieces, storage, DHT, session |
| `Sources/SwiftTorrentApp` | SwiftUI app (window + menu bar + settings) |
| `Sources/storrent` | CLI harness (`info`, `create`, `announce`, `download`, `seed`, `magnet`, `dht`) |
| `Tests/TorrentEngineTests` | Unit tests + loopback end-to-end suites |
| `Scripts/` | build/test/bundle helpers |

## Building

Requires macOS 15+ and a Swift 6 toolchain. Two equivalent ways to build:

**Xcode** — open `SwiftTorrent.xcodeproj`, then build/run the **SwiftTorrent**
scheme (targets: the app, the `storrent` CLI, `TorrentEngine`, and tests). The
project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen);
after editing `project.yml`, run `xcodegen generate` to refresh it.

**SwiftPM / command line** — no Xcode project needed:

```sh
Scripts/test.sh        # run the full test suite
Scripts/bundle.sh      # build dist/SwiftTorrent.app (release, ad-hoc signed)
```

The scripts prefer a full Xcode install (`/Applications/Xcode[-beta].app`),
where plain `swift build` / `swift test` just work. With Command Line Tools
only, they fall back to the flags CLT needs: rpaths and a `-plugin-path` for
Swift Testing, and `SDKROOT` pinned to the bundled 26.5 SDK (the macOS 27 beta
SDK's SwiftUI macros require a plugin CLT doesn't ship).

For ad-hoc engine work:

```sh
swift build
.build/…/storrent download something.torrent ~/Downloads
.build/…/storrent magnet "magnet:?xt=urn:btih:…"
```

## Architecture notes

Everything is actor-based Swift concurrency; the engine never touches AppKit.
`TorrentSession` is the single public entry point — the app consumes 1 Hz
value-type `TorrentSnapshot`s and calls intent methods (`addTorrent`,
`addMagnet`, `pauseTorrent`, …).

Reliability decisions worth knowing about:

- Info-hashes are computed over the *original* bencoded bytes (never
  re-encoded), with byte ranges tracked by the decoder.
- Every piece is SHA-1 verified before it touches its final location; peers
  contributing to two corrupt pieces are banned.
- File paths from metadata are sanitized against directory traversal.
- Resume data is only trusted if file modification times are unchanged;
  otherwise the torrent is silently re-checked.
- The DHT node answers queries from the network (ping/find_node/get_peers/
  announce_peer with rotating tokens), so the client is a good citizen.

## Not in v1

BitTorrent v2 (BEP 52), encryption (MSE/PE), uTP, PEX, UPnP/NAT-PMP port
mapping, App Store sandboxing. The module boundaries leave room for all of
them.

## Note

Use it for content you have the right to download and share — Linux ISOs are
the canonical test material (this client was verified end-to-end against the
Debian netinst image, by .torrent and by trackerless magnet, checksums
matching).
