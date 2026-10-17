import Foundation
import MarginKit
import Testing

@Suite struct UpdateCheckTests {
    static let page = URL(string: "https://github.com/Jenish-Shobhit/margin/releases/tag/v0.0.20")!

    static func release(_ tag: String, assets: [String]? = nil, draft: Bool = false, prerelease: Bool = false,
                        body: String? = "## Notes") -> GitHubRelease {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let names = assets ?? ["Margin-\(version).zip"]
        return GitHubRelease(
            tagName: tag, name: "Margin \(version)", body: body, htmlURL: page, draft: draft, prerelease: prerelease,
            publishedAt: Date(timeIntervalSince1970: 1_792_000_000),
            assets: names.map {
                GitHubRelease.Asset(name: $0, downloadURL: URL(string: "https://github.com/x/\($0)")!, size: 2_000_000)
            })
    }

    static let current = SemanticVersion("0.0.19")!

    private func decide(_ release: GitHubRelease, current: SemanticVersion = current, skipped: String? = nil,
                        manual: Bool = false) throws -> UpdateDecision {
        try UpdateCheck.decide(release, current: current, skipped: skipped, manual: manual)
    }

    @Test func offersANewerRelease() throws {
        guard case .available(let update) = try decide(Self.release("v0.0.20")) else {
            Issue.record("not offered")
            return
        }
        #expect(update.version == SemanticVersion("0.0.20"))
        #expect(update.versionString == "0.0.20")
        #expect(update.asset.name == "Margin-0.0.20.zip")
        #expect(update.notes == "## Notes")
        #expect(update.releasePage == Self.page)
        #expect(update.publishedAt == Date(timeIntervalSince1970: 1_792_000_000))
    }

    @Test func numericOrderDecides() throws {
        #expect(try decide(Self.release("v0.0.10"), current: SemanticVersion("0.0.9")!) != .upToDate)
        #expect(try decide(Self.release("v0.1.0"), current: SemanticVersion("0.0.10")!) != .upToDate)
        #expect(try decide(Self.release("v0.0.9"), current: SemanticVersion("0.0.10")!) == .upToDate)
    }

    @Test func sameOrOlderIsUpToDate() throws {
        #expect(try decide(Self.release("v0.0.19")) == .upToDate)
        #expect(try decide(Self.release("0.0.19")) == .upToDate)
        // A build of main is ahead of the latest release (0.0.19 running, 0.0.15 published).
        #expect(try decide(Self.release("v0.0.15")) == .upToDate)
        #expect(try decide(Self.release("v0.0.15"), manual: true) == .upToDate)
    }

    @Test func draftsAndPreReleasesAreNeverOffered() throws {
        #expect(try decide(Self.release("v0.0.20", draft: true)) == .upToDate)
        #expect(try decide(Self.release("v0.0.20", prerelease: true)) == .upToDate)
        #expect(try decide(Self.release("v0.1.0-beta.1")) == .upToDate)
        #expect(try decide(Self.release("v0.1.0-beta.1"), manual: true) == .upToDate)
    }

    @Test func aPreReleaseCopyIsOfferedItsRelease() throws {
        let decision = try decide(Self.release("v0.1.0"), current: SemanticVersion("0.1.0-rc.2")!)
        guard case .available(let update) = decision else {
            Issue.record("not offered")
            return
        }
        #expect(update.versionString == "0.1.0")
    }

