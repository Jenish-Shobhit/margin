import Foundation
import Synchronization

/// Waiting for an answer that may never come (a framework's completion handler: a screen recording's stop, spec §14.4):
/// whichever comes first, the answer or the time limit, is taken, and a later one is dropped.
public enum TimeLimit {
    /// Calls `start` with the function its work answers through, and returns that answer, or `timedOut()` if none came
    /// within `seconds`. `timedOut` runs only when the time is up with no answer.
    public static func answer<T: Sendable>(within seconds: TimeInterval, _ start: (@escaping @Sendable (T) -> Void) -> Void,
                                           timedOut: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            let answer = FirstAnswer(c)
            start { value in answer.resume(value) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, seconds)) {
                answer.resume(timedOut())
            }
        }
    }
}

/// A continuation resumed once, by the first answer; later ones are dropped, and not even worked out.
final class FirstAnswer<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: @autoclosure () -> T) {
        guard let continuation = continuation.withLock({ $0.take() }) else { return }
        continuation.resume(returning: value())
    }
}
