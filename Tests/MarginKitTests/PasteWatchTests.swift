import AppKit
import MarginKit
import Testing

@Suite struct PasteKeysTests {
    @Test func aPasteIsVWithCommandOrControl() {
        #expect(PasteKeys(v: true, command: true).isPaste)
        #expect(PasteKeys(v: true, control: true).isPaste)            // ⌃V: Claude Code, terminals
        #expect(PasteKeys(v: true, command: true, control: true).isPaste)
    }

    @Test func anythingElseIsSomeoneLooking() {
        #expect(!PasteKeys().isPaste)                                  // a clipboard manager, history, another device
        #expect(!PasteKeys(v: true).isPaste)                           // typing a v
        #expect(!PasteKeys(command: true).isPaste)                     // ⌘ held for something else
        #expect(!PasteKeys(command: true, control: true).isPaste)
    }
}

/// Uses private, uniquely named pasteboards: the user's clipboard is never touched. Reading one in this process asks the
/// provider as another app's read would.
@MainActor @Suite struct PasteWatchTests {
    final class Keys {
        var held = PasteKeys()
    }

    let shot = try! PNGWriter.encode(makeImage(width: 8, height: 6), scale: 2)
    let url = URL(fileURLWithPath: "/Users/me/Library/Application Support/Margin/Pasteboard/Screenshot 2026-10-17 at 10.00.00.png")
    let a = UUID(), b = UUID()

    func watch(_ keys: Keys, pasted: @escaping ([UUID]) -> Void = { _ in }) -> PasteWatch {
        let watch = PasteWatch(keys: { keys.held }, reportDelay: 0.01)
        watch.onPaste = pasted
        return watch
    }

    /// Lets the watch's delayed report run.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    @Test func promisesTheSameItemsACaptureWrites() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let keys = Keys()
        let w = watch(keys)
        let count = w.write([.init(id: a, png: shot, fileURL: url)], to: pb)
        #expect(count == pb.changeCount && w.changeCount == count)
        #expect(pb.pasteboardItems?.count == 1)
        #expect(pb.pasteboardItems?.first?.types == [.png, .fileURL])
        #expect(w.reads.isEmpty)   // nothing asked yet
        // What a paste gets is what the capture would have written.
        #expect(pb.data(forType: .png) == shot)
        #expect(pb.pasteboardItems?.first?.string(forType: .fileURL) == url.absoluteString)
        let image = try #require(NSImage(pasteboard: pb))
        #expect(image.representations.first?.pixelsWide == 8)
    }

    @Test func aReadWithPasteKeysIsAPaste() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let keys = Keys()
        var pasted: [[UUID]] = []
        let w = watch(keys) { pasted.append($0) }
        w.write([.init(id: a, png: shot, fileURL: url)], to: pb)
        keys.held = PasteKeys(v: true, command: true)
        _ = pb.data(forType: .png)
        await settle()
        #expect(pasted == [[a]])
        #expect(w.pasted == [a])
        #expect(w.reads.map(\.type) == ["public.png"])
    }

    @Test func aReadWithoutThemIsSomeoneLooking() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let keys = Keys()
        var pasted: [[UUID]] = []
        let w = watch(keys) { pasted.append($0) }
        w.write([.init(id: a, png: shot, fileURL: url)], to: pb)
        _ = pb.data(forType: .png)                       // a clipboard manager, say
        keys.held = PasteKeys(command: true)
        _ = pb.pasteboardItems?.first?.string(forType: .fileURL)
        await settle()
        #expect(pasted.isEmpty && w.pasted.isEmpty)
        #expect(w.reads.count == 2)
    }

    /// The pasteboard keeps what it was given: once someone has read a type, a later paste of it isn't seen. Then the
    /// card stays, which is the safe way to be wrong.
    @Test func onlyTheFirstReadOfATypeIsSeen() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let keys = Keys()
        var pasted: [[UUID]] = []
        let w = watch(keys) { pasted.append($0) }
        w.write([.init(id: a, png: shot, fileURL: url)], to: pb)
        _ = pb.data(forType: .png)
        keys.held = PasteKeys(v: true, command: true)
        _ = pb.data(forType: .png)
        await settle()
        #expect(pasted.isEmpty)
        #expect(w.reads.count == 1)
        // A terminal's paste reads the file instead, which nobody has read yet.
        _ = pb.pasteboardItems?.first?.string(forType: .fileURL)
        await settle()
        #expect(pasted == [[a]])
    }

    @Test func onePasteOfSeveralItemsIsReportedOnce() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let keys = Keys()
        var pasted: [[UUID]] = []
        let w = watch(keys) { pasted.append($0) }
        w.write([.init(id: a, png: shot, fileURL: url), .init(id: b, png: shot, fileURL: url)], to: pb)
        keys.held = PasteKeys(v: true, control: true)
        for item in pb.pasteboardItems ?? [] {
            _ = item.data(forType: .png)
            _ = item.string(forType: .fileURL)
        }
        await settle()
        #expect(pasted == [[a, b]])
    }

    /// Once a paste has read everything, the pasteboard is done with the watch, and Margin may let it go: the paste is
    /// still reported, and the image is no longer held.
    @Test func aPasteIsReportedAfterTheWatchIsLetGo() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let keys = Keys()
        var pasted: [[UUID]] = []
        var w: PasteWatch? = watch(keys) { pasted.append($0) }
        w?.write([.init(id: a, png: shot, fileURL: url)], to: pb)
        keys.held = PasteKeys(v: true, command: true)
        _ = pb.data(forType: .png)
        _ = pb.pasteboardItems?.first?.string(forType: .fileURL)
        #expect(w?.isFinished == true)
        w = nil
        await settle()
        #expect(pasted == [[a]])
    }

    @Test func unwatchedItemsNeverReport() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let keys = Keys()
        var pasted: [[UUID]] = []
        let w = watch(keys) { pasted.append($0) }
        let movie = URL(fileURLWithPath: "/Users/me/Desktop/Screenshots/Screen Recording 2026-10-17 at 10.00.00.mp4")
        w.write([.init(id: a, png: nil, fileURL: movie, watched: false), .init(id: b, png: shot, fileURL: url)], to: pb)
        #expect(pb.pasteboardItems?.map(\.types) == [[.fileURL], [.png, .fileURL]])
        keys.held = PasteKeys(v: true, command: true)
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map(\.path) == [movie.path, url.path])
        await settle()
        #expect(pasted == [[b]])
    }

    @Test func fulfilledDataNeedsNoMoreAsking() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let keys = Keys()
        let w = watch(keys)
        w.write([.init(id: a, png: shot, fileURL: url)], to: pb)
        w.fulfil()
        #expect(pb.data(forType: .png) == shot)
        #expect(pb.pasteboardItems?.first?.string(forType: .fileURL) == url.absoluteString)
        #expect(w.reads.isEmpty)
    }

    @Test func anotherCopyFinishesTheWatch() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let w = watch(Keys())
        w.write([.init(id: a, png: shot, fileURL: url)], to: pb)
        #expect(!w.isFinished)
        pb.clearContents()
        pb.setString("something else", forType: .string)
        await settle()
        #expect(w.isFinished)
        #expect(w.changeCount != pb.changeCount)
    }
}
