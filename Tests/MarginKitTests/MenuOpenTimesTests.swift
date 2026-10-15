import Foundation
import MarginKit
import Testing

@Suite struct MenuOpenTimesTests {
    @Test func aPressWhileTheMenuWasOpenIsHeld() {
        var times = MenuOpenTimes()
        #expect(!times.held(5))
        times.menuOpened(at: 10)
        times.menuClosed(at: 14)
        #expect(times.held(10))
        #expect(times.held(12.5))
        #expect(times.held(14 - MenuOpenTimes.closing))
        #expect(!times.held(9.99))   // pressed before it opened (delivered late anyway: not ours to drop)
        #expect(!times.held(14.01))  // pressed after it closed
    }

    @Test func aPressAsTheMenuWasClosingGoesThrough() {
        // Esc at 13.75; the menu fades out and AppKit reports the close at 14. A key pressed at 13.85, just after the
        // Esc, is delivered then: it goes through.
        var times = MenuOpenTimes()
        times.menuOpened(at: 10)
        times.menuClosed(at: 14)
        #expect(!times.held(13.85))
        #expect(!times.held(14 - MenuOpenTimes.closing + 0.01))
        #expect(MenuOpenTimes.closing >= 0.35 && MenuOpenTimes.closing <= 0.6)
    }

    @Test func onlyTheLastMenuCounts() {
        var times = MenuOpenTimes()
        times.menuOpened(at: 10)
        times.menuClosed(at: 14)
        times.menuOpened(at: 20)
        times.menuClosed(at: 22)
        #expect(!times.held(12))
        #expect(times.held(20.5))
    }

    @Test func nothingIsHeldWhileAMenuIsStillOpen() {
        // Delivered while a menu is open, a hotkey wasn't held back by it; and a close that never comes mustn't
        // swallow every shortcut from then on.
        var times = MenuOpenTimes()
        times.menuOpened(at: 10)
        #expect(!times.held(11))
        times.menuOpened(at: 30)   // a second open without a close
        #expect(!times.held(31))
    }

    @Test func aMenuInsideAnotherCountsOnce() {
        var times = MenuOpenTimes()
        times.menuOpened(at: 10)
        times.menuOpened(at: 11)
        times.menuClosed(at: 12)
        #expect(!times.held(10.5))     // the outer menu is still open
        times.menuClosed(at: 14)
        #expect(times.held(10.5))
        #expect(times.held(12.5))
    }

    @Test func aCloseWithoutAnOpenIsIgnored() {
        var times = MenuOpenTimes()
        times.menuClosed(at: 5)
        #expect(!times.held(4))
        times.menuOpened(at: 10)
        times.menuClosed(at: 12)
        times.menuClosed(at: 13)
        #expect(times.held(11))
        #expect(!times.held(12.5))
    }
}
