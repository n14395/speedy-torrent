import Foundation

/// A single 16 KiB-or-smaller block within a piece.
struct BlockRef: Hashable, Sendable {
    let index: Int
    let begin: Int
    let length: Int
}

/// Piece/block bookkeeping and request strategy for one torrent: rarest-first
/// (or sequential) piece selection, block-level pipelining, and endgame
/// duplication. Pure state machine — no I/O, no hashing; the controller owns
/// verification and disk writes. Not thread-safe: must be confined to the
/// controller actor.
final class PieceManager {
    static let blockSize = 16 * 1024
    /// Cap on concurrently downloading pieces (bounds piece-buffer memory).
    private let maxInProgress = 96

    let info: TorrentInfo
    var sequential: Bool
    private(set) var have: Bitfield
    /// Verified payload bytes (kept incrementally in sync with `have`).
    private(set) var completedLength: Int64

    /// Indices into `info.files` the user wants downloaded (never empty).
    private(set) var wantedFiles: Set<Int>
    /// Pieces overlapping any wanted file (boundary pieces are wanted even
    /// when they extend into unwanted files, so wanted files verify fully).
    private var wantedPieces: [Bool]
    /// Global byte range of each file.
    private let fileSpans: [(start: Int64, end: Int64)]

    /// How many connected peers have each piece (for rarest-first).
    private var availability: [Int]
    private var inProgress: [Int: PieceProgress] = [:]

    final class PieceProgress {
        let index: Int
        let size: Int
        var data: Data
        var blockReceived: [Bool]
        /// Number of outstanding requests per block (endgame may exceed 1).
        var blockRequests: [Int]
        var receivedCount = 0

        init(index: Int, size: Int) {
            self.index = index
            self.size = size
            self.data = Data(count: size)
            let blocks = (size + PieceManager.blockSize - 1) / PieceManager.blockSize
            self.blockReceived = [Bool](repeating: false, count: blocks)
            self.blockRequests = [Int](repeating: 0, count: blocks)
        }

        var blockCount: Int { blockReceived.count }
        var isComplete: Bool { receivedCount == blockCount }

        func blockLength(_ block: Int) -> Int {
            block == blockCount - 1
                ? size - block * PieceManager.blockSize
                : PieceManager.blockSize
        }
    }

    init(
        info: TorrentInfo,
        have: Bitfield? = nil,
        sequential: Bool = false,
        wantedFiles: Set<Int>? = nil
    ) {
        self.info = info
        self.sequential = sequential
        self.have = have ?? Bitfield(count: info.pieceCount)
        self.availability = [Int](repeating: 0, count: info.pieceCount)
        self.completedLength = 0

        var spans: [(Int64, Int64)] = []
        var offset: Int64 = 0
        for file in info.files {
            spans.append((offset, offset + file.length))
            offset += file.length
        }
        self.fileSpans = spans

        let allFiles = Set(info.files.indices)
        let requested = wantedFiles.map { $0.intersection(allFiles) } ?? allFiles
        self.wantedFiles = requested.isEmpty ? allFiles : requested
        self.wantedPieces = []
        recomputeWantedPieces()

        if let have {
            for index in 0..<info.pieceCount where have[index] {
                completedLength += Int64(info.pieceSize(at: index))
            }
        }
    }

    var isComplete: Bool { have.isFull }

    // MARK: - File selection

    /// Changes the wanted-file set; an empty selection is ignored. In-flight
    /// pieces that became unwanted are dropped (their straggler blocks are
    /// simply ignored on arrival).
    func setWantedFiles(_ wanted: Set<Int>) {
        let clamped = wanted.intersection(Set(info.files.indices))
        guard !clamped.isEmpty, clamped != wantedFiles else { return }
        wantedFiles = clamped
        recomputeWantedPieces()
        for index in inProgress.keys where !wantedPieces[index] {
            inProgress[index] = nil
        }
    }

    private func recomputeWantedPieces() {
        var mask = [Bool](repeating: false, count: info.pieceCount)
        for index in wantedFiles {
            let span = fileSpans[index]
            guard span.end > span.start else { continue } // zero-length file
            let first = Int(span.start / Int64(info.pieceLength))
            let last = Int((span.end - 1) / Int64(info.pieceLength))
            for piece in first...last {
                mask[piece] = true
            }
        }
        wantedPieces = mask
    }

    func isWanted(_ piece: Int) -> Bool {
        piece >= 0 && piece < wantedPieces.count && wantedPieces[piece]
    }

    /// Pieces overlapping wanted files, as a bitfield (for storage to decide
    /// which files are worth allocating).
    func wantedPieceBitfield() -> Bitfield {
        var bitfield = Bitfield(count: info.pieceCount)
        for index in 0..<info.pieceCount where wantedPieces[index] {
            bitfield[index] = true
        }
        return bitfield
    }

    /// All pieces overlapping wanted files are verified.
    var isWantedComplete: Bool {
        for index in 0..<info.pieceCount where wantedPieces[index] && !have[index] {
            return false
        }
        return true
    }

    /// Byte size of the wanted piece set (the progress denominator).
    var wantedBytes: Int64 {
        var total: Int64 = 0
        for index in 0..<info.pieceCount where wantedPieces[index] {
            total += Int64(info.pieceSize(at: index))
        }
        return total
    }

    var completedWantedBytes: Int64 {
        var total: Int64 = 0
        for index in 0..<info.pieceCount where wantedPieces[index] && have[index] {
            total += Int64(info.pieceSize(at: index))
        }
        return total
    }

