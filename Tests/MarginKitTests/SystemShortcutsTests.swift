import Foundation
import MarginKit
import Testing

@Suite struct SystemShortcutsTests {
    /// Parses a plist the way `CFPreferencesCopyAppValue` hands it over (NSNumber, NSDictionary, …).
    func plist(_ body: String) throws -> [String: Any] {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\(body)</dict></plist>
        """
        return try #require(PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])
    }

    func enabled(_ list: [SystemScreenshotShortcut]) -> [Int: Bool] {
        Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.enabled) })
    }

    @Test func noDictionaryMeansAllEnabled() {
        let list = SystemShortcuts.parse(nil)
        #expect(list.map(\.id) == [28, 29, 30, 31, 184])
        #expect(list.allSatisfy { $0.enabled })
    }

    @Test func missingEntryMeansEnabled() throws {
        let list = SystemShortcuts.parse(try plist("<key>15</key><dict><key>enabled</key><false/></dict>"))
        #expect(list.allSatisfy { $0.enabled })
    }

    @Test func entryWithoutEnabledKeyIsEnabled() throws {
        let list = SystemShortcuts.parse(try plist("<key>30</key><dict></dict>"))
        #expect(enabled(list)[30] == true)
    }

    @Test func enabledZeroAsInteger() throws {
        let list = SystemShortcuts.parse(try plist("""
            <key>28</key><dict><key>enabled</key><integer>0</integer></dict>
            <key>29</key><dict><key>enabled</key><integer>1</integer></dict>
            """))
        #expect(enabled(list) == [28: false, 29: true, 30: true, 31: true, 184: true])
    }

    @Test func enabledAsPlistBool() throws {
        let list = SystemShortcuts.parse(try plist("""
            <key>30</key><dict><key>enabled</key><false/></dict>
            <key>31</key><dict><key>enabled</key><true/></dict>
            """))
        #expect(enabled(list) == [28: true, 29: true, 30: false, 31: true, 184: true])
    }

    @Test func enabledAsNSNumber() {
        let list = SystemShortcuts.parse([
            "28": ["enabled": NSNumber(value: 0)],
            "29": ["enabled": NSNumber(value: false)],
            "30": ["enabled": NSNumber(value: 1)],
        ])
        #expect(enabled(list) == [28: false, 29: false, 30: true, 31: true, 184: true])
    }

    @Test func enabledAsSwiftBoolAndInt() {
        let list = SystemShortcuts.parse([
            "28": ["enabled": false],
            "29": ["enabled": true],
            "30": ["enabled": 0],
            "31": ["enabled": 1],
            "184": ["enabled": false],
        ])
        #expect(enabled(list) == [28: false, 29: true, 30: false, 31: true, 184: false])
    }

    @Test func allDisabled() throws {
        let body = [28, 29, 30, 31, 184].map { "<key>\($0)</key><dict><key>enabled</key><false/></dict>" }.joined()
        #expect(SystemShortcuts.parse(try plist(body)).allSatisfy { !$0.enabled })
    }

    @Test func titlesAndDefaultKeys() {
        let list = SystemShortcuts.parse(nil)
        #expect(list.map(\.keys) == ["⇧⌘3", "⌃⇧⌘3", "⇧⌘4", "⌃⇧⌘4", "⇧⌘5"])
        #expect(list.map(\.keys) == SystemShortcuts.catalog.map(\.keys))
        #expect(list[2].title == "Save picture of selected area as a file")
        #expect(list[2].combo == ShortcutAction.captureArea.defaultCombo)
        #expect(list[3].combo == ShortcutAction.captureArea.defaultCombo.withControl)
        #expect(list[0].combo == ShortcutAction.captureScreen.defaultCombo)
        #expect(list[4].title == "Screenshot and recording options")
        #expect(list[4].combo == ShortcutAction.recordScreen.defaultCombo)
    }

    @Test func theToolbarsRealBindingIsRead() throws {
        // As macOS stores 184 once it's been touched: (53, 23, 1179648) is "5", key code 23, ⇧⌘.
        let list = SystemShortcuts.parse(try plist("""
            <key>184</key><dict><key>enabled</key><true/><key>value</key><dict>
              <key>parameters</key><array><integer>53</integer><integer>23</integer><integer>1179648</integer></array>
              <key>type</key><string>standard</string></dict></dict>
            """))
        #expect(list[4].combo == KeyCombo(keyCode: 0x17, modifiers: KeyCombo.cmd | KeyCombo.shift))
        #expect(list[4].enabled)
        // Rebound by the user to ⌥⇧⌘S: Margin's ⇧⌘5 no longer clashes with it.
        let rebound = SystemShortcuts.parse(["184": ["enabled": 1, "value": ["parameters": [115, 1, 1_703_936], "type": "standard"]]])
        #expect(rebound[4].keys == "⌥⇧⌘S")
        let margin = ShortcutAction.allCases.flatMap { $0.registeredCombos(for: $0.defaultCombo) }
        #expect(!SystemShortcuts.conflicts(rebound, with: margin).map(\.id).contains(184))
    }

    @Test func parametersGiveTheRealBinding() throws {
        // As macOS stores it: (character, key code, AppKit modifier flags). 1179648 = ⇧⌘.
        let list = SystemShortcuts.parse(try plist("""
            <key>30</key><dict><key>enabled</key><true/><key>value</key><dict>
              <key>parameters</key><array><integer>52</integer><integer>21</integer><integer>1179648</integer></array>
              <key>type</key><string>standard</string></dict></dict>
            <key>28</key><dict><key>enabled</key><true/><key>value</key><dict>
              <key>parameters</key><array><integer>65535</integer><integer>19</integer><integer>1572864</integer></array>
              <key>type</key><string>standard</string></dict></dict>
            """))
        #expect(list[2].combo == KeyCombo(keyCode: 0x15, modifiers: KeyCombo.cmd | KeyCombo.shift))
        #expect(list[2].keys == "⇧⌘4")
        // Rebound by the user to ⌥⌘2 (1572864 = ⌥ 1<<19 | ⌘ 1<<20).
        #expect(list[0].combo == KeyCombo(keyCode: 0x13, modifiers: KeyCombo.cmd | KeyCombo.option))
        #expect(list[0].keys == "⌥⌘2")
    }

    @Test func malformedParametersFallBackToDefault() {
        let list = SystemShortcuts.parse(["30": ["enabled": 1, "value": ["parameters": [52]]]])
        #expect(list[2].combo == ShortcutAction.captureArea.defaultCombo)
    }

    @Test func conflictsWithMarginDefaults() {
        let margin = ShortcutAction.allCases.flatMap { $0.registeredCombos(for: $0.defaultCombo) }
        let all = SystemShortcuts.parse(nil)
        #expect(SystemShortcuts.conflicts(all, with: margin).map(\.id) == [28, 29, 30, 31, 184])

        let someOff = SystemShortcuts.parse(["28": ["enabled": 0], "31": ["enabled": 0]])
        #expect(SystemShortcuts.conflicts(someOff, with: margin).map(\.id) == [29, 30, 184])

        // 28–31 off but 184 untouched, as on a Mac that turned them off before 0.1.0: only ⇧⌘5 is still macOS's.
        let screenshotsOff = SystemShortcuts.parse(Dictionary(uniqueKeysWithValues: (28...31).map { ("\($0)", ["enabled": 0] as [String: Any]) }))
        #expect(SystemShortcuts.conflicts(screenshotsOff, with: margin).map(\.id) == [184])

        let allOff = SystemShortcuts.parse(Dictionary(uniqueKeysWithValues: [28, 29, 30, 31, 184].map { ("\($0)", ["enabled": 0] as [String: Any]) }))
        #expect(SystemShortcuts.conflicts(allOff, with: margin).isEmpty)
    }

    @Test func noConflictWhenMarginUsesOtherKeys() {
        let altArea = KeyCombo(keyCode: 0x00, modifiers: KeyCombo.cmd | KeyCombo.option) // ⌥⌘A
        var margin = ShortcutAction.captureArea.registeredCombos(for: altArea)
        margin += ShortcutAction.captureScreen.registeredCombos(for: ShortcutAction.captureScreen.defaultCombo)
        #expect(SystemShortcuts.conflicts(SystemShortcuts.parse(nil), with: margin).map(\.id) == [28, 29])
    }

    @Test func noToolbarConflictWhenRecordUsesOtherKeys() {
        let record = KeyCombo(keyCode: 0x0F, modifiers: KeyCombo.cmd | KeyCombo.option) // ⌥⌘R
        let margin = ShortcutAction.recordScreen.registeredCombos(for: record)
        #expect(SystemShortcuts.conflicts(SystemShortcuts.parse(nil), with: margin).isEmpty)
    }

    @Test func currentReadsWithoutCrashing() {
        let list = SystemShortcuts.current()
        #expect(list.map(\.id) == [28, 29, 30, 31, 184])
    }
}
