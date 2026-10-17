import Foundation
import MarginKit
import Testing

@Suite struct UpdateInstallTests {
    static let bundleID = "io.github.jenish-shobhit.margin"

    // MARK: The new bundle's Info.plist

    @Test func acceptsMarginAtTheExpectedVersion() throws {
        try UpdateInstall.checkBundleInfo(
            ["CFBundleIdentifier": Self.bundleID, "CFBundleShortVersionString": "0.0.20"],
            bundleID: Self.bundleID, expectedVersion: "0.0.20")
    }

    @Test func refusesAnotherApp() {
        #expect(throws: UpdateError.wrongBundle("com.example.other")) {
            try UpdateInstall.checkBundleInfo(
                ["CFBundleIdentifier": "com.example.other", "CFBundleShortVersionString": "0.0.20"],
                bundleID: Self.bundleID, expectedVersion: "0.0.20")
        }
        #expect(throws: UpdateError.wrongBundle(nil)) {
            try UpdateInstall.checkBundleInfo(nil, bundleID: Self.bundleID, expectedVersion: "0.0.20")
        }
    }

    @Test func refusesAnotherVersion() {
        for found in ["0.0.19", "0.0.21", "0.0.20-beta", "garbage"] {
            #expect(throws: UpdateError.wrongVersion(found: found, expected: "0.0.20")) {
                try UpdateInstall.checkBundleInfo(
                    ["CFBundleIdentifier": Self.bundleID, "CFBundleShortVersionString": found],
                    bundleID: Self.bundleID, expectedVersion: "0.0.20")
            }
        }
        #expect(throws: UpdateError.wrongVersion(found: nil, expected: "0.0.20")) {
            try UpdateInstall.checkBundleInfo(["CFBundleIdentifier": Self.bundleID], bundleID: Self.bundleID,
                                              expectedVersion: "0.0.20")
        }
    }

    // MARK: Where the running copy is

    @Test func locations() throws {
        try UpdateInstall.checkLocation(bundlePath: "/Applications/Margin.app")
        try UpdateInstall.checkLocation(bundlePath: "/Users/me/Applications/Margin.app")
        #expect(throws: UpdateError.notAnApp) {
            try UpdateInstall.checkLocation(bundlePath: "/Users/me/margin/.build/debug")
        }
        #expect(throws: UpdateError.translocated) {
            try UpdateInstall.checkLocation(
                bundlePath: "/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/Margin.app")
        }
    }

    @Test func downloadLimits() {
        #expect(UpdateInstall.downloadLimit(listedSize: 1_945_999) == 1_945_999)   // GitHub's size is exact
        #expect(UpdateInstall.downloadLimit(listedSize: 0) == 512 * 1024 * 1024)   // none listed: still bounded
        #expect(UpdateInstall.downloadLimit(listedSize: -1) == 512 * 1024 * 1024)
    }

    @Test func aRelaunchWaitsOutTheFirstHalfMinute() {
        let launch = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(UpdateInstall.relaunchDelay(launchedAt: launch, now: launch.addingTimeInterval(4)) == 26)
        #expect(UpdateInstall.relaunchDelay(launchedAt: launch, now: launch.addingTimeInterval(30)) == 0)
        #expect(UpdateInstall.relaunchDelay(launchedAt: launch, now: launch.addingTimeInterval(3600)) == 0)
        // A clock set back never waits longer than the half minute; an unknown launch doesn't wait.
        #expect(UpdateInstall.relaunchDelay(launchedAt: launch, now: launch.addingTimeInterval(-50)) == 30)
        #expect(UpdateInstall.relaunchDelay(launchedAt: nil, now: launch) == 0)
    }

    @Test func trashNames() {
        #expect(UpdateInstall.trashName(oldVersion: "0.0.19") == "Margin 0.0.19")
        #expect(UpdateInstall.trashName(oldVersion: "1/2:3") == "Margin 1-2-3")
    }

    // MARK: The helper

    /// A fake install: an old and a new "Margin.app" (folders with a marker file), a Trash folder, a log, and an `open`
    /// that only records what it was asked to open.
    struct Stage {
        let dir: TempDir
        let app: URL, staging: URL, newApp: URL, trash: URL, log: URL, opened: URL, open: URL

        init() throws {
            dir = try TempDir()
            let root = dir.url
            app = root.appendingPathComponent("Applications/Margin.app")
            staging = root.appendingPathComponent("staging")
            newApp = staging.appendingPathComponent("extracted/Margin.app")
            trash = root.appendingPathComponent("Trash")
            log = root.appendingPathComponent("Logs/Update.log")
            opened = root.appendingPathComponent("opened.txt")
            open = root.appendingPathComponent("open.sh")
            let fm = FileManager.default
            for folder in [app, newApp, trash, log.deletingLastPathComponent()] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data("old".utf8).write(to: app.appendingPathComponent("version"))
            try Data("new".utf8).write(to: newApp.appendingPathComponent("version"))
            try Data("zip".utf8).write(to: staging.appendingPathComponent("Margin-0.0.20.zip"))
            try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(opened.path)\"\n".utf8).write(to: open)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        }

        func version(at url: URL) -> String? {
            (try? String(contentsOf: url.appendingPathComponent("version"), encoding: .utf8))
        }

        var openedPaths: [String] {
            ((try? String(contentsOf: opened, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        var logText: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

        var trashed: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted()
        }

        /// Runs the helper to the end. `pid` is the process it waits for (by default one that has already exited).
        @discardableResult
        func run(pid: Int32? = nil, waitTenths: Int = 30, newApp: URL? = nil) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = UpdateInstall.helperArguments(
                app: app, newApp: newApp ?? self.newApp, staging: staging, pid: try pid ?? Self.exitedPID(),
                trash: trash, trashName: "Margin 0.0.19", log: log, open: open.path, quitWaitTenths: waitTenths)
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        /// The pid of a process that has run and exited.
        static func exitedPID() throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try p.run()
            p.waitUntilExit()
            return p.processIdentifier
        }
    }

    @Test func replacesTheAppAndTrashesTheOldOne() throws {
        let stage = try Stage()
        defer { stage.dir.remove() }
        #expect(try stage.run() == 0)
        #expect(stage.version(at: stage.app) == "new")
        #expect(stage.trashed == ["Margin 0.0.19.app"])
        #expect(stage.version(at: stage.trash.appendingPathComponent("Margin 0.0.19.app")) == "old")
        #expect(stage.openedPaths == ["-g " + stage.app.path])
        #expect(!FileManager.default.fileExists(atPath: stage.staging.path))   // the zip and what's left go
        #expect(stage.logText.contains("Installed \(stage.app.path)"))
        #expect(stage.logText.contains("as Margin 0.0.19.app"))
        #expect(!stage.logText.contains("FAILED"))
    }

    @Test func aNameTakenInTheTrashGetsANumber() throws {
        let stage = try Stage()
        defer { stage.dir.remove() }
        let fm = FileManager.default
        try fm.createDirectory(at: stage.trash.appendingPathComponent("Margin 0.0.19.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stage.trash.appendingPathComponent("Margin 0.0.19 2.app"), withIntermediateDirectories: true)
        #expect(try stage.run() == 0)
        #expect(stage.trashed == ["Margin 0.0.19 2.app", "Margin 0.0.19 3.app", "Margin 0.0.19.app"])
        #expect(stage.version(at: stage.trash.appendingPathComponent("Margin 0.0.19 3.app")) == "old")
        #expect(stage.version(at: stage.app) == "new")
    }

    @Test func waitsForMarginToQuit() throws {
        let stage = try Stage()
        defer { stage.dir.remove() }
        let margin = Process()
        margin.executableURL = URL(fileURLWithPath: "/bin/sleep")
        margin.arguments = ["0.6"]
        try margin.run()
        let start = Date()
        #expect(try stage.run(pid: margin.processIdentifier, waitTenths: 50) == 0)
        #expect(Date().timeIntervalSince(start) >= 0.5)
        #expect(stage.version(at: stage.app) == "new")
    }

    @Test func changesNothingIfMarginDoesntQuit() throws {
        let stage = try Stage()
        defer { stage.dir.remove() }
        let margin = Process()
        margin.executableURL = URL(fileURLWithPath: "/bin/sleep")
        margin.arguments = ["10"]
        try margin.run()
        defer { margin.terminate() }
        #expect(try stage.run(pid: margin.processIdentifier, waitTenths: 3) == 1)
        #expect(stage.version(at: stage.app) == "old")
        #expect(stage.trashed.isEmpty)
        #expect(stage.openedPaths.isEmpty)   // it's still running: nothing to open
        #expect(!FileManager.default.fileExists(atPath: stage.staging.path))
        #expect(stage.logText.contains("FAILED: Margin didn't quit"))
    }

    @Test func aMissingNewAppReopensTheOldOne() throws {
        let stage = try Stage()
        defer { stage.dir.remove() }
        #expect(try stage.run(newApp: stage.staging.appendingPathComponent("nothing/Margin.app")) == 1)
        #expect(stage.version(at: stage.app) == "old")
        #expect(stage.trashed.isEmpty)
        #expect(stage.openedPaths == ["-g " + stage.app.path])
        #expect(stage.logText.contains("FAILED: the new app is missing"))
    }

    @Test func anOldAppThatCantMoveStays() throws {
        let stage = try Stage()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stage.app.deletingLastPathComponent().path)
            stage.dir.remove()
        }
        // Its folder can't be written (as /Applications for a standard user).
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stage.app.deletingLastPathComponent().path)
        #expect(try stage.run() == 1)
        #expect(stage.version(at: stage.app) == "old")
        #expect(stage.trashed.isEmpty)
        #expect(stage.openedPaths == ["-g " + stage.app.path])
        #expect(stage.logText.contains("FAILED: couldn't move"))
    }

    @Test func pathsWithSpacesAndQuotes() throws {
        let stage = try Stage()
        defer { stage.dir.remove() }
        let odd = stage.dir.url.appendingPathComponent("My \"Apps\" $HOME `x`/Margin.app")
        try FileManager.default.createDirectory(at: odd.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: stage.app, to: odd)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = UpdateInstall.helperArguments(
            app: odd, newApp: stage.newApp, staging: stage.staging, pid: try Stage.exitedPID(), trash: stage.trash,
            trashName: "Margin 0.0.19", log: stage.log, open: stage.open.path, quitWaitTenths: 10)
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(stage.version(at: odd) == "new")
        #expect(stage.openedPaths == ["-g " + odd.path])
    }

    // MARK: The log, after a relaunch

    @Test func lastFailureSinceTheInstall() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let before = formatter.string(from: started - 3600), during = formatter.string(from: started + 2)
        let log = """
            \(before)  FAILED: an older failure
            \(during)  Waiting for Margin (pid 42) to quit
            \(during)  FAILED: couldn't move /Applications/Margin.app to the Trash, so nothing was changed
            """
        #expect(UpdateInstall.lastFailure(inLog: log, since: started)
                == "couldn't move /Applications/Margin.app to the Trash, so nothing was changed")
        let fine = """
            \(before)  FAILED: an older failure
            \(during)  Installed /Applications/Margin.app; the previous copy is in the Trash as Margin 0.0.19.app
            """
        #expect(UpdateInstall.lastFailure(inLog: fine, since: started) == nil)
        #expect(UpdateInstall.lastFailure(inLog: "", since: started) == nil)
        #expect(UpdateInstall.lastFailure(inLog: "garbage\nFAILED: x", since: started) == nil)
    }

    @Test func logLivesInLibraryLogs() {
        #expect(UpdateInstall.logFile.path.hasSuffix("/Library/Logs/Margin/Update.log"))
    }
}

