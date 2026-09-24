// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

/// Build-time constants for the engine.
public enum TorrentEngineInfo {
    public static let version = "0.1.0"

    /// Azureus-style peer ID prefix: -ST<version>- (BEP 20).
    public static let peerIDPrefix = "-ST0100-"
}
