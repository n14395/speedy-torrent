// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

enum DHTError: Error {
    case timeout
    case badResponse
    case notRunning
}

/// A BEP 5 mainline DHT node: answers queries from the network, and performs
/// iterative get_peers/announce_peer lookups for our torrents.
public actor DHTNode {
    public static let defaultBootstrapNodes = [
        ("router.bittorrent.com", UInt16(6881)),
        ("dht.transmissionbt.com", UInt16(6881)),
        ("router.utorrent.com", UInt16(6881)),
    ]

    let ownID = NodeID.random()
    private let socket = UDPSocket()
    private var routing: RoutingTable!
    private var running = false

    private struct Pending {
        let continuation: CheckedContinuation<BValue, Error>
        let deadline: ContinuousClock.Instant
        let address: PeerAddress
    }
    private var pending: [Data: Pending] = [:]
    private var transactionCounter: UInt16 = .random(in: .min ... .max)

    private var tokenSecret = NodeID.random()
    private var previousTokenSecret = NodeID.random()

    /// Peers announced to us, per info-hash, with expiry.
    private var peerStore: [Data: [PeerAddress: ContinuousClock.Instant]] = [:]

    private var sweeperTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var statePath: URL?

    public init() {}

    public var nodeCount: Int { routing?.count ?? 0 }
    public var port: UInt16 {
        get async { await socket.port }
    }

    // MARK: - Lifecycle

    public func start(port: UInt16, statePath: URL? = nil) async throws {
        guard !running else { return }
        routing = RoutingTable(ownID: ownID)
        self.statePath = statePath
        try await socket.open(port: port) { [weak self] data, address in
            guard let self else { return }
            Task { await self.handleDatagram(data, from: address) }
        }
        running = true
        sweeperTask = Task { await self.runSweeper() }
        bootstrapTask = Task { await self.bootstrap() }
    }

    public func stop() async {
        guard running else { return }
        running = false
        saveNodes()
        sweeperTask?.cancel()
        bootstrapTask?.cancel()
        for entry in pending.values {
            entry.continuation.resume(throwing: DHTError.notRunning)
        }
        pending.removeAll()
        await socket.close()
    }

    /// Pings an address so a live node gets added to the routing table (used
    /// for peers' PORT messages and loopback tests).
    public func addCandidate(_ address: PeerAddress) async {
        _ = try? await query("ping", arguments: [], to: address)
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        var seeds: [PeerAddress] = loadSavedNodes()
        if routing.count < 8 {
            for (host, port) in Self.defaultBootstrapNodes {
                for ip in await DNSResolver.resolveIPv4(host).prefix(2) {
                    seeds.append(PeerAddress(host: ip, port: port))
                }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for seed in seeds.prefix(24) {
                group.addTask { await self.addCandidate(seed) }
            }
        }
        // Populate the table around our own ID.
        _ = await lookup(target: ownID, collectPeers: false)
        saveNodes()
    }

    // MARK: - Public lookups

    /// Iterative get_peers; when `announcePort` is set, announce_peer to the
    /// closest responding nodes afterwards.
    public func findPeers(infoHash: InfoHash, announcePort: UInt16?) async -> [PeerAddress] {
        guard running else { return [] }
        let result = await lookup(target: infoHash.data, collectPeers: true)
        if let announcePort {
            for (address, token) in result.tokens.prefix(8) {
                let arguments: [(String, BValue)] = [
                    ("implied_port", .integer(0)),
                    ("info_hash", .string(infoHash.data)),
                    ("port", .integer(Int(announcePort))),
                    ("token", .string(token)),
                ]
                Task { _ = try? await self.query("announce_peer", arguments: arguments, to: address) }
            }
        }
        return Array(result.peers)
    }

    private struct LookupResult {
        var peers: Set<PeerAddress> = []
        var tokens: [(PeerAddress, Data)] = []
    }

    private func lookup(target: Data, collectPeers: Bool) async -> LookupResult {
        var result = LookupResult()
        var candidates = routing.closest(to: target, count: 16)
        var queried = Set<PeerAddress>()

        for _ in 0..<8 {
            let batch = candidates
                .filter { !queried.contains($0.address) }
                .prefix(3)
            guard !batch.isEmpty else { break }
            queried.formUnion(batch.map(\.address))

            let method = collectPeers ? "get_peers" : "find_node"
            let keyName = collectPeers ? "info_hash" : "target"
            let responses = await withTaskGroup(
                of: (PeerAddress, BValue?).self,
                returning: [(PeerAddress, BValue?)].self
            ) { group in
                for node in batch {
                    group.addTask {
                        let response = try? await self.query(
                            method, arguments: [(keyName, .string(target))], to: node.address
                        )
                        return (node.address, response)
                    }
                }
                var collected: [(PeerAddress, BValue?)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected
            }

            for (address, response) in responses {
                guard let response else { continue }
                if let values = response["values"]?.listValue {
                    for value in values {
                        if let compact = value.stringData {
                            result.peers.formUnion(CompactPeers.parseIPv4(compact))
                        }
                    }
                }
                if let token = response["token"]?.stringData {
                    result.tokens.append((address, token))
                }
                if let nodesData = response["nodes"]?.stringData {
                    candidates.append(contentsOf: KRPC.parseCompactNodes(nodesData))
                }
            }

            var seen = Set<PeerAddress>()
            candidates = candidates
                .filter { seen.insert($0.address).inserted }
                .sorted { NodeID.isCloser($0.id, than: $1.id, to: target) }
            candidates = Array(candidates.prefix(32))
        }
        return result
    }

    // MARK: - Query plumbing

    /// A 2-byte counter alone wraps at 65,536 queries — reachable in a long
    /// session — and a wrap onto a still-outstanding transaction overwrote its
    /// entry, stranding that continuation forever. The random half makes a
    /// collision need a 32-bit coincidence; `query` still guards against one.
    private func nextTransaction() -> Data {
        transactionCounter &+= 1
        var data = Data()
        data.appendUInt16(transactionCounter)
        data.appendUInt16(.random(in: .min ... .max))
        return data
    }

    func query(
        _ method: String, arguments: [(String, BValue)], to address: PeerAddress
    ) async throws -> BValue {
        guard running else { throw DHTError.notRunning }
        let transaction = nextTransaction()
        let payload = KRPC.encodeQuery(
            transaction: transaction,
            method: method,
            arguments: [("id", .string(ownID))] + arguments
        )
        return try await withCheckedThrowingContinuation { continuation in
            // Never drop a continuation on the floor: on the vanishing chance
            // of a collision, fail the older query rather than leaking it.
            if let stale = pending.removeValue(forKey: transaction) {
                stale.continuation.resume(throwing: DHTError.badResponse)
            }
            pending[transaction] = Pending(
                continuation: continuation,
                deadline: .now.advanced(by: .seconds(3)),
                address: address
            )
            Task { await self.socket.send(payload, to: address) }
        }
    }

    private func runSweeper() async {
        var ticks = 0
        while !Task.isCancelled, running {
            try? await Task.sleep(for: .milliseconds(500))
            ticks += 1
            let now = ContinuousClock.now

            for (transaction, entry) in pending where entry.deadline < now {
                pending[transaction] = nil
                routing.failed(entry.address)
                entry.continuation.resume(throwing: DHTError.timeout)
            }

            if ticks % 600 == 0 { // every 5 minutes
                previousTokenSecret = tokenSecret
                tokenSecret = NodeID.random()
                for (hash, peers) in peerStore {
                    peerStore[hash] = peers.filter { $0.value > now }
                    if peerStore[hash]?.isEmpty == true {
                        peerStore[hash] = nil
                    }
                }
                saveNodes()
            }
        }
    }

    // MARK: - Incoming traffic

    private func handleDatagram(_ data: Data, from address: PeerAddress) {
        guard running, let message = KRPC.decode(data) else { return }
        switch message {
        case .response(let transaction, let body):
            if let id = body["id"]?.stringData, id.count == 20 {
                routing.heard(from: KRPC.NodeInfo(id: id, address: address))
            }
            if let entry = resolvePending(transaction, from: address) {
                entry.continuation.resume(returning: body)
            }
        case .error(let transaction, _, let errorMessage):
            if let entry = resolvePending(transaction, from: address) {
                entry.continuation.resume(throwing: DHTError.badResponse)
                _ = errorMessage
            }
        case .query(let transaction, let method, let arguments):
            if let id = arguments["id"]?.stringData, id.count == 20 {
                routing.heard(from: KRPC.NodeInfo(id: id, address: address))
            }
            handleQuery(method: method, arguments: arguments, transaction: transaction, from: address)
        }
    }

    /// Claims a pending query only for the address it was actually sent to.
    /// Otherwise any host that guessed a transaction id could answer a query it
    /// was never asked, injecting peers and nodes into our routing table. A
    /// mismatched reply leaves the entry pending, so the real one can still
    /// land — and the sweeper times it out if it never does.
    private func resolvePending(_ transaction: Data, from address: PeerAddress) -> Pending? {
        guard let entry = pending[transaction], entry.address == address else { return nil }
        pending[transaction] = nil
        return entry
    }

    private func handleQuery(method: String, arguments: BValue, transaction: Data, from address: PeerAddress) {
        var body: [(String, BValue)] = [("id", .string(ownID))]
        switch method {
        case "ping":
            break

        case "find_node":
            let target = arguments["target"]?.stringData ?? ownID
            let nodes = routing.closest(to: target.count == 20 ? target : ownID)
            body.append(("nodes", .string(KRPC.encodeCompactNodes(nodes))))

        case "get_peers":
            guard let infoHash = arguments["info_hash"]?.stringData, infoHash.count == 20 else {
                send(KRPC.encodeError(transaction: transaction, code: 203, message: "bad info_hash"), to: address)
                return
            }
            body.append(("token", .string(makeToken(for: address, secret: tokenSecret))))
            let now = ContinuousClock.now
            let known = (peerStore[infoHash] ?? [:]).filter { $0.value > now }.keys
            if !known.isEmpty {
                let values = known.prefix(50).compactMap { peer in
                    KRPC.encodeCompactPeer(peer).map { BValue.string($0) }
                }
                body.append(("values", .list(values)))
            } else {
                body.append(("nodes", .string(KRPC.encodeCompactNodes(routing.closest(to: infoHash)))))
            }

        case "announce_peer":
            guard let infoHash = arguments["info_hash"]?.stringData, infoHash.count == 20,
                  let token = arguments["token"]?.stringData,
                  validateToken(token, for: address)
            else {
                send(KRPC.encodeError(transaction: transaction, code: 203, message: "bad token"), to: address)
                return
            }
            let port: UInt16
            if arguments["implied_port"]?.integerValue == 1 {
                port = address.port
            } else if let announced = arguments["port"]?.integerValue, let valid = UInt16(exactly: announced) {
                port = valid
            } else {
                port = address.port
            }
            var peers = peerStore[infoHash] ?? [:]
            if peers.count < 200 || peers[PeerAddress(host: address.host, port: port)] != nil {
                peers[PeerAddress(host: address.host, port: port)] = .now.advanced(by: .seconds(30 * 60))
            }
            if peerStore.count < 2000 || peerStore[infoHash] != nil {
                peerStore[infoHash] = peers
            }

        default:
            send(KRPC.encodeError(transaction: transaction, code: 204, message: "method unknown"), to: address)
            return
        }
        send(KRPC.encodeResponse(transaction: transaction, body: body), to: address)
    }

    private func send(_ payload: Data, to address: PeerAddress) {
        Task { await self.socket.send(payload, to: address) }
    }

    // MARK: - Tokens

    private func makeToken(for address: PeerAddress, secret: Data) -> Data {
        Data(Insecure.SHA1.hash(data: secret + Data(address.host.utf8)))
    }

    private func validateToken(_ token: Data, for address: PeerAddress) -> Bool {
        token == makeToken(for: address, secret: tokenSecret)
            || token == makeToken(for: address, secret: previousTokenSecret)
    }

    // MARK: - Node persistence

    private struct SavedNode: Codable {
        let host: String
        let port: UInt16
    }

    private func saveNodes() {
        guard let statePath else { return }
        let nodes = routing.closest(to: ownID, count: 64).map {
            SavedNode(host: $0.address.host, port: $0.address.port)
        }
        if let data = try? JSONEncoder().encode(nodes) {
            try? data.write(to: statePath, options: .atomic)
        }
    }

    private func loadSavedNodes() -> [PeerAddress] {
        guard let statePath,
              let data = try? Data(contentsOf: statePath),
              let nodes = try? JSONDecoder().decode([SavedNode].self, from: data)
        else { return [] }
        return nodes.map { PeerAddress(host: $0.host, port: $0.port) }
    }
}
