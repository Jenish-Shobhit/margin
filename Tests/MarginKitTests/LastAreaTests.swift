import CoreGraphics
import Foundation
import MarginKit
import Testing

/// What 0.0.8 and earlier stored under `lastArea`: a rect in AppKit global points.
struct LegacyLastArea: Codable {
    var rect: CGRect
    var displayID: UInt32
}

@Suite struct LastAreaTests {
    let macBook = CGRect(x: 0, y: 0, width: 1470, height: 956)
    /// A 1920 × 1080 display to the right of the MacBook, while the MacBook is primary.
    let externalRight = CGRect(x: 1470, y: 0, width: 1920, height: 1080)

    @Test func sameArrangementGivesTheSameRect() {
        let rect = CGRect(x: 1600, y: 200, width: 400, height: 300)
        let area = LastArea(rect: rect, displayID: 2, displayFrame: externalRight)
        #expect(area.rectInDisplay == CGRect(x: 130, y: 200, width: 400, height: 300))
        #expect(area.displaySize == CGSize(width: 1920, height: 1080))
        #expect(area.rect(onDisplayFrame: externalRight) == rect)
    }

    @Test func followsItsDisplayWhenItBecomesPrimary() {
        // The lid closes: the external display becomes primary at the origin. Same area, not a 320 pt strip.
        let area = LastArea(rect: CGRect(x: 1600, y: 200, width: 400, height: 300), displayID: 2, displayFrame: externalRight)
        #expect(area.rect(onDisplayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
                == CGRect(x: 130, y: 200, width: 400, height: 300))
    }

    @Test func followsItsDisplayToTheLeftAndBelow() {
        let area = LastArea(rect: CGRect(x: 1600, y: 200, width: 400, height: 300), displayID: 2, displayFrame: externalRight)
        #expect(area.rect(onDisplayFrame: CGRect(x: -1920, y: -124, width: 1920, height: 1080))
                == CGRect(x: -1790, y: 76, width: 400, height: 300))
    }

    @Test func fractionalPointsSurvive() {
        let display = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let rect = CGRect(x: -400.5, y: 20, width: 300, height: 200.25)
        let area = LastArea(rect: rect, displayID: 42, displayFrame: display)
        #expect(area.rect(onDisplayFrame: display) == rect)
        #expect(area.rect(onDisplayFrame: display.offsetBy(dx: 3390, dy: 0)) == rect.offsetBy(dx: 3390, dy: 0))
    }

    @Test func anotherResolutionGivesNil() {
        let area = LastArea(rect: CGRect(x: 1600, y: 200, width: 400, height: 300), displayID: 2, displayFrame: externalRight)
        #expect(area.rect(onDisplayFrame: CGRect(x: 1470, y: 0, width: 2560, height: 1440)) == nil)
        #expect(area.rect(onDisplayFrame: CGRect(x: 1470, y: 0, width: 1920, height: 1200)) == nil)
    }

    @Test func partOutsideTheDisplayIsDropped() {
        let area = LastArea(rect: CGRect(x: 1300, y: -50, width: 400, height: 300), displayID: 2, displayFrame: externalRight)
        #expect(area.rectInDisplay == CGRect(x: 0, y: 0, width: 230, height: 250))
        #expect(area.rect(onDisplayFrame: externalRight) == CGRect(x: 1470, y: 0, width: 230, height: 250))
    }

    @Test func areaOffItsDisplayGivesNil() {
        let area = LastArea(rect: CGRect(x: 100, y: 100, width: 50, height: 50), displayID: 2, displayFrame: externalRight)
        #expect(area.rectInDisplay == .zero)
        #expect(area.rect(onDisplayFrame: externalRight) == nil)
    }

    @Test func storedRectOutsideTheDisplayGivesNil() {
        var area = LastArea(rect: CGRect(x: 1600, y: 200, width: 400, height: 300), displayID: 2, displayFrame: externalRight)
        area.rectInDisplay = CGRect(x: 1700, y: 200, width: 400, height: 300)
        #expect(area.rect(onDisplayFrame: externalRight) == nil)
        area.rectInDisplay = CGRect(x: 10, y: 10, width: 0, height: 300)
        #expect(area.rect(onDisplayFrame: externalRight) == nil)
    }

    @Test func codableRoundTrip() throws {
        let area = LastArea(rect: CGRect(x: 1600, y: 200, width: 400, height: 300), displayID: 2, displayFrame: externalRight)
        let data = try JSONEncoder().encode(area)
        #expect(try JSONDecoder().decode(LastArea.self, from: data) == area)
    }

    @Test func legacyGlobalFormatDoesNotDecode() throws {
        let legacy = try JSONEncoder().encode(LegacyLastArea(rect: CGRect(x: 1600, y: 200, width: 400, height: 300), displayID: 2))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LastArea.self, from: legacy) }
    }

    @Test func newFormatHasNoGlobalRectForOlderVersions() throws {
        // 0.0.8 reading this after a downgrade must not take the display-relative rect for a global one.
        let data = try JSONEncoder().encode(LastArea(rect: CGRect(x: 1600, y: 200, width: 400, height: 300), displayID: 2,
                                                     displayFrame: externalRight))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LegacyLastArea.self, from: data) }
    }
}
