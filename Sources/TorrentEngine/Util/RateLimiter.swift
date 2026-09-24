// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A token-bucket rate limiter shared across all connections in a session.
/// `nil` rate means unlimited (acquire returns immediately). Burst capacity is
/// one second's worth of tokens.
public actor RateLimiter {
    private var bytesPerSecond: Double?
    private var tokens: Double = 0
    private var lastRefill = ContinuousClock.now

    public init(bytesPerSecond: Int? = nil) {
        self.bytesPerSecond = bytesPerSecond.map(Double.init)
    }

    public func setRate(_ newBytesPerSecond: Int?) {
        refill()
        bytesPerSecond = newBytesPerSecond.map(Double.init)
        if let rate = bytesPerSecond {
            tokens = min(tokens, rate)
        }
    }

    /// Charges `count` bytes against the bucket, waiting for capacity.
    ///
    /// Any positive balance admits the request, and the debit may drive the
    /// bucket negative — the next refill repays it. Waiting for the balance to
    /// *cover* `count` would never terminate for a request larger than the
    /// one-second ceiling `refill` imposes, which is every 64 KiB socket read
    /// under a 64 KiB/s limit and every piece message under a 16 KiB/s one.
    /// Debiting in full keeps the long-run rate exact; an oversized request
    /// simply overshoots and pays it back as a proportionally longer pause.
    public func acquire(_ count: Int) async {
        guard bytesPerSecond != nil, count > 0 else { return }
        while true {
            refill()
            if tokens > 0 {
                tokens -= Double(count)
                return
            }
            guard let rate = bytesPerSecond else { return } // limit lifted mid-wait
            let wait = min(max(-tokens / rate, 0.005), 0.25)
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func refill() {
        let now = ContinuousClock.now
        let elapsed = lastRefill.duration(to: now)
        lastRefill = now
        guard let rate = bytesPerSecond else { return }
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(tokens + seconds * rate, rate)
    }
}