    /// True if the peer has a wanted piece we lack — the interest signal.
    func peerHasUsefulPiece(_ peerBits: Bitfield) -> Bool {
        for index in 0..<info.pieceCount
        where wantedPieces[index] && !have[index] && peerBits[index] {
            return true
        }
        return false
    }

    // MARK: - Peer availability

    func peerJoined(with bitfield: Bitfield) {
        for index in 0..<info.pieceCount where bitfield[index] {
            availability[index] += 1
        }
    }

    func peerLeft(with bitfield: Bitfield) {
        for index in 0..<info.pieceCount where bitfield[index] {
            availability[index] -= 1
        }
    }

    func peerHas(_ index: Int) {
        guard index >= 0, index < info.pieceCount else { return }
        availability[index] += 1
    }

    // MARK: - Request selection

    /// Picks the next block to request from a peer with the given bitfield,
    /// skipping blocks in `excluding` (that peer's own outstanding requests).
    func nextRequest(peerHas: Bitfield, excluding: Set<BlockRef>) -> BlockRef? {
        // 1. Finish partially downloaded pieces first.
        for progress in inProgress.values where peerHas[progress.index] {
            if let ref = unrequestedBlock(in: progress) {
                return ref
            }
        }

        // 2. Start a new piece.
        if inProgress.count < maxInProgress, let index = pickNewPiece(peerHas: peerHas) {
            let progress = PieceProgress(index: index, size: info.pieceSize(at: index))
            inProgress[index] = progress
            return unrequestedBlock(in: progress)
        }

        // 3. Endgame: everything is requested; duplicate the least-requested
        //    outstanding block this peer isn't already fetching.
        var best: (ref: BlockRef, requests: Int)?
        for progress in inProgress.values where peerHas[progress.index] {
            for block in 0..<progress.blockCount where !progress.blockReceived[block] {
                let ref = BlockRef(
                    index: progress.index,
                    begin: block * Self.blockSize,
                    length: progress.blockLength(block)
                )
                guard !excluding.contains(ref) else { continue }
                let requests = progress.blockRequests[block]
                if best == nil || requests < best!.requests {
                    best = (ref, requests)
                }
            }
        }
        return best?.ref
    }

    private func unrequestedBlock(in progress: PieceProgress) -> BlockRef? {
        for block in 0..<progress.blockCount
        where !progress.blockReceived[block] && progress.blockRequests[block] == 0 {
            return BlockRef(
                index: progress.index,
                begin: block * Self.blockSize,
                length: progress.blockLength(block)
            )
        }
        return nil
    }

    private func pickNewPiece(peerHas: Bitfield) -> Int? {
        if sequential {
            for index in 0..<info.pieceCount
            where wantedPieces[index] && !have[index] && inProgress[index] == nil && peerHas[index] {
                return index
            }
            return nil
        }
        // Rarest-first with uniform random tie-breaking (reservoir sampling).
        var best: Int?
        var bestAvailability = Int.max
        var ties = 0
        for index in 0..<info.pieceCount
        where wantedPieces[index] && !have[index] && inProgress[index] == nil && peerHas[index] {
            let pieceAvailability = availability[index]
            if pieceAvailability < bestAvailability {
                best = index
                bestAvailability = pieceAvailability
                ties = 1
            } else if pieceAvailability == bestAvailability {
                ties += 1
                if Int.random(in: 0..<ties) == 0 {
                    best = index
                }
            }
        }
        return best
    }

    func markRequested(_ ref: BlockRef) {
        guard let progress = inProgress[ref.index] else { return }
        progress.blockRequests[ref.begin / Self.blockSize] += 1
    }

    func cancelRequest(_ ref: BlockRef) {
        guard let progress = inProgress[ref.index] else { return }
        let block = ref.begin / Self.blockSize
        if progress.blockRequests[block] > 0 {
            progress.blockRequests[block] -= 1
        }
    }

    // MARK: - Incoming blocks

    enum BlockResult {
        case ignored
        case progress
        /// All blocks received — verify this piece's assembled bytes.
        case pieceComplete(Data)
    }

    func receivedBlock(index: Int, begin: Int, block: Data) -> BlockResult {
        guard let progress = inProgress[index],
              begin % Self.blockSize == 0
        else { return .ignored }
        let blockIndex = begin / Self.blockSize
        guard blockIndex < progress.blockCount,
              block.count == progress.blockLength(blockIndex),
              !progress.blockReceived[blockIndex]
        else { return .ignored }

        progress.blockReceived[blockIndex] = true
        if progress.blockRequests[blockIndex] > 0 {
            progress.blockRequests[blockIndex] -= 1
        }
        progress.receivedCount += 1
        progress.data.replaceSubrange(begin..<begin + block.count, with: block)
        return progress.isComplete ? .pieceComplete(progress.data) : .progress
    }

    func pieceVerified(_ index: Int) {
        inProgress[index] = nil
        if !have[index] {
            have[index] = true
            completedLength += Int64(info.pieceSize(at: index))
        }
    }

    /// Hash mismatch: throw everything away and re-download the piece.
    func pieceFailed(_ index: Int) {
        inProgress[index] = nil
    }

    /// Marks a piece as already on disk (initial verification / fast resume).
    func markHave(_ index: Int) {
        pieceVerified(index)
    }

    /// The lowest wanted, missing piece not already being fetched from peers —
    /// for web seeds to grab without duplicating peer work.
    func nextMissingWantedPiece() -> Int? {
        for index in 0..<info.pieceCount
        where wantedPieces[index] && !have[index] && inProgress[index] == nil {
            return index
        }
        return nil
    }

    /// Clears all verified state so a full re-check can re-populate it.
    func resetHave() {
        have = Bitfield(count: info.pieceCount)
        completedLength = 0
        inProgress.removeAll()
    }
}
