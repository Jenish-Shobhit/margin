import Foundation
import MarginKit
import Testing

@Suite struct RunningCopiesTests {
    typealias Copy = RunningCopies.Copy
    let t = Date(timeIntervalSince1970: 1_791_999_737)

    @Test func aloneItKeepsRunning() {
        let me = Copy(processID: 500, launchDate: t)
        #expect(RunningCopies.olderCopy(than: me, among: []) == nil)
        #expect(RunningCopies.olderCopy(than: me, among: [me]) == nil)
    }

    @Test func theNewerCopyGivesWay() {
        let old = Copy(processID: 900, launchDate: t)
        let new = Copy(processID: 400, launchDate: t.addingTimeInterval(3600))
        #expect(RunningCopies.olderCopy(than: new, among: [old, new]) == old)
        #expect(RunningCopies.olderCopy(than: old, among: [old, new]) == nil)
    }

    @Test func itGivesWayToTheOldestOfSeveral() {
        let a = Copy(processID: 10, launchDate: t)
        let b = Copy(processID: 20, launchDate: t.addingTimeInterval(5))
        let me = Copy(processID: 30, launchDate: t.addingTimeInterval(9))
        #expect(RunningCopies.olderCopy(than: me, among: [b, a]) == a)
    }

    @Test func startingTogetherTheyAgree() {
        // The same launch date: the lower process ID stays, whichever copy asks.
        let a = Copy(processID: 10, launchDate: t)
        let b = Copy(processID: 20, launchDate: t)
        #expect(RunningCopies.olderCopy(than: a, among: [b]) == nil)
        #expect(RunningCopies.olderCopy(than: b, among: [a]) == a)
    }

    @Test func anUnknownLaunchDateCountsAsEarlier() {
        let unknown = Copy(processID: 70, launchDate: nil)
        let me = Copy(processID: 60, launchDate: t)
        #expect(RunningCopies.olderCopy(than: me, among: [unknown]) == unknown)
        #expect(RunningCopies.olderCopy(than: unknown, among: [me]) == nil)
    }
}