/// The update bookkeeping in `Preferences`, on a throwaway suite.
@MainActor @Suite final class UpdatePreferencesTests {
    let suite = "io.github.jenish-shobhit.margin.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let prefs: Preferences

    init() {
        defaults = UserDefaults(suiteName: suite)!
        prefs = Preferences(defaults: defaults)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    @Test func startingValues() {
        #expect(prefs.checksForUpdates == true)
        #expect(prefs.skippedUpdateVersion == nil)
        #expect(prefs.lastUpdateCheck == nil)
        #expect(prefs.pendingUpdate == nil)
    }

    @Test func roundTrips() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        prefs.checksForUpdates = false
        prefs.skippedUpdateVersion = "0.0.20"
        prefs.lastUpdateCheck = date
        prefs.pendingUpdate = ("0.0.21", date)
        let again = Preferences(defaults: defaults)
        #expect(again.checksForUpdates == false)
        #expect(again.skippedUpdateVersion == "0.0.20")
        #expect(again.lastUpdateCheck == date)
        #expect(again.pendingUpdate?.version == "0.0.21")
        #expect(again.pendingUpdate?.date == date)
        again.pendingUpdate = nil
        again.skippedUpdateVersion = nil
        #expect(prefs.pendingUpdate == nil)
        #expect(prefs.skippedUpdateVersion == nil)
        #expect(defaults.object(forKey: "pendingUpdateDate") == nil)
    }

    @Test func theToggleIsASettingChange() {
        let counter = NotificationCounter(Preferences.didChange, object: prefs)
        prefs.checksForUpdates = false
        #expect(counter.count == 1)
    }
}
