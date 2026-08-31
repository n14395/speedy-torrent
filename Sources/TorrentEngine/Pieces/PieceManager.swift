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
    /// Non-normal file priorities, by file index. Sparse: the common case (all
    /// normal) is an empty dictionary.
    private(set) var filePriorities: [Int: FilePriority]
    /// Pieces overlapping any wanted file (boundary pieces are wanted even
    /// when they extend into unwanted files, so wanted files verify fully).
    private var wantedPieces: [Bool]
    /// Request priority of each piece: the highest priority among the *wanted*
    /// files overlapping it. Unwanted files are excluded so their priority
    /// can't drag a shared boundary piece up or down.
    private var piecePriority: [FilePriority]
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
        wantedFiles: Set<Int>? = nil,
        filePriorities: [Int: FilePriority] = [:]
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
        self.filePriorities = filePriorities.filter {
            $0.value != .normal && allFiles.contains($0.key)
        }
        self.wantedPieces = []
        self.piecePriority = []
        recomputePieceMasks()

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
        recomputePieceMasks()
        for index in inProgress.keys where !wantedPieces[index] {
            inProgress[index] = nil
        }
    }

    /// Sets the request priority of the given files. Pieces already in flight
    /// are left alone — priority steers which piece is picked *next*, and
    /// dropping partial work to honour it would waste what those peers sent.
    func setPriority(_ priority: FilePriority, for files: Set<Int>) {
        let clamped = files.intersection(Set(info.files.indices))
        guard !clamped.isEmpty else { return }
        var changed = false
        for index in clamped {
            let old = filePriorities[index] ?? .normal
            guard old != priority else { continue }
            if priority == .normal {
                filePriorities.removeValue(forKey: index)
            } else {
                filePriorities[index] = priority
            }
            changed = true
        }
        guard changed else { return }
        recomputePieceMasks()
    }

    func priority(for file: Int) -> FilePriority {
        filePriorities[file] ?? .normal
    }

    /// The files at a given non-normal priority, sorted, or nil when there are
    /// none — the shape the resume record stores.
    func fileIndices(at priority: FilePriority) -> [Int]? {
        let indices = filePriorities.filter { $0.value == priority }.keys.sorted()
        return indices.isEmpty ? nil : indices
    }

    /// Rebuilds both per-piece projections of the file table in one walk: which
    /// pieces are wanted, and at what priority.
    private func recomputePieceMasks() {
        var mask = [Bool](repeating: false, count: info.pieceCount)
        // nil = no wanted file covers this piece yet; the first one seeds it
        // and later ones raise it.
        var levels = [FilePriority?](repeating: nil, count: info.pieceCount)
        for index in wantedFiles {
            let span = fileSpans[index]
            guard span.end > span.start else { continue } // zero-length file
            let priority = filePriorities[index] ?? .normal
            let first = Int(span.start / Int64(info.pieceLength))
            let last = Int((span.end - 1) / Int64(info.pieceLength))
            for piece in first...last {
                mask[piece] = true
                levels[piece] = max(levels[piece] ?? priority, priority)
            }
        }
        wantedPieces = mask
        piecePriority = levels.map { $0 ?? .normal }
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

    /// Picks the next piece to start. Priority comes first — the highest
    /// priority any candidate offers wins outright — and the usual policy
    /// (file order, or rarest-first) then chooses within that group. With every
    /// file at normal priority this is exactly the old behaviour.
    private func pickNewPiece(peerHas: Bitfield) -> Int? {
        if sequential {
            var best: Int?
            var bestPriority = FilePriority.low
            for index in 0..<info.pieceCount
            where wantedPieces[index] && !have[index] && inProgress[index] == nil && peerHas[index] {
                let priority = piecePriority[index]
                // Strictly greater: at equal priority the earlier piece (the
                // one already held) is the sequential choice.
                guard best == nil || priority > bestPriority else { continue }
                best = index
                bestPriority = priority
                if priority == .high { break } // nothing later can outrank it
            }
            return best
        }
        // Rarest-first with uniform random tie-breaking (reservoir sampling),
        // applied within the best priority band seen so far.
        var best: Int?
        var bestPriority = FilePriority.low
        var bestAvailability = Int.max
        var ties = 0
        for index in 0..<info.pieceCount
        where wantedPieces[index] && !have[index] && inProgress[index] == nil && peerHas[index] {
            let priority = piecePriority[index]
            if best == nil || priority > bestPriority {
                best = index
                bestPriority = priority
                bestAvailability = availability[index]
                ties = 1
                continue
            }
            guard priority == bestPriority else { continue } // outranked
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

    /// The most urgent wanted, missing piece not already being fetched from
    /// peers — for web seeds to grab without duplicating peer work. Ties (the
    /// usual case, everything normal) go to the lowest piece index.
    func nextMissingWantedPiece() -> Int? {
        var best: Int?
        var bestPriority = FilePriority.low
        for index in 0..<info.pieceCount
        where wantedPieces[index] && !have[index] && inProgress[index] == nil {
            let priority = piecePriority[index]
            guard best == nil || priority > bestPriority else { continue }
            best = index
            bestPriority = priority
            if priority == .high { break }
        }
        return best
    }

    /// Clears all verified state so a full re-check can re-populate it.
    func resetHave() {
        have = Bitfield(count: info.pieceCount)
        completedLength = 0
        inProgress.removeAll()
    }
}
