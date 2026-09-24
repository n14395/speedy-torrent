// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Relocating a torrent's content on disk.
///
/// The engine sizes its `.part` files up front with `truncate`, which makes
/// them *sparse*: a half-finished 150 GB torrent reads as 150 GB long but
/// occupies only what has actually arrived. `FileManager.moveItem` knows
/// nothing about that, so across volumes it reads every hole back as zeros and
/// writes them out for real — the move costs the torrent's full length instead
/// of its downloaded size, and the file lands fully allocated at the other end.
///
/// So: rename where a rename will do, and where it won't, copy through
/// `copyfile(3)` with `COPYFILE_DATA_SPARSE`, which carries the holes across.
enum SparseMove {
    struct Failure: LocalizedError {
        let operation: String
        let path: String
        let code: Int32

        var errorDescription: String? {
            "\(operation) “\(URL(fileURLWithPath: path).lastPathComponent)”: "
                + String(cString: strerror(code))
        }
    }

    /// Moves a file or directory tree. Within one volume this is a rename and
    /// moves no data at all; across volumes it copies holes-and-all and then
    /// removes the source, so a failure part-way leaves the source untouched.
    static func move(from source: URL, to destination: URL) throws {
        if rename(source.path, destination.path) == 0 { return }
        let renameError = errno
        // EXDEV is the expected "different volume" answer; anything else is a
        // real failure and worth reporting as one rather than copying blindly.
        guard renameError == EXDEV else {
            throw Failure(operation: "Could not move", path: source.path, code: renameError)
        }
        try copyPreservingHoles(from: source, to: destination)
        try FileManager.default.removeItem(at: source)
    }

    /// Copies a file or directory tree, keeping sparse regions sparse. The
    /// destination is removed again if the copy fails, so a torrent is never
    /// left split across two folders.
    static func copyPreservingHoles(from source: URL, to destination: URL) throws {
        guard let state = copyfile_state_alloc() else {
            throw Failure(operation: "Could not prepare to copy", path: source.path, code: ENOMEM)
        }
        defer { copyfile_state_free(state) }
        let flags = copyfile_flags_t(
            COPYFILE_ALL          // data plus permissions, dates and xattrs
                | COPYFILE_RECURSIVE  // multi-file torrents are a directory
                | COPYFILE_NOFOLLOW   // copy a symlink, never what it points at
                | COPYFILE_DATA_SPARSE
        )
        guard copyfile(source.path, destination.path, state, flags) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: destination)
            throw Failure(operation: "Could not copy", path: source.path, code: code)
        }
    }
}
