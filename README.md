# SpeedyTorrent

A fast, reliable BitTorrent client for macOS, written entirely in Swift.
The protocol engine is built from scratch with **zero third-party
dependencies** — no libtorrent, no bundled daemon, just Swift concurrency and
Apple's system frameworks.

![status](https://img.shields.io/badge/status-v0.1-blue)
![platform](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6-orange)
![tests](https://img.shields.io/badge/tests-101%20passing-brightgreen)

## Features

**Downloading**
- `.torrent` files and **magnet links** — metadata is fetched in the
  background the moment a magnet is opened, so the add dialog fills in the
  name, size, and file list live, before you confirm
- **Web seeds** (BEP 19): pieces are pulled from HTTP mirrors alongside the
  swarm — well-mirrored content downloads even with zero peers
- **Per-file selection** with a tri-state checkbox file tree (name/size
  sorting); unwanted files that share no piece with a wanted file are never
  even created on disk
- **Sequential download** as a per-torrent option, for previewing media early
- In-progress files carry a `.part` suffix and are renamed the instant every
  piece covering them verifies

**Swarm & network**
- Built-in mainline **DHT** node (BEP 5) that answers queries from the
  network, **peer exchange** (BEP 11), and **local peer discovery** (BEP 14)
- HTTP(S) and UDP trackers (BEP 15) with tiered failover (BEP 12), compact
  and IPv6 peer lists (BEP 23 / 7)
- **Protocol encryption** (MSE/PE) — off / prefer / require — to reach
  encryption-only peers and resist traffic shaping
- **NAT-PMP port mapping** (PCP-compatible routers included) so peers can
  reach you behind a home router, with live status in Settings
- Classic tit-for-tat choking with optimistic unchoke while seeding

**Managing**
- **Queue**: cap concurrent active downloads; extra torrents wait in line, are
  promoted automatically on completion, and can be reordered (order survives
  restarts)
- **Seeding goals**: stop seeding at a share ratio and/or after a time limit
- **Fast resume** across launches; tampered files are detected and re-checked,
  and a **Verify Data** action re-hashes on demand
- Per-torrent download location — existing content is moved safely when
  changed — plus global speed limits and per-torrent pause/resume
- Sortable, searchable torrent list with status filters, and a status bar
  showing totals, DHT size, port-mapping state, and encryption mode
- **Inspector** panel: a live per-torrent **speed graph**, peers (client,
  rates, flags, encryption), tracker health per tier, per-file progress, and
  torrent info with one-click **Copy Magnet Link**
- **Statistics** window: aggregate transfer graph plus session and all-time
  downloaded/uploaded/ratio counters, persisted across launches

**macOS app**
- Menu bar item with live transfer rates and pause/resume-all
- Dock icon shows aggregate download progress while anything is downloading
- Registered handler for `magnet:` links and `.torrent` files (drag-and-drop,
  Finder double-click, paste)
- Download-complete notifications

## Getting started

Requires **macOS 15+**. Download a release DMG, drag the app to Applications,
and on first launch right-click → **Open** (the app is ad-hoc signed, not
notarized, so Gatekeeper warns once), or run:

```sh
xattr -dr com.apple.quarantine /Applications/SpeedyTorrent.app
```

## Building from source

Requires a Swift 6 toolchain. Two equivalent ways to build:

**Xcode** — open `SpeedyTorrent.xcodeproj` and run the **SpeedyTorrent**
scheme. The project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen); after editing `project.yml`,
run `xcodegen generate` to refresh it.

**Command line** — plain SwiftPM, no Xcode project needed:

```sh
Scripts/test.sh    # run the full test suite
Scripts/build.sh   # build dist/SpeedyTorrent.app + a distributable .dmg
```

The scripts prefer a full Xcode install (`/Applications/Xcode[-beta].app`) and
fall back to Command Line Tools with the extra flags CLT needs (Swift Testing
rpaths/plugin path, pinned SDK).

### CLI harness

`storrent` exercises the engine without the UI — handy for scripting and
debugging:

```sh
swift run storrent info something.torrent        # parse and print metainfo
swift run storrent create <file-or-dir>          # make a .torrent
swift run storrent announce something.torrent    # query trackers for peers
swift run storrent download something.torrent ~/Downloads
swift run storrent seed something.torrent <content-parent-dir>
swift run storrent magnet "magnet:?xt=urn:btih:…"
swift run storrent dht <40-hex-infohash>         # DHT peer lookup
```

## Architecture

Two cleanly separated layers:

| Path | What it is |
|---|---|
| `Sources/TorrentEngine` | Actor-based engine library: bencode, metainfo, trackers, peer wire, MSE, pieces, storage, DHT, LSD, session |
| `Sources/SpeedyTorrentApp` | SwiftUI app (window + menu bar + settings) |
| `Sources/storrent` | CLI harness |
| `Tests/TorrentEngineTests` | Unit tests + loopback end-to-end suites |

The engine never imports AppKit. `TorrentSession` is the single public entry
point: the app consumes 1 Hz value-type `TorrentSnapshot`s and calls intent
methods (`addTorrent`, `commitMagnet`, `pauseTorrent`, …).

Reliability decisions worth knowing about:

- Info-hashes are computed over the *original* bencoded bytes (never
  re-encoded), with byte ranges tracked by the decoder.
- Every piece is SHA-1 verified before it is written — whether it came from a
  peer or a web seed; peers contributing to two corrupt pieces are banned.
- File paths from metadata are sanitized against directory traversal.
- Resume data is trusted only if file modification times are unchanged;
  otherwise the torrent is silently re-checked.
- DHT, PEX, and LSD are all disabled for torrents marked `private`.

## Testing

```sh
Scripts/test.sh
```

101 tests cover the codecs (bencode, KRPC, PEX, NAT-PMP, LSD, MSE crypto
against known vectors) and, more importantly, real end-to-end behavior:
loopback swarms download, seed, resume, re-check, queue, encrypt, exchange
peers, and fetch from a local HTTP web seed — over real sockets, with byte-for-
byte payload verification. The client has also been verified against the
Debian netinst image by `.torrent` and by trackerless magnet, checksums
matching.

## Protocol support

BEP 3 (peer wire), 5 (DHT), 7 (IPv6 peers), 9 (metadata exchange),
10 (extension protocol), 11 (PEX), 12 (tracker tiers), 14 (LSD),
15 (UDP trackers), 19 (web seeds), 20 (peer IDs), 23 (compact peers),
plus MSE/PE stream encryption.

Not yet: BitTorrent v2 (BEP 52), uTP, UPnP-IGD (NAT-PMP covers most home
routers), per-file priorities beyond on/off, App Store sandboxing. The module
boundaries leave room for all of them.

## Note

Use SpeedyTorrent for content you have the right to download and share —
Linux ISOs are the canonical test material.
