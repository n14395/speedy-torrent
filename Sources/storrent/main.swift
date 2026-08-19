import Foundation
import TorrentEngine

let usage = """
storrent — SpeedyTorrent engine CLI harness

Usage:
  storrent version
  storrent info <file.torrent>
  storrent announce <file.torrent>
  storrent create <file-or-dir> [tracker-url]
  storrent download <file.torrent> [output-dir] [--sequential] [--port N]
  storrent seed <file.torrent> <content-parent-dir> [--port N]
  storrent magnet "<magnet-uri>" [output-dir] [--port N] [--encryption off|prefer|require]
"""

/// `--encryption off|prefer|require` (default: prefer, matching the app).
func encryptionArgument(_ arguments: [String]) -> EncryptionPolicy {
    guard let index = arguments.firstIndex(of: "--encryption"),
          arguments.indices.contains(index + 1)
    else { return .preferred }
    switch arguments[index + 1].lowercased() {
    case "off", "disabled", "none": return .disabled
    case "require", "required": return .required
    default: return .preferred
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KiB", "MiB", "GiB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
}

func printProgress(_ snap: TorrentSnapshot) {
    let line = String(
        format: "%5.1f%%  %@/%@  ↓ %@/s ↑ %@/s  peers %d  pieces %d/%d  [%@]",
        snap.progress * 100,
        formatBytes(snap.completedLength), formatBytes(snap.totalLength),
        formatBytes(Int64(snap.downloadRate)), formatBytes(Int64(snap.uploadRate)),
        snap.peerCount, snap.havePieces, snap.pieceCount,
        snap.state.rawValue
    )
    print(line)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadMetaInfo(_ path: String) -> TorrentMetaInfo {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { fail("cannot read \(path)") }
    do {
        return try TorrentMetaInfo(torrentFileData: data)
    } catch {
        fail("cannot parse \(path): \(error)")
    }
}

func printInfo(_ meta: TorrentMetaInfo) {
    print("name:         \(meta.info.name)")
    print("info-hash:    \(meta.info.infoHash.hexString)")
    print("total size:   \(meta.info.totalLength) bytes")
    print("piece length: \(meta.info.pieceLength)")
    print("pieces:       \(meta.info.pieceCount)")
    print("private:      \(meta.info.isPrivate)")
    print("files:")
    for file in meta.info.files {
        print("  \(file.path.joined(separator: "/"))  (\(file.length) bytes)")
    }
    print("trackers:")
    for (index, tier) in meta.announceTiers.enumerated() {
        for url in tier {
            print("  tier \(index): \(url)")
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "version":
    print("storrent 0.1.0 (engine \(TorrentEngineInfo.version))")

case "info":
    guard arguments.count == 2 else { fail(usage) }
    printInfo(loadMetaInfo(arguments[1]))

case "announce":
    guard arguments.count == 2 else { fail(usage) }
    let meta = loadMetaInfo(arguments[1])
    let manager = TrackerManager(tiers: meta.announceTiers)
    let request = AnnounceRequest(
        infoHash: meta.info.infoHash,
        peerID: PeerID.generate(),
        port: 6881,
        left: meta.info.totalLength,
        event: .started,
        key: UInt32.random(in: .min ... .max)
    )
    do {
        let response = try await manager.announce(request)
        print("interval: \(response.interval)s")
        if let seeders = response.seeders, let leechers = response.leechers {
            print("seeders: \(seeders), leechers: \(leechers)")
        }
        print("peers (\(response.peers.count)):")
        for peer in response.peers.prefix(30) {
            print("  \(peer)")
        }
        for (url, error) in await manager.lastErrors {
            print("tracker error: \(url): \(error)")
        }
    } catch {
        for (url, message) in await manager.lastErrors {
            print("tracker error: \(url): \(message)")
        }
        fail("announce failed: \(error)")
    }

case "create":
    guard arguments.count >= 2 else { fail(usage) }
    let source = URL(fileURLWithPath: arguments[1])
    let tiers = arguments.count > 2 ? [[arguments[2]]] : []
    do {
        let data = try TorrentBuilder.makeTorrentData(contentsOf: source, announceTiers: tiers)
        let output = source.deletingPathExtension().appendingPathExtension("torrent")
        try data.write(to: output)
        print("wrote \(output.path)")
        printInfo(try TorrentMetaInfo(torrentFileData: data))
    } catch {
        fail("create failed: \(error)")
    }

case "download":
    guard arguments.count >= 2 else { fail(usage) }
    let meta = loadMetaInfo(arguments[1])
    let outputDir = arguments.count > 2 && !arguments[2].hasPrefix("--")
        ? URL(fileURLWithPath: arguments[2])
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let sequential = arguments.contains("--sequential")
    let port: UInt16 = arguments.firstIndex(of: "--port")
        .flatMap { arguments.indices.contains($0 + 1) ? UInt16(arguments[$0 + 1]) : nil } ?? 0

    let session = TorrentSession(configuration: .init(
        downloadDirectory: outputDir,
        listenPort: port,
        sequentialDownload: sequential
    ))
    if port != 0 {
        _ = try? await session.startListening()
    }
    do {
        _ = try await session.addTorrent(fileData: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    } catch {
        fail("add failed: \(error)")
    }
    print("downloading \(meta.info.name) → \(outputDir.path)")
    while true {
        try? await Task.sleep(for: .seconds(1))
        guard let snap = await session.snapshots().first else { break }
        printProgress(snap)
        if snap.state == .seeding {
            print("complete.")
            break
        }
        if snap.state == .failed {
            fail("failed: \(snap.errorMessage ?? "unknown error")")
        }
    }
    await session.shutdown()

case "seed":
    guard arguments.count >= 3 else { fail(usage) }
    let meta = loadMetaInfo(arguments[1])
    let contentParent = URL(fileURLWithPath: arguments[2])
    let port: UInt16 = arguments.firstIndex(of: "--port")
        .flatMap { arguments.indices.contains($0 + 1) ? UInt16(arguments[$0 + 1]) : nil } ?? 6881

    let session = TorrentSession(configuration: .init(
        downloadDirectory: contentParent,
        listenPort: port
    ))
    do {
        _ = try await session.startListening()
        _ = try await session.addTorrent(fileData: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    } catch {
        fail("seed failed: \(error)")
    }
    print("seeding \(meta.info.name) on port \(port) (ctrl-c to stop)")
    while true {
        try? await Task.sleep(for: .seconds(5))
        if let snap = await session.snapshots().first {
            printProgress(snap)
        }
    }

case "dht":
    guard arguments.count == 2, let hash = InfoHash(hex: arguments[1]) else {
        fail("usage: storrent dht <40-hex-infohash>")
    }
    let node = DHTNode()
    do {
        try await node.start(port: 0)
    } catch {
        fail("dht start failed: \(error)")
    }
    print("bootstrapping…")
    for second in 1...15 {
        try? await Task.sleep(for: .seconds(1))
        print("  t+\(second)s routing table: \(await node.nodeCount) nodes")
        if await node.nodeCount >= 20 { break }
    }
    print("looking up peers for \(hash)…")
    let peers = await node.findPeers(infoHash: hash, announcePort: nil)
    print("found \(peers.count) peers")
    for peer in peers.prefix(20) {
        print("  \(peer)")
    }
    await node.stop()

case "magnet":
    guard arguments.count >= 2 else { fail(usage) }
    let outputDir = arguments.count > 2 && !arguments[2].hasPrefix("--")
        ? URL(fileURLWithPath: arguments[2])
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let port: UInt16 = arguments.firstIndex(of: "--port")
        .flatMap { arguments.indices.contains($0 + 1) ? UInt16(arguments[$0 + 1]) : nil } ?? 6893
    let policy = encryptionArgument(arguments)
    let session = TorrentSession(configuration: .init(
        downloadDirectory: outputDir,
        listenPort: port,
        encryptionPolicy: policy
    ))
    print("encryption: \(policy.rawValue)")
    do {
        _ = try await session.startListening()
    } catch {
        fail("listen failed: \(error)")
    }
    do {
        _ = try await session.addMagnet(arguments[1])
    } catch {
        fail("add magnet failed: \(error)")
    }
    print("resolving magnet via DHT/trackers…")
    var announced = false
    while true {
        try? await Task.sleep(for: .seconds(1))
        guard let snap = await session.snapshots().first else { break }
        if snap.state == .fetchingMetadata {
            print("fetching metadata…  candidate peers: \(snap.peerCount)  dht nodes: \(await session.dhtNodeCount())")
        } else {
            if !announced {
                print("metadata resolved: \(snap.name) (\(formatBytes(snap.totalLength)))")
                announced = true
            }
            printProgress(snap)
        }
        if snap.state == .seeding {
            print("complete.")
            break
        }
        if snap.state == .failed {
            fail("failed: \(snap.errorMessage ?? "unknown")")
        }
    }
    await session.shutdown()

default:
    print(usage)
    exit(arguments.isEmpty ? 0 : 64)
}
