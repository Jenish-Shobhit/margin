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

    // MARK: - PNG + file URL (0.0.2: ⌘V in terminals)

    /// A real file named like a capture, so readers that load the image through the file URL work too.
    func savedCapture(in dir: TempDir, name: String = "Screenshot 2026-10-14 at 22.30.35.png",
                      width: Int = 80, height: Int = 60) throws -> (png: Data, url: URL) {
        let png = try PNGWriter.encode(makeImage(width: width, height: height), scale: 2)
        let url = dir.url.appendingPathComponent(name)
        try png.write(to: url)
        return (png, url)
    }

    @Test func writesPNGAndFileURLOnOneItem() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let shot = try savedCapture(in: dir)
        let count = ClipboardWriter.write(pngs: [shot.png], fileURLs: [shot.url], to: pb)
        #expect(count == pb.changeCount)
        #expect(pb.pasteboardItems?.count == 1)
        #expect(pb.pasteboardItems?.first?.types == [.png, .fileURL]) // the image first: it's the content
        #expect(pb.data(forType: .png) == shot.png)
        #expect(pb.pasteboardItems?.first?.string(forType: .fileURL) == shot.url.absoluteString)
        // Image readers still get the image.
        let image = try #require(NSImage(pasteboard: pb))
        #expect(image.size == CGSize(width: 40, height: 30))
        #expect(image.representations.first?.pixelsWide == 80)
        #expect(pb.readObjects(forClasses: [NSImage.self])?.count == 1)
        // File readers get the saved file.
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map(\.standardizedFileURL) == [shot.url.standardizedFileURL])
        // No plain text: a text field never gets the path instead of the image.
        #expect(pb.string(forType: .string) == nil)
    }

    /// Ghostty's ⌘V (`NSPasteboard.getOpinionatedStringContents`) pastes file URLs as shell-escaped paths.
    /// Both versions: 1.3.x reads every URL on the pasteboard, newer builds read each item in order.
    @Test func terminalPasteGetsEscapedPaths() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let first = try savedCapture(in: dir)
        let second = try savedCapture(in: dir, name: "Screenshot 2026-10-14 at 22.30.35 (2).png", width: 6, height: 2)
        ClipboardWriter.write(pngs: [first.png, second.png], fileURLs: [first.url, second.url], to: pb)
        let expected = dir.url.path + #"/Screenshot\ 2026-10-14\ at\ 22.30.35.png "#
            + dir.url.path + #"/Screenshot\ 2026-10-14\ at\ 22.30.35\ \(2\).png"#
        #expect(ghostty131Paste(pb) == expected)
        #expect(ghosttyPerItemPaste(pb) == expected)
    }

    @Test func missingOrNonFileURLsLeaveThatItemPNGOnly() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let png = try PNGWriter.encode(makeImage(width: 4, height: 4), scale: 1)
        let web = try #require(URL(string: "https://example.com/shot.png"))
        ClipboardWriter.write(pngs: [png, png, png], fileURLs: [nil, web], to: pb)
        #expect(pb.pasteboardItems?.map(\.types) == [[.png], [.png], [.png]])
        #expect(pb.readObjects(forClasses: [NSURL.self])?.isEmpty ?? true)
        #expect(ghosttyPerItemPaste(pb) == nil) // as before 0.0.2: nothing for a terminal to paste
    }

    @Test func pngOnlyWriteIsWriteWithoutURLs() throws {
        let a = NSPasteboard.withUniqueName(), b = NSPasteboard.withUniqueName()
        defer { a.releaseGlobally(); b.releaseGlobally() }
        let png = try PNGWriter.encode(makeImage(width: 4, height: 4), scale: 1)
        ClipboardWriter.write(pngs: [png], to: a)
        ClipboardWriter.write(pngs: [png], fileURLs: [nil], to: b)
        #expect(a.types == b.types)
        #expect(a.pasteboardItems?.first?.types == [.png])
    }
}

/// Ghostty's shell escape (`macos/Sources/Ghostty/Ghostty.Shell.swift`): a backslash before each of these.
private func ghosttyEscape(_ string: String) -> String {
    var result = string
    for char in #"\ ()[]{}<>"'`!#$&;|*?"# + "\t" {
        result = result.replacingOccurrences(of: String(char), with: #"\"# + String(char))
    }
    return result
}

/// Ghostty 1.3.1 `getOpinionatedStringContents`: every URL on the pasteboard, else the string.
@MainActor private func ghostty131Paste(_ pb: NSPasteboard) -> String? {
    if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
        return urls.map { $0.isFileURL ? ghosttyEscape($0.path) : $0.absoluteString }.joined(separator: " ")
    }
    return pb.string(forType: .string)
}

/// Ghostty main since 49806fc (July 2026): each pasteboard item in order, its file URL else its string.
@MainActor private func ghosttyPerItemPaste(_ pb: NSPasteboard) -> String? {
    let strings = (pb.pasteboardItems ?? []).compactMap { item -> String? in
        if let plist = item.propertyList(forType: .fileURL),
           let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
            return ghosttyEscape(url.path)
        }
        return item.string(forType: .string)
    }
    return strings.isEmpty ? nil : strings.joined(separator: " ")
}
