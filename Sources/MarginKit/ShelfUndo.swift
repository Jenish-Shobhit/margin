import Foundation

/// Runs the shelf's ⌘Z one step at a time. Each step puts its cards back at the indices they had when it
/// happened (`ShelfStore.restore`), which only holds once every newer step is back. A step can take a moment
/// (its files come back from the Trash off the main thread), so a ⌘Z pressed meanwhile waits its turn instead
/// of overtaking it.
public struct UndoSequencer: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Start the newest step now, and call `finished()` when it's done.
        case run
        /// A step is running; this ⌘Z starts after it (`finished()` returns true then).
        case wait
        /// Nothing left to bring back.
        case nothing
    }

    /// A step has started and hasn't finished.
    public private(set) var isRunning = false
    /// ⌘Zs waiting for the running step, each with a step of its own on the stack.
    public private(set) var waiting = 0

    public init() {}

    /// A ⌘Z, with `available` steps on the stack (a running step is off it already).
    public mutating func request(available: Int) -> Decision {
        if isRunning {
            guard waiting < available else { return .nothing }
            waiting += 1
            return .wait
        }
        guard available > 0 else { return .nothing }
        isRunning = true
        return .run
    }

    /// The running step is done. True when a waiting ⌘Z starts now (and is running from then on).
    public mutating func finished() -> Bool {
        guard waiting > 0 else {
            isRunning = false
            return false
        }
        waiting -= 1
        return true
    }

    /// The stack emptied under waiting ⌘Zs (their steps were dropped): nothing more to run.
    public mutating func reset() {
        isRunning = false
        waiting = 0
    }
}