    @Test func aNewerReleaseWithoutItsZipIsAnError() throws {
        #expect(throws: UpdateError.noDownload("0.0.20")) { try decide(Self.release("v0.0.20", assets: [])) }
        #expect(throws: UpdateError.noDownload("0.0.20")) {
            try decide(Self.release("v0.0.20", assets: ["Margin-0.0.19.zip", "Source.zip"]))
        }
        // Not when it isn't newer: there's nothing to install anyway.
        #expect(try decide(Self.release("v0.0.18", assets: [])) == .upToDate)
    }

    @Test func aTagThatIsntAVersionIsAnError() {
        #expect(throws: UpdateError.unreadableVersion("nightly")) { try decide(Self.release("nightly")) }
    }

    // MARK: Skip This Version

    @Test func automaticChecksSkipTheSkippedVersion() throws {
        #expect(try decide(Self.release("v0.0.20"), skipped: "0.0.20") == .skipped("0.0.20"))
        #expect(try decide(Self.release("v0.0.20"), skipped: "v0.0.20") == .skipped("0.0.20"))
    }

    @Test func aManualCheckOffersTheSkippedVersion() throws {
        guard case .available = try decide(Self.release("v0.0.20"), skipped: "0.0.20", manual: true) else {
            Issue.record("a manual check should offer it")
            return
        }
    }

    @Test func aLaterVersionThanTheSkippedOneIsOffered() throws {
        guard case .available(let update) = try decide(Self.release("v0.0.21"), skipped: "0.0.20") else {
            Issue.record("0.0.21 should be offered")
            return
        }
        #expect(update.versionString == "0.0.21")
    }

    @Test func sameVersionMatching() {
        #expect(UpdateCheck.isSameVersion("0.0.20", "v0.0.20"))
        #expect(UpdateCheck.isSameVersion("0.1", "0.1.0"))
        #expect(!UpdateCheck.isSameVersion("0.0.20", "0.0.2"))
        #expect(UpdateCheck.isSameVersion("nightly", "nightly"))
        #expect(!UpdateCheck.isSameVersion("nightly", "0.0.20"))
    }

    // MARK: HTTP

    @Test func httpStatusErrors() {
        #expect(UpdateCheck.error(forStatus: 200, rateLimitRemaining: nil) == nil)
        #expect(UpdateCheck.error(forStatus: 404, rateLimitRemaining: "59") == .noRelease)
        #expect(UpdateCheck.error(forStatus: 403, rateLimitRemaining: "0") == .rateLimited)
        #expect(UpdateCheck.error(forStatus: 429, rateLimitRemaining: nil) == .rateLimited)
        #expect(UpdateCheck.error(forStatus: 403, rateLimitRemaining: "12") == .httpStatus(403))
        #expect(UpdateCheck.error(forStatus: 502, rateLimitRemaining: nil) == .httpStatus(502))
    }

    @Test func onlyGitHubsPublicAPI() {
        #expect(UpdateCheck.latestReleaseURL.absoluteString == "https://api.github.com/repos/Jenish-Shobhit/margin/releases/latest")
        #expect(UpdateCheck.releasesPage.absoluteString == "https://github.com/Jenish-Shobhit/margin/releases/latest")
    }

    @Test func everyErrorSaysSomething() {
        let all: [UpdateError] = [
            .offline("The Internet connection appears to be offline."), .httpStatus(500), .rateLimited, .noRelease,
            .unreadableAnswer, .unreadableVersion("x"), .noDownload("0.0.20"), .download("timed out"),
            .incompleteDownload, .checksumMismatch, .unzip("exit 1"), .noAppInDownload, .wrongBundle("com.example"),
            .wrongBundle(nil), .wrongVersion(found: "0.0.19", expected: "0.0.20"), .badSignature("invalid"),
            .differentSigner, .runningCopyUnsigned, .notAnApp, .translocated, .folderNotWritable("/Applications"),
            .helper("no /bin/sh"), .helperFailed(version: "0.0.20", detail: "couldn't move it"),
            .helperFailed(version: "0.0.20", detail: nil),
        ]
        for error in all {
            #expect(error.message.count > 20, "\(error)")
            #expect(error.message.hasSuffix("."), "\(error)")
        }
        // A system description keeps the sentence's punctuation single.
        #expect(UpdateError.offline("Could not connect to the server.").message
                == "Margin couldn’t reach GitHub (Could not connect to the server). Check your internet connection and try again.")
        #expect(UpdateError.download("The request timed out.").message == "The download failed (The request timed out).")
        #expect(UpdateError.helperFailed(version: "0.0.20", detail: "couldn't move it.").message
                == "Couldn't move it. There’s more in ~/Library/Logs/Margin/Update.log.")
        #expect(!UpdateError.rateLimited.isInstallError)
        #expect(UpdateError.differentSigner.isInstallError)
        #expect(UpdateError.folderNotWritable("/Applications").opensReleasesPage)
        #expect(UpdateError.folderNotWritable("/Applications").message.contains("/Applications"))
        #expect(!UpdateError.checksumMismatch.opensReleasesPage)
        #expect(UpdateError.noDownload("0.0.20").message.contains("Margin-0.0.20.zip"))
        #expect(UpdateError.helperFailed(version: "0.0.20", detail: "couldn't move it").message
                == "Couldn't move it. There’s more in ~/Library/Logs/Margin/Update.log.")
        #expect(UpdateError.helperFailed(version: "0.0.20", detail: nil).message
                == "The installer didn’t finish. There’s more in ~/Library/Logs/Margin/Update.log.")
    }
}

