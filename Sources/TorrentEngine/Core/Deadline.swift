// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Runs `work`, but stops waiting for it after `seconds` and cancels it.
///
/// Used for shutdown courtesies — tracker "stopped" announces, releasing the
/// router port mapping — which talk to the network and must never hold up
/// quitting. A dead tracker would otherwise block until URLSession's own
/// 60-second timeout.
func withDeadline(seconds: Double, _ work: @Sendable @escaping () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await work() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
        _ = await group.next()
        group.cancelAll()
    }
}
