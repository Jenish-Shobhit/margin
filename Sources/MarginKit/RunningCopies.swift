import Foundation

/// One copy of Margin at a time. Two would each register the shortcuts, so one ⇧⌘3 would save two files, and each
/// would keep its own shelf.json (the last to write wins, and a card goes missing at the next launch). A copy that
/// starts while another runs gives way to the older one.
public enum RunningCopies {
    public struct Copy: Equatable, Sendable {
        public let processID: Int32
        /// Nil when macOS doesn't say (it then counts as the earlier one).
        public let launchDate: Date?

        public init(processID: Int32, launchDate: Date?) {
            self.processID = processID
            self.launchDate = launchDate
        }
    }

    /// The copy `me` gives way to: the earliest launched of `others` that launched before it (the same date goes by
    /// process ID). Nil when `me` is the oldest, which keeps running. Two copies starting together agree on which.
    public static func olderCopy(than me: Copy, among others: [Copy]) -> Copy? {
        others.filter { $0.processID != me.processID && isEarlier($0, than: me) }
            .min { isEarlier($0, than: $1) }
    }

    private static func isEarlier(_ a: Copy, than b: Copy) -> Bool {
        let da = a.launchDate ?? .distantPast, db = b.launchDate ?? .distantPast
        return da != db ? da < db : a.processID < b.processID
    }
}
