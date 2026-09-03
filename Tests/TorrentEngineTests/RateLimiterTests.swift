import Foundation
import Testing
@testable import TorrentEngine

@Suite struct RateLimiterTests {
    /// A single request larger than one second's worth of tokens must still be
    /// admitted. The receive pump asks for up to 64 KiB at a time and a piece
    /// message is ~16 KiB, so a bucket that only admitted requests it could
    /// fully cover wedged every connection under a small limit — permanently.
    @Test(.timeLimit(.minutes(1)))
    func oversizedRequestCompletes() async throws {
        let limiter = RateLimiter(bytesPerSecond: 8 * 1024)
        let start = ContinuousClock.now
        await limiter.acquire(64 * 1024) // 8x the per-second budget
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// Debiting in full (rather than clamping) keeps the long-run rate exact:
    /// 128 KiB at 32 KiB/s should take roughly four seconds, not eight and not
    /// none.
    @Test(.timeLimit(.minutes(1)))
    func averageRateIsHonoured() async throws {
        let limiter = RateLimiter(bytesPerSecond: 32 * 1024)
        let start = ContinuousClock.now
        for _ in 0..<8 {
            await limiter.acquire(16 * 1024)
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed > .seconds(2))
        #expect(elapsed < .seconds(7))
    }

    /// An oversized request overshoots into deficit; the next one waits for it
    /// to be repaid rather than being admitted for free.
    @Test(.timeLimit(.minutes(1)))
    func deficitIsRepaidBeforeTheNextRequest() async throws {
        let limiter = RateLimiter(bytesPerSecond: 16 * 1024)
        await limiter.acquire(64 * 1024) // four seconds of budget in one go
        let start = ContinuousClock.now
        await limiter.acquire(1024)
        #expect(ContinuousClock.now - start > .seconds(2))
    }

    // Moved here from PersistenceTests.swift, where this suite used to live.

    @Test func pacesAcquisitions() async throws {
        // 100 KiB/s budget, 300 KiB of traffic → at least ~2s (minus the 1s burst).
        let limiter = RateLimiter(bytesPerSecond: 100 * 1024)
        let start = ContinuousClock.now
        for _ in 0..<30 {
            await limiter.acquire(10 * 1024)
        }
        let elapsed = start.duration(to: .now)
        #expect(elapsed >= .seconds(1.5), "elapsed \(elapsed)")
    }

    @Test func unlimitedIsImmediate() async {
        let limiter = RateLimiter(bytesPerSecond: nil)
        let start = ContinuousClock.now
        for _ in 0..<100 {
            await limiter.acquire(1 << 20)
        }
        #expect(start.duration(to: .now) < .seconds(1))
    }
}
