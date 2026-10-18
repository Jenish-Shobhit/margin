import Foundation
import MarginKit
import Synchronization
import Testing

@Suite struct TimeLimitTests {
    @Test func anAnswerInTimeIsTaken() async {
        let timedOut = Mutex(false)
        let value = await TimeLimit.answer(within: 5, { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { done(1) }
        }, timedOut: {
            timedOut.withLock { $0 = true }
            return 0
        })
        #expect(value == 1)
        // The time limit, when it comes, finds the answer given: its value isn't even worked out.
        try? await Task.sleep(for: .seconds(0.1))
        #expect(!timedOut.withLock { $0 })
    }

    @Test func noAnswerIsTheTimeLimits() async {
        let clock = ContinuousClock()
        let start = clock.now
        let value = await TimeLimit.answer(within: 0.1, { (_: @escaping @Sendable (Int) -> Void) in }, timedOut: { -1 })
        #expect(value == -1)
        #expect(clock.now - start >= .seconds(0.1))
    }

    @Test func aLateAnswerIsDropped() async {
        let value = await TimeLimit.answer(within: 0.05, { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { done(1) }
        }, timedOut: { -1 })
        #expect(value == -1)
        // Answering after the time limit doesn't resume the continuation twice (which would trap).
        try? await Task.sleep(for: .seconds(0.25))
    }

    @Test func aSecondAnswerIsDropped() async {
        let value = await TimeLimit.answer(within: 5, { done in
            done(1)
            done(2)
        }, timedOut: { -1 })
        #expect(value == 1)
    }
}
