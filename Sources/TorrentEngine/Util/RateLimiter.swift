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

    public func acquire(_ count: Int) async {
        guard bytesPerSecond != nil, count > 0 else { return }
        refill()
        while tokens < Double(count) {
            guard let rate = bytesPerSecond else { return } // limit lifted mid-wait
            let deficit = Double(count) - tokens
            let wait = min(max(deficit / rate, 0.01), 0.5)
            try? await Task.sleep(for: .seconds(wait))
            refill()
        }
        tokens -= Double(count)
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
