import AppKit
import MarginKit
import Testing

@Suite struct ClipboardMarkTests {
    let a = UUID(), b = UUID()

    /// `observe` is mutating, so it can't run inside `#expect`.
    func observe(_ mark: inout ClipboardMark, _ count: Int) -> Bool {
        mark.observe(changeCount: count)
    }

    @Test func startsEmpty() {
        var mark = ClipboardMark()
        #expect(mark.itemID == nil && mark.changeCount == -1)
        let r1 = observe(&mark, 0), r2 = observe(&mark, -1)
        #expect(!r1 && !r2)
        #expect(mark.itemID == nil)
    }

    @Test func writeThenSameCountKeepsMark() {
        var mark = ClipboardMark()
        mark.didWrite(itemID: a, changeCount: 5)
        #expect(mark.itemID == a && mark.changeCount == 5)
        let r1 = observe(&mark, 5), r2 = observe(&mark, 5)
        #expect(!r1 && !r2)
        #expect(mark.itemID == a)
    }

    @Test func otherCopyClearsMarkOnce() {
        var mark = ClipboardMark()
        mark.didWrite(itemID: a, changeCount: 5)
        let cleared = observe(&mark, 6)
        #expect(cleared)
        #expect(mark.itemID == nil)
        let again = observe(&mark, 7), back = observe(&mark, 5)
        #expect(!again && !back) // already cleared: no second report
    }

    @Test func anyDifferentCountClears() {
        var mark = ClipboardMark()
        mark.didWrite(itemID: a, changeCount: 5)
        let cleared = observe(&mark, 4) // e.g. a pasteboard server restart
        #expect(cleared && mark.itemID == nil)
    }

    @Test func secondWriteMovesMark() {
        var mark = ClipboardMark()
        mark.didWrite(itemID: a, changeCount: 5)
        mark.didWrite(itemID: b, changeCount: 7)
        #expect(mark.itemID == b && mark.changeCount == 7)
        let same = observe(&mark, 7)
        #expect(!same && mark.itemID == b)
        let other = observe(&mark, 5)
        #expect(other && mark.itemID == nil)
    }

    @Test func writeAfterClearMarksAgain() {
        var mark = ClipboardMark()
        mark.didWrite(itemID: a, changeCount: 5)
        _ = observe(&mark, 6)
        mark.didWrite(itemID: a, changeCount: 8)
        let r = observe(&mark, 8)
        #expect(!r && mark.itemID == a)
    }

    @Test func removingOtherItemKeepsMark() {
        var mark = ClipboardMark()
        mark.didWrite(itemID: a, changeCount: 5)
        mark.itemRemoved(b)
        #expect(mark.itemID == a)
    }

    @Test func removingMarkedItemClearsIt() {
        var mark = ClipboardMark()
        mark.didWrite(itemID: a, changeCount: 5)
        mark.itemRemoved(a)
        #expect(mark.itemID == nil)
        let r = observe(&mark, 6)
        #expect(!r) // nothing left to clear
    }

    @Test func explicitClear() {
        var mark = ClipboardMark()
        mark.didWrite(itemID: a, changeCount: 5)
        mark.clear()
        #expect(mark.itemID == nil)
        let r = observe(&mark, 9)
        #expect(!r)
    }

    @Test func equatable() {
        var x = ClipboardMark(), y = ClipboardMark()
        #expect(x == y)
        x.didWrite(itemID: a, changeCount: 1)
        #expect(x != y)
        y.didWrite(itemID: a, changeCount: 1)
        #expect(x == y)
    }
}

/// Uses a private, uniquely named pasteboard: the user's clipboard is never touched.
@MainActor @Suite struct ClipboardWriterTests {
    @Test func writesPNGOnlyAndReadsBack() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let png = try PNGWriter.encode(makeImage(width: 80, height: 60), scale: 2)
        let count = ClipboardWriter.write(pngs: [png], to: pb)
        #expect(count == pb.changeCount)
        #expect(pb.pasteboardItems?.count == 1)
        #expect(pb.pasteboardItems?.first?.types == [.png])
        // Same list `screencapture -c` produces on macOS 27: the server adds the legacy and TIFF translations.
        #expect(pb.types?.map(\.rawValue) == ["public.png", "Apple PNG pasteboard type", "public.tiff", "NeXT TIFF v4.0 pasteboard type"])
        #expect(pb.data(forType: .png) == png)
        let image = try #require(NSImage(pasteboard: pb))
        #expect(image.size == CGSize(width: 40, height: 30)) // 144 dpi → points
        #expect(image.representations.first?.pixelsWide == 80)
    }

    @Test func oneItemPerImageAndReplacesOldContents() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("old", forType: .string)
        let before = pb.changeCount
        let pngs = try [makeImage(width: 4, height: 4), makeImage(width: 6, height: 2)].map { try PNGWriter.encode($0, scale: 1) }
        let count = ClipboardWriter.write(pngs: pngs, to: pb)
        #expect(count > before)
        #expect(pb.string(forType: .string) == nil)
        #expect(pb.pasteboardItems?.count == 2)
        #expect(pb.pasteboardItems?.map { $0.data(forType: .png) } == pngs)
        #expect(pb.readObjects(forClasses: [NSImage.self])?.count == 2)
    }
}
