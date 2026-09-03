import Foundation
import CryptoKit

public enum StorageError: Error {
    case ioFailure(String)
    case outOfRange
}

/// Maps a torrent's piece space onto files on disk and performs all reads and
/// writes. Single-file torrents live at `<downloadDirectory>/<name>`,
/// multi-file torrents under `<downloadDirectory>/<name>/...`.
///
/// While a file is incomplete its data lives at `<path>.part`; the moment every
/// piece overlapping that file is verified it is renamed to its final name.
/// This lets the user (and other tools) tell finished files from in-progress
/// ones at a glance.
actor FileStore {
    /// Extension marking an in-progress file.
    static let partExtension = "part"

    private struct FileSpan {
        let index: Int
        let url: URL
        let relativePath: String
        /// Offset of this file's first byte in the torrent's global byte space.
        let globalOffset: Int64
        let length: Int64
    }

    private let info: TorrentInfo
    private let spans: [FileSpan]
    /// The torrent's on-disk root: the content directory for multi-file
    /// torrents, the (final) single file otherwise.
    nonisolated let contentRootURL: URL

    /// Per-file: true when the file currently sits at its final path.
    private var finalized: [Bool]
    private var handles: [Int: FileHandle] = [:]

    init(info: TorrentInfo, downloadDirectory: URL) {
        self.info = info
        let base = info.isDirectory
            ? downloadDirectory.appendingPathComponent(info.name, isDirectory: true)
            : downloadDirectory
        var spans: [FileSpan] = []
        var offset: Int64 = 0
        for (index, file) in info.files.enumerated() {
            var url = base
            for component in file.path {
                url.appendPathComponent(component)
            }
            spans.append(FileSpan(
                index: index,
                url: url,
                relativePath: file.path.joined(separator: "/"),
                globalOffset: offset,
                length: file.length
            ))
            offset += file.length
        }
        self.spans = spans
        self.finalized = [Bool](repeating: false, count: spans.count)
        self.contentRootURL = info.isDirectory
            ? base
            : base.appendingPathComponent(info.name)
    }

    // MARK: - Path helpers

    private func partURL(_ span: FileSpan) -> URL {
        span.url.appendingPathExtension(Self.partExtension)
    }

    private func activeURL(_ span: FileSpan) -> URL {
        finalized[span.index] ? span.url : partURL(span)
    }

    /// The best existing path to reveal in Finder (final if present, else the
    /// in-progress file/dir).
    nonisolated func revealURL() -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: contentRootURL.path) {
            return contentRootURL
        }
        let part = contentRootURL.appendingPathExtension(Self.partExtension)
        return fileManager.fileExists(atPath: part.path) ? part : contentRootURL
    }

    /// Top-level filesystem entries belonging to this torrent that currently
    /// exist (for relocation): one directory for multi-file torrents, or the
    /// final/`.part` file for single-file torrents.
    func onDiskItems() -> [URL] {
        let fileManager = FileManager.default
        if info.isDirectory {
            return fileManager.fileExists(atPath: contentRootURL.path) ? [contentRootURL] : []
        }
        let span = spans[0]
        return [span.url, partURL(span)].filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Modification times per relative path (of the active file), for
    /// fast-resume validation.
    func fileStamps() -> [String: Double] {
        var stamps: [String: Double] = [:]
        for span in spans {
            let date = (try? FileManager.default.attributesOfItem(atPath: activeURL(span).path))?[.modificationDate] as? Date
            stamps[span.relativePath] = date?.timeIntervalSince1970 ?? 0
        }
        return stamps
    }

    /// Removes all downloaded content (final and in-progress) from disk.
    ///
    /// Removes this torrent's own files rather than its content directory
    /// wholesale: two torrents can share a top-level directory name in one
    /// download folder — re-releases routinely do — and deleting the directory
    /// took the other one's data with it. Directories are pruned afterwards,
    /// deepest first and only when empty, so anything the user put alongside
    /// the content survives.
    func deleteAllFiles() {
        close()
        let fileManager = FileManager.default
        for span in spans {
            try? fileManager.removeItem(at: span.url)
            try? fileManager.removeItem(at: partURL(span))
        }
        guard info.isDirectory else { return }

        let rootPath = contentRootURL.standardizedFileURL.path
        var candidates = Set<URL>()
        for span in spans {
            var parent = span.url.deletingLastPathComponent().standardizedFileURL
            while parent.path.hasPrefix(rootPath) {
                candidates.insert(parent)
                if parent.path == rootPath { break }
                parent = parent.deletingLastPathComponent()
            }
        }
        candidates.insert(contentRootURL.standardizedFileURL)
        for directory in candidates.sorted(by: { $0.path.count > $1.path.count }) {
            let contents = try? fileManager.contentsOfDirectory(atPath: directory.path)
            if contents?.isEmpty == true {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    // MARK: - Allocation

    /// Ensures every wanted file exists at its final path (if already complete)
    /// or as a `.part` file, sized correctly. Files that no wanted piece
    /// overlaps are skipped entirely — not created on disk. Returns true if any
    /// file already held data — the caller should then verify or trust resume.
    ///
    /// `wantedPieces` nil means every file is wanted.
    func preallocate(wantedPieces: Bitfield? = nil) throws -> Bool {
        let fileManager = FileManager.default
        var hadExistingData = false
        for span in spans {
            // Skip files with no wanted overlapping piece (they never receive
            // data, so there's no reason to occupy a filename for them).
            if let wantedPieces, span.length > 0, let range = pieceRange(for: span),
               !range.contains(where: { wantedPieces[$0] }) {
                continue
            }

            try fileManager.createDirectory(
                at: span.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Zero-length files are trivially complete: create the final file.
            if span.length == 0 {
                if !fileManager.fileExists(atPath: span.url.path) {
                    fileManager.createFile(atPath: span.url.path, contents: nil)
                }
                finalized[span.index] = true
                continue
            }

            let part = partURL(span)
            let finalSize = sizeOfFile(at: span.url)
            let partSize = sizeOfFile(at: part)

            if let partSize {
                // Resume an in-progress file.
                if partSize > 0 { hadExistingData = true }
                finalized[span.index] = false
                if partSize != span.length {
                    try handle(for: span, creatingIfNeeded: true).truncate(atOffset: UInt64(span.length))
                }
            } else if let finalSize, finalSize == span.length {
                // A finished file from a previous run. Trust tentatively;
                // reconcile(have:) de-finalizes it if verification disagrees.
                hadExistingData = true
                finalized[span.index] = true
            } else if let finalSize {
                // A wrong-sized final file (e.g. partial data from an older
                // build): migrate it to a .part and keep the bytes.
                if finalSize > 0 { hadExistingData = true }
                try? fileManager.moveItem(at: span.url, to: part)
                finalized[span.index] = false
                try handle(for: span, creatingIfNeeded: true).truncate(atOffset: UInt64(span.length))
            } else {
                // Fresh download: create and size the .part file.
                finalized[span.index] = false
                try handle(for: span, creatingIfNeeded: true).truncate(atOffset: UInt64(span.length))
            }
        }
        return hadExistingData
    }

    // MARK: - Finalization

    private func pieceRange(for span: FileSpan) -> ClosedRange<Int>? {
        guard span.length > 0 else { return nil }
        let first = Int(span.globalOffset / Int64(info.pieceLength))
        let last = Int((span.globalOffset + span.length - 1) / Int64(info.pieceLength))
        return first...last
    }

    private func fileIsComplete(_ span: FileSpan, have: Bitfield) -> Bool {
        guard let range = pieceRange(for: span) else { return true } // zero-length
        for piece in range where !have[piece] {
            return false
        }
        return true
    }

    /// Finalizes files that just became complete because `piece` was verified.
    /// Returns the relative paths of any files renamed to their final name.
    @discardableResult
    func finalizeCompletedFiles(after piece: Int, have: Bitfield) -> [String] {
        var names: [String] = []
        for span in spans where !finalized[span.index] {
            guard let range = pieceRange(for: span), range.contains(piece) else { continue }
            if fileIsComplete(span, have: have) {
                finalize(span)
                names.append(span.relativePath)
            }
        }
        return names
    }

    /// Brings on-disk file naming in line with `have`: finalizes complete
    /// files and reverts any final file that is actually incomplete back to a
    /// `.part` (corruption, or a download migrated from an older build).
    func reconcile(have: Bitfield) {
        for span in spans {
            let complete = fileIsComplete(span, have: have)
            if complete, !finalized[span.index] {
                finalize(span)
            } else if !complete, finalized[span.index] {
                deFinalize(span)
            }
        }
    }

    private func finalize(_ span: FileSpan) {
        guard !finalized[span.index] else { return }
        closeHandle(span.index)
        let fileManager = FileManager.default
        let part = partURL(span)
        if fileManager.fileExists(atPath: part.path) {
            try? fileManager.removeItem(at: span.url) // paranoia; shouldn't exist
            try? fileManager.moveItem(at: part, to: span.url)
        } else if !fileManager.fileExists(atPath: span.url.path) {
            fileManager.createFile(atPath: span.url.path, contents: nil)
        }
        finalized[span.index] = true
    }

    private func deFinalize(_ span: FileSpan) {
        guard finalized[span.index] else { return }
        closeHandle(span.index)
        let fileManager = FileManager.default
        let part = partURL(span)
        if fileManager.fileExists(atPath: span.url.path) {
            try? fileManager.removeItem(at: part) // remove any stale .part
            try? fileManager.moveItem(at: span.url, to: part)
        }
        finalized[span.index] = false
    }

    // MARK: - I/O

    func writePiece(_ pieceData: Data, at index: Int) throws {
        let data = Data(pieceData) // normalize slices to zero-based indices
        try withSpans(pieceIndex: index, length: data.count) { span, fileOffset, dataRange in
            let handle = try handle(for: span, creatingIfNeeded: true)
            try handle.seek(toOffset: UInt64(fileOffset))
            try handle.write(contentsOf: data.subdata(in: dataRange))
        }
    }

    func readBlock(index: Int, begin: Int, length: Int) throws -> Data {
        guard index >= 0, index < info.pieceCount,
              begin >= 0, length > 0,
              begin + length <= info.pieceSize(at: index)
        else { throw StorageError.outOfRange }
        var out = Data(count: length)
        try withSpans(pieceIndex: index, offsetInPiece: begin, length: length) { span, fileOffset, dataRange in
            // Never create a missing file on read: an absent file means a
            // skipped/unwanted piece, which verification skips gracefully.
            let handle = try handle(for: span, creatingIfNeeded: false)
            try handle.seek(toOffset: UInt64(fileOffset))
            guard let chunk = try handle.read(upToCount: dataRange.count),
                  chunk.count == dataRange.count
            else { throw StorageError.ioFailure("short read from \(span.url.lastPathComponent)") }
            out.replaceSubrange(dataRange, with: chunk)
        }
        return out
    }

    func readPiece(_ index: Int) throws -> Data {
        try readBlock(index: index, begin: 0, length: info.pieceSize(at: index))
    }

    /// How far through the current `verifyAllPieces` scan we are, 0...1.
    /// Polled by the controller's tick rather than pushed through a callback,
    /// which keeps the reporting rate at 1 Hz for free.
    private(set) var verifyProgress: Double = 0

    /// Hash-checks every piece against the metadata (initial add of existing
    /// data, or resume without trusted state). Unreadable pieces are simply
    /// not marked.
    ///
    /// Yields periodically so a 50 GB re-check does not hold this actor for
    /// minutes, and honours cancellation so removing a torrent mid-scan stops
    /// the work instead of waiting it out. A cancelled scan returns what it
    /// verified so far; callers treat that as "these pieces are known good",
    /// which is true — it is only incomplete.
    func verifyAllPieces() async -> Bitfield {
        var have = Bitfield(count: info.pieceCount)
        verifyProgress = 0
        defer { verifyProgress = 0 }
        for index in 0..<info.pieceCount {
            if index % 64 == 0 {
                if Task.isCancelled { return have }
                verifyProgress = Double(index) / Double(info.pieceCount)
                await Task.yield()
            }
            guard let piece = try? readPiece(index) else { continue }
            if Data(Insecure.SHA1.hash(data: piece)) == info.pieceHashes[index] {
                have[index] = true
            }
        }
        return have
    }

    func close() {
        for handle in handles.values {
            try? handle.close()
        }
        handles.removeAll()
    }

    // MARK: - Piece/file mapping

    /// Invokes `body` for each file span overlapping the given piece range,
    /// passing the offset within that file and the corresponding range within
    /// the piece-local data buffer.
    private func withSpans(
        pieceIndex: Int,
        offsetInPiece: Int = 0,
        length: Int,
        _ body: (FileSpan, Int64, Range<Int>) throws -> Void
    ) rethrows {
        let globalStart = Int64(pieceIndex) * Int64(info.pieceLength) + Int64(offsetInPiece)
        let globalEnd = globalStart + Int64(length)
        for span in spans where span.length > 0 {
            let spanEnd = span.globalOffset + span.length
            let overlapStart = max(globalStart, span.globalOffset)
            let overlapEnd = min(globalEnd, spanEnd)
            guard overlapStart < overlapEnd else { continue }
            let fileOffset = overlapStart - span.globalOffset
            let dataRange = Int(overlapStart - globalStart)..<Int(overlapEnd - globalStart)
            try body(span, fileOffset, dataRange)
        }
    }

    private func sizeOfFile(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    private func closeHandle(_ index: Int) {
        if let handle = handles.removeValue(forKey: index) {
            try? handle.close()
        }
    }

    /// Cached read/write handle for a span, opened at its currently active
    /// path (final or `.part`). Writes create the file if missing; reads throw
    /// on a missing file rather than resurrecting a skipped one.
    private func handle(for span: FileSpan, creatingIfNeeded: Bool) throws -> FileHandle {
        if let existing = handles[span.index] {
            return existing
        }
        let url = activeURL(span)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            guard creatingIfNeeded else {
                throw StorageError.ioFailure("missing \(url.lastPathComponent)")
            }
            try? fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forUpdating: url)
            handles[span.index] = handle
            return handle
        } catch {
            throw StorageError.ioFailure("cannot open \(url.path): \(error)")
        }
    }
}
