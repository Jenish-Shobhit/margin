import CoreGraphics
import MarginKit
import Testing

@Suite struct WindowPickingTests {
    /// A 1470 × 956 laptop display, and a 1920 × 1080 one to its left.
    let laptop = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let external = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    var displays: [CGRect] { [laptop, external] }

    func role(_ layer: Int, _ frame: CGRect) -> WindowPicking.Role {
        WindowPicking.role(layer: layer, frame: frame, displays: displays)
    }

    @Test func aWindowIsUncoveredWhenNothingInFrontOverlapsIt() {
        let window = CGRect(x: 200, y: 150, width: 900, height: 600)
        #expect(WindowPicking.isUncovered(window, inFront: []))
        #expect(WindowPicking.isUncovered(window, inFront: [CGRect(x: 1100, y: 150, width: 300, height: 300)]))  // touching
        #expect(WindowPicking.isUncovered(window, inFront: [CGRect(x: 0, y: 923, width: 1470, height: 33)]))     // the menu bar
        #expect(!WindowPicking.isUncovered(window, inFront: [CGRect(x: 1000, y: 650, width: 300, height: 300)])) // over a corner
        #expect(!WindowPicking.isUncovered(window, inFront: [CGRect(x: 300, y: 0, width: 870, height: 160)]))    // the Dock
        #expect(!WindowPicking.isUncovered(window, inFront: [CGRect(x: 400, y: 300, width: 100, height: 100)]))  // inside it
    }

    @Test func theLevels() {
        #expect(WindowPicking.dockLevel == 20)
        #expect(WindowPicking.popUpMenuLevel == 101)
    }

    @Test func normalWindowsArePickedWhateverTheirSize() {
        #expect(role(0, CGRect(x: 100, y: 100, width: 600, height: 400)) == .pickable)
        #expect(role(0, laptop) == .pickable)                                            // full screen
        #expect(role(0, CGRect(x: -100, y: -300, width: 3000, height: 2000)) == .pickable)
    }

    @Test func floatingWindowsArePicked() {
        let panel = CGRect(x: 400, y: 350, width: 300, height: 220)
        #expect(role(3, panel) == .pickable)    // NSWindow.Level.floating: utility panels, "always on top", PiP
        #expect(role(8, panel) == .pickable)    // modal panel
        #expect(role(19, panel) == .pickable)   // utility
        // Partly off screen, or zoomed to the visible frame, it's still a window.
        #expect(role(3, CGRect(x: 1300, y: 600, width: 400, height: 300)) == .pickable)
        #expect(role(3, CGRect(x: 0, y: 0, width: 1470, height: 922)) == .pickable)
        #expect(role(3, CGRect(x: -1900, y: 100, width: 1900, height: 900)) == .pickable)   // on the bigger display
    }

    @Test func systemUICoversWithoutBeingPicked() {
        #expect(role(20, CGRect(x: 300, y: 0, width: 870, height: 80)) == .cover)        // the Dock
        #expect(role(21, CGRect(x: 1100, y: 850, width: 360, height: 90)) == .cover)     // a notification banner
        #expect(role(24, CGRect(x: 0, y: 923, width: 1470, height: 33)) == .cover)       // the menu bar
        #expect(role(25, CGRect(x: 1200, y: 923, width: 40, height: 33)) == .cover)      // a status item
        #expect(role(100, CGRect(x: 300, y: 300, width: 800, height: 300)) == .cover)
    }

    @Test func menusAndAboveAreIgnored() {
        let rect = CGRect(x: 300, y: 300, width: 300, height: 400)
        #expect(role(101, rect) == .ignored)    // pop-up menus
        #expect(role(1000, rect) == .ignored)   // Margin's shelf (.screenSaver)
        #expect(role(1001, rect) == .ignored)   // its overlay
        #expect(role(-2147483624, rect) == .ignored)
    }

    @Test func overlaysAboveNormalWindowsAreIgnored() {
        // A floating companion's see-through canvas, taller than the display (seen at layer 3 on the dev machine).
        #expect(role(3, CGRect(x: 31, y: -432, width: 1132, height: 1813)) == .ignored)
        // Covering a whole display, at a floating level or the Dock's.
        #expect(role(3, laptop) == .ignored)
        #expect(role(20, external) == .ignored)
        // Wider than any display it's on.
        #expect(role(25, CGRect(x: -1920, y: 0, width: 3390, height: 30)) == .ignored)
        // On no display at all.
        #expect(role(3, CGRect(x: 5000, y: 5000, width: 300, height: 200)) == .ignored)
    }
}
