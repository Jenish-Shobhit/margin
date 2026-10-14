import CoreGraphics
import Foundation
import MarginKit
import Testing

@Suite struct UndoSequencerTests {
    /// Feeds ⌘Zs (`.ask(available)`) and step completions (`.finish`) to a sequencer; returns what it said.
    enum Event { case ask(Int), finish }
    enum Answer: Equatable { case decision(UndoSequencer.Decision), next(Bool) }

    func play(_ events: [Event], on s: inout UndoSequencer) -> [Answer] {
        events.map { event in
            switch event {
            case .ask(let available): .decision(s.request(available: available))
            case .finish: .next(s.finished())
            }
        }
    }

    @Test func nothingToUndo() {
        var s = UndoSequencer()
        #expect(play([.ask(0)], on: &s) == [.decision(.nothing)])
        #expect(!s.isRunning)
    }

    @Test func aStepThatFinishesAtOnce() {
        var s = UndoSequencer()
        #expect(play([.ask(1)], on: &s) == [.decision(.run)])
        #expect(s.isRunning)
        #expect(play([.finish, .ask(0)], on: &s) == [.next(false), .decision(.nothing)])
        #expect(!s.isRunning)
    }

    @Test func aSecondUndoWaitsForTheFirst() {
        var s = UndoSequencer()
        // The newest of 3 steps runs (2 left); two more ⌘Zs wait; a fourth has no step left.
        #expect(play([.ask(3), .ask(2), .ask(2), .ask(2)], on: &s)
                == [.decision(.run), .decision(.wait), .decision(.wait), .decision(.nothing)])
        #expect(s.waiting == 2)
        // Each finished step starts the next waiting one, then the sequencer is idle.
        #expect(play([.finish], on: &s) == [.next(true)])
        #expect(s.isRunning && s.waiting == 1)
        #expect(play([.finish, .finish], on: &s) == [.next(true), .next(false)])
        #expect(!s.isRunning && s.waiting == 0)
    }

    @Test func resetDropsWaitingUndos() {
        var s = UndoSequencer()
        #expect(play([.ask(2), .ask(1)], on: &s) == [.decision(.run), .decision(.wait)])
        s.reset()
        #expect(s == UndoSequencer())
        #expect(play([.ask(1)], on: &s) == [.decision(.run)])
    }

    /// The bug: on [A, B, C], dismiss A, then move B to the Trash, then ⌘Z ⌘Z quickly. B's undo waits on the
    /// Trash, and A's (instant) undo used to overtake it, giving [B, A, C].
    @MainActor @Test func fastUndosLandNewestFirst() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = ShelfStore(fileURL: dir.url.appendingPathComponent("shelf.json"))
        let a = ShelfItem(url: try dir.file("a.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        let b = ShelfItem(url: try dir.file("b.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        let c = ShelfItem(url: try dir.file("c.png"), createdAt: .now, pixelSize: CGSize(width: 1, height: 1))
        [a, b, c].forEach(store.append)
        var stack = [store.remove(ids: [a.id]), store.remove(ids: [b.id])]   // dismiss A, trash B
        #expect(store.items == [c])

        var s = UndoSequencer()
        #expect(play([.ask(stack.count)], on: &s) == [.decision(.run)])
        let trashStep = stack.removeLast()                                     // B: still coming back from the Trash
        #expect(play([.ask(stack.count)], on: &s) == [.decision(.wait)])     // A waits for it
        store.restore(trashStep)
        #expect(play([.finish], on: &s) == [.next(true)])
        store.restore(stack.removeLast())
        #expect(play([.finish], on: &s) == [.next(false)])
        #expect(store.items == [a, b, c])

        // What overtaking did: A first, then B.
        let again = ShelfStore(fileURL: dir.url.appendingPathComponent("again.json"))
        [a, b, c].forEach(again.append)
        let dismissA = again.remove(ids: [a.id])
        let trashB = again.remove(ids: [b.id])
        again.restore(dismissA)
        again.restore(trashB)
        #expect(again.items == [b, a, c])
    }
}
