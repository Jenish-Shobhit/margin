import Foundation
import MarginKit
import Testing

@Suite struct UnsavedShotsTests {
    @Test func missingFolderHasNoShots() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        #expect(!UnsavedShots.exist(in: dir.url.appendingPathComponent("Unsaved", isDirectory: true)))
    }

    @Test func emptyFolderHasNoShots() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        #expect(!UnsavedShots.exist(in: dir.url))
    }

    @Test func hiddenFilesDontCount() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        _ = try dir.file(".DS_Store")
        _ = try dir.file(".margin-\(UUID().uuidString).tmp")
        #expect(!UnsavedShots.exist(in: dir.url))
    }

    @Test func aShotCounts() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        _ = try dir.file(".DS_Store")
        _ = try dir.file("Screenshot 2026-10-15 at 14.32.05.png")
        #expect(UnsavedShots.exist(in: dir.url))
    }

    @Test func toastNamesTheFolderAndTheWayBack() {
        let text = UnsavedShots.fallbackToast(saveFolder: URL(fileURLWithPath: "/Users/me/Desktop/Screenshots", isDirectory: true))
        #expect(text.contains("“Screenshots”"))
        #expect(text.contains("Saved to Unsaved"))
        // The menu item's name, kept on one line when the toast wraps.
        #expect(text.hasSuffix("Show\u{00A0}Unsaved\u{00A0}Shots"))
        #expect(text.replacingOccurrences(of: "\u{00A0}", with: " ").contains(UnsavedShots.menuItemTitle))
    }
}
