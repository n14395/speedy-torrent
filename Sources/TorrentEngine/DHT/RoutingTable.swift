// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Kademlia routing table: one bucket of 8 per shared-prefix length with our
/// node ID. Confined to the DHTNode actor.
final class RoutingTable {
    static let bucketSize = 8

    struct Entry {
        let node: KRPC.NodeInfo
        var lastSeen: ContinuousClock.Instant
        var failures: Int
    }

    let ownID: Data
    /// buckets[i] holds nodes sharing exactly i prefix bits with ownID.
    private var buckets: [[Entry]] = Array(repeating: [], count: 161)
    private var byAddress: [PeerAddress: Data] = [:]

    init(ownID: Data) {
        self.ownID = ownID
    }

    var count: Int { buckets.reduce(0) { $0 + $1.count } }

    var allNodes: [KRPC.NodeInfo] {
        buckets.flatMap { $0.map(\.node) }
    }

    /// Records a node as alive (responded or queried us).
    func heard(from node: KRPC.NodeInfo) {
        guard node.id.count == 20, node.id != ownID else { return }
        let bucket = NodeID.commonPrefixBits(node.id, ownID)
        if let index = buckets[bucket].firstIndex(where: { $0.node.id == node.id }) {
            buckets[bucket][index].lastSeen = .now
            buckets[bucket][index].failures = 0
            return
        }
        // Same address re-appearing with a new ID: drop the old entry.
        if let oldID = byAddress[node.address], oldID != node.id {
            let oldBucket = NodeID.commonPrefixBits(oldID, ownID)
            buckets[oldBucket].removeAll { $0.node.id == oldID }
        }
        var entries = buckets[bucket]
        if entries.count >= Self.bucketSize {
            // Evict a failing or stale node if there is one; otherwise drop.
            if let evict = entries.firstIndex(where: { $0.failures >= 2 }) {
                byAddress[entries[evict].node.address] = nil
                entries.remove(at: evict)
            } else if let oldest = entries.enumerated().min(by: { $0.element.lastSeen < $1.element.lastSeen }),
                      oldest.element.lastSeen < ContinuousClock.now.advanced(by: .seconds(-15 * 60)) {
                byAddress[oldest.element.node.address] = nil
                entries.remove(at: oldest.offset)
            } else {
                return
            }
        }
        entries.append(Entry(node: node, lastSeen: .now, failures: 0))
        buckets[bucket] = entries
        byAddress[node.address] = node.id
    }

    func failed(_ address: PeerAddress) {
        guard let id = byAddress[address] else { return }
        let bucket = NodeID.commonPrefixBits(id, ownID)
        guard let index = buckets[bucket].firstIndex(where: { $0.node.id == id }) else { return }
        buckets[bucket][index].failures += 1
        if buckets[bucket][index].failures >= 4 {
            byAddress[address] = nil
            buckets[bucket].remove(at: index)
        }
    }

    func closest(to target: Data, count: Int = bucketSize) -> [KRPC.NodeInfo] {
        allNodes
            .sorted { NodeID.isCloser($0.id, than: $1.id, to: target) }
            .prefix(count)
            .map { $0 }
    }
}