@Suite struct UpdateScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    @Test func neverCheckedIsDue() {
        #expect(UpdateSchedule.isDue(lastCheck: nil, now: now, atLaunch: true))
        #expect(UpdateSchedule.isDue(lastCheck: nil, now: now, atLaunch: false))
        #expect(UpdateSchedule.nextCheck(lastCheck: nil, now: now) == now)
    }

    @Test func everyTwentyFourHours() {
        #expect(!UpdateSchedule.isDue(lastCheck: now - 23 * hour, now: now, atLaunch: false))
        #expect(UpdateSchedule.isDue(lastCheck: now - 24 * hour, now: now, atLaunch: false))
        #expect(UpdateSchedule.isDue(lastCheck: now - 30 * 24 * hour, now: now, atLaunch: false))
        #expect(UpdateSchedule.nextCheck(lastCheck: now - 2 * hour, now: now) == now + 22 * hour)
        #expect(UpdateSchedule.nextCheck(lastCheck: now - 25 * hour, now: now) == now)
    }

    @Test func atLaunchUnlessARelaunch() {
        #expect(UpdateSchedule.isDue(lastCheck: now - 2 * hour, now: now, atLaunch: true))
        #expect(UpdateSchedule.isDue(lastCheck: now - hour, now: now, atLaunch: true))
        #expect(!UpdateSchedule.isDue(lastCheck: now - 59 * 60, now: now, atLaunch: true))
        #expect(!UpdateSchedule.isDue(lastCheck: now - 10, now: now, atLaunch: true))
    }

    @Test func aClockSetBackDoesntStopChecks() {
        #expect(!UpdateSchedule.isDue(lastCheck: now + 60, now: now, atLaunch: false))   // a little skew is fine
        #expect(UpdateSchedule.isDue(lastCheck: now + 48 * hour, now: now, atLaunch: false))
        #expect(UpdateSchedule.isDue(lastCheck: now + 48 * hour, now: now, atLaunch: true))
    }
}

@Suite struct MarginURLTests {
    @Test func updateRequests() {
        for s in ["margin://update", "MARGIN://Update", "margin://update/", "margin://update?install=1",
                  "margin://update/install#now", "margin:update"] {
            #expect(MarginURL.isUpdateRequest(URL(string: s)!), "\(s)")
        }
    }

    @Test func anythingElseIsIgnored() {
        for s in ["margin://", "margin://install", "margin://updates", "margin://capture/update", "https://update",
                  "file:///update", "margins://update", "margin:install"] {
            #expect(!MarginURL.isUpdateRequest(URL(string: s)!), "\(s)")
        }
    }
}

@Suite struct ReleaseNotesTests {
    @Test func theFixturesNotes() throws {
        let release = try GitHubRelease.decode(Data(releaseFixtureJSON.utf8))
        let blocks = ReleaseNotes.blocks(release.body ?? "")
        #expect(blocks.first == .heading(level: 2, text: "0.0.15 — 2026-10-15"))
        #expect(blocks.dropFirst().first == .heading(level: 3, text: "Fixed"))
        #expect(blocks.filter { if case .bullet = $0 { true } else { false } }.count == 3)
        #expect(blocks.contains(.heading(level: 3, text: "Changed")))
        // What release.sh adds for people downloading by hand isn't shown.
        #expect(!blocks.contains { if case .heading(_, let text) = $0 { text == "Install" } else { false } })
        #expect(!blocks.contains { block in
            switch block {
            case .paragraph(let t), .bullet(let t): t.contains("Generated with") || t.contains("Open Anyway")
            case .heading: false
            }
        })
        #expect(blocks.last == .bullet("Esc and Space are caught from the very start of ⇧⌘4, and the capture screen appears about 3 ms sooner."))
    }

    @Test func bulletsParagraphsAndWrappedLines() {
        let blocks = ReleaseNotes.blocks("""
            Intro line one
            continues here.

            - First
              wraps.
            * Second
            + Third

            # Top
            #### Deep
            Last.
            """)
        #expect(blocks == [
            .paragraph("Intro line one continues here."),
            .bullet("First wraps."),
            .bullet("Second"),
            .bullet("Third"),
            .heading(level: 2, text: "Top"),
            .heading(level: 4, text: "Deep"),
            .paragraph("Last."),
        ])
    }

    @Test func emptyNotes() {
        #expect(ReleaseNotes.blocks("").isEmpty)
        #expect(ReleaseNotes.blocks("\n\n  \n").isEmpty)
        #expect(ReleaseNotes.blocks("### Install\n\nDownload it.").isEmpty)
        #expect(ReleaseNotes.blocks("a\r\nb") == [.paragraph("a b")])
    }
}
