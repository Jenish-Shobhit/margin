import Foundation
import MarginKit
import Testing

/// The write side of `SystemShortcuts`, without touching the real preferences.
@Suite struct SystemShortcutsWriteTests {
    /// A dictionary like this Mac's `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys`.
    var sample: [String: Any] {
        [
            "15": ["enabled": false],
            "28": ["enabled": true, "value": ["parameters": [51, 20, 1_179_648], "type": "standard"]],
            // Rebound by the user to ⌥⌘4, with a key macOS might add some day.
            "30": ["enabled": true, "value": ["parameters": [52, 21, 1_572_864], "type": "standard"], "extra": "kept"],
            "60": ["enabled": false, "value": ["parameters": [32, 49, 262_144], "type": "standard"]],
            "164": ["enabled": true, "value": ["parameters": [8_388_608, 4_286_578_687], "type": "modifier"]],
        ]
    }

    func entry(_ d: [String: Any], _ id: Int) throws -> [String: Any] {
        try #require(d[String(id)] as? [String: Any])
    }

    func value(_ d: [String: Any], _ id: Int) throws -> NSDictionary {
        try #require(entry(d, id)["value"] as? [String: Any]) as NSDictionary
    }

    @Test func turnsAllFourOffAndBackOn() {
        let off = SystemShortcuts.applying(enabled: false, to: sample)
        #expect(SystemShortcuts.parse(off).allSatisfy { !$0.enabled })
        let on = SystemShortcuts.applying(enabled: true, to: off)
        #expect(SystemShortcuts.parse(on).allSatisfy { $0.enabled })
    }

    @Test func keepsOtherIDsUntouched() throws {
        let off = SystemShortcuts.applying(enabled: false, to: sample)
        #expect(Set(off.keys) == Set(sample.keys).union(["29", "31"]))
        for id in [15, 60, 164] {
            #expect(try entry(off, id) as NSDictionary == entry(sample, id) as NSDictionary)
        }
    }

    @Test func keepsExistingValueAndOtherKeys() throws {
        let off = SystemShortcuts.applying(enabled: false, to: sample)
        #expect(try value(off, 28) == value(sample, 28))
        #expect(try value(off, 30) == value(sample, 30))
        #expect(try entry(off, 30)["extra"] as? String == "kept")
        // The user's own binding survives a round trip, and is what Margin reads afterwards.
        let on = SystemShortcuts.applying(enabled: true, to: off)
        #expect(try value(on, 30) == value(sample, 30))
        #expect(SystemShortcuts.parse(on)[2].keys == "⌥⌘4")
    }

    @Test func createsMissingEntriesWithMacOSDefaults() throws {
        let off = SystemShortcuts.applying(enabled: false, to: [:])
        #expect(off.count == 4)
        let expected: [Int: [Int]] = [28: [51, 20, 1_179_648], 29: [51, 20, 1_441_792],
                                      30: [52, 21, 1_179_648], 31: [52, 21, 1_441_792]]
        for (id, parameters) in expected {
            let e = try entry(off, id)
            #expect(e["enabled"] as? Bool == false)
            #expect(try value(off, id) == ["parameters": parameters, "type": "standard"] as NSDictionary)
        }
    }

    @Test func nilDictionaryIsTreatedAsEmpty() {
        let off = SystemShortcuts.applying(enabled: false, to: nil)
        #expect(Set(off.keys) == ["28", "29", "30", "31"])
    }

    @Test func entryWithoutValueGetsTheDefault() throws {
        let off = SystemShortcuts.applying(enabled: false, to: ["31": ["enabled": true]])
        #expect(try value(off, 31) == ["parameters": [52, 21, 1_441_792], "type": "standard"] as NSDictionary)
    }

    @Test func malformedValueIsKeptAsIs() throws {
        let off = SystemShortcuts.applying(enabled: false, to: ["30": ["enabled": 1, "value": ["parameters": [52]]]])
        #expect(try value(off, 30) == ["parameters": [52]] as NSDictionary)
        #expect(try entry(off, 30)["enabled"] as? Bool == false)
    }

    @Test func onlyTheGivenIDsChange() throws {
        let off = SystemShortcuts.applying(enabled: false, ids: [30], to: sample)
        #expect(try entry(off, 28)["enabled"] as? Bool == true)
        #expect(try entry(off, 30)["enabled"] as? Bool == false)
        #expect(off["29"] == nil && off["31"] == nil)
    }

    @Test func idWithoutADefaultGetsOnlyEnabled() throws {
        let off = SystemShortcuts.applying(enabled: false, ids: [184], to: [:])
        #expect(try entry(off, 184) as NSDictionary == ["enabled": false] as NSDictionary)
    }

    @Test func defaultsMatchTheDefaultCombos() {
        for id in SystemShortcuts.allIDs {
            let off = SystemShortcuts.applying(enabled: true, ids: [id], to: [:])
            let parsed = SystemShortcuts.parse(off).first { $0.id == id }
            #expect(parsed?.combo == SystemShortcuts.defaultCombo(forID: id))
        }
    }

    @Test func survivesAPropertyListRoundTrip() throws {
        // What CFPreferences stores must be a valid property list (Bool, Int, String, arrays, dictionaries).
        let off = SystemShortcuts.applying(enabled: false, to: sample)
        let data = try PropertyListSerialization.data(fromPropertyList: off, format: .binary, options: 0)
        let back = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(back as NSDictionary == off as NSDictionary)
        #expect(SystemShortcuts.parse(back).allSatisfy { !$0.enabled })
    }

    // MARK: activateSettings

    @Test func activateSettingsExists() {
        #expect(FileManager.default.isExecutableFile(atPath: SystemShortcuts.activateSettingsPath))
    }

    @Test func activationSucceedsOnExitZero() throws {
        try SystemShortcuts.activate("/usr/bin/true", timeout: 5)
    }

    @Test func activationFailsOnNonZeroExit() {
        #expect(throws: SystemShortcutsError.activationFailed(1)) {
            try SystemShortcuts.activate("/usr/bin/false", timeout: 5)
        }
    }

    @Test func activationFailsWhenMissing() {
        #expect {
            try SystemShortcuts.activate("/nonexistent/activateSettings", timeout: 5)
        } throws: { error in
            guard case .activationUnavailable = error as? SystemShortcutsError else { return false }
            return true
        }
    }

    @Test func activationTimesOut() {
        let start = Date()
        #expect(throws: SystemShortcutsError.activationTimedOut) {
            try SystemShortcuts.activate("/bin/sleep", arguments: ["10"], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func errorsSayWhetherTheSettingWasSaved() {
        #expect(!SystemShortcutsError.writeFailed.isSaved)
        #expect(!SystemShortcutsError.unreadable.isSaved)
        #expect(!SystemShortcutsError.didNotStick.isSaved)
        #expect(SystemShortcutsError.activationTimedOut.isSaved)
        #expect(SystemShortcutsError.activationFailed(1).isSaved)
        #expect(SystemShortcutsError.writeFailed.errorDescription?.isEmpty == false)
    }
}
