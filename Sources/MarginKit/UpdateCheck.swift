import Foundation

/// A newer release the updater can install (spec §14.3).
public struct AvailableUpdate: Equatable, Sendable {
    public let version: SemanticVersion
    /// As in the tag, without its `v`: what the asset's name and the new app's `CFBundleShortVersionString` say.
    public let versionString: String
    /// `Margin-<version>.zip`.
    public let asset: GitHubRelease.Asset
    /// The release notes, Markdown as GitHub has them.
    public let notes: String
    public let releasePage: URL
    public let publishedAt: Date?

    public init(version: SemanticVersion, versionString: String, asset: GitHubRelease.Asset, notes: String,
                releasePage: URL, publishedAt: Date?) {
        self.version = version
        self.versionString = versionString
        self.asset = asset
        self.notes = notes
        self.releasePage = releasePage
        self.publishedAt = publishedAt
    }
}

/// What a check found.
public enum UpdateDecision: Equatable, Sendable {
    /// A newer release, with its zip: the update window offers it.
    case available(AvailableUpdate)
    /// Nothing newer than the running version (a manual check says "Margin Y is up to date.").
    case upToDate
    /// An automatic check found the version the user chose Skip This Version for. A manual check still offers it.
    case skipped(String)
}

public enum UpdateCheck {
    /// The only thing a check asks for: GitHub's public API, with no account and nothing about the user.
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/Jenish-Shobhit/margin/releases/latest")!
    /// Where "Open Releases Page" goes when the release's own page isn't known.
    public static let releasesPage = URL(string: "https://github.com/Jenish-Shobhit/margin/releases/latest")!

    /// Compares the latest release with the running version.
    /// - Only a release (no draft, nothing GitHub or its tag marks as a pre-release) that's newer than `current` is
    ///   offered. A copy newer than the latest release (a build of `main`) is up to date.
    /// - An automatic check (`manual` false) doesn't offer the version in `skipped`; a later version is offered again.
    /// - Throws `UpdateError.unreadableVersion` for a tag that isn't a version, `.noDownload` for a newer release without
    ///   its `Margin-<version>.zip`.
    public static func decide(_ release: GitHubRelease, current: SemanticVersion, skipped: String?,
                              manual: Bool) throws -> UpdateDecision {
        if release.draft || release.prerelease { return .upToDate }
        guard let latest = release.version else { throw UpdateError.unreadableVersion(release.tagName) }
        guard !latest.isPreRelease, latest > current else { return .upToDate }
        guard let asset = release.appAsset else { throw UpdateError.noDownload(release.versionString) }
        if !manual, let skipped, isSameVersion(skipped, release.versionString) { return .skipped(release.versionString) }
        return .available(AvailableUpdate(
            version: latest, versionString: release.versionString, asset: asset, notes: release.body ?? "",
            releasePage: release.htmlURL, publishedAt: release.publishedAt))
    }

    /// `0.0.20` and `v0.0.20` are the same version; strings that aren't versions match only themselves.
    public static func isSameVersion(_ a: String, _ b: String) -> Bool {
        if let x = SemanticVersion(a), let y = SemanticVersion(b) { return x == y }
        return a == b
    }

    /// An error for GitHub's HTTP status (200 isn't one). 403 and 429 are its rate limit for unauthenticated calls (60
    /// an hour per address) when `remaining` (`X-RateLimit-Remaining`) is 0 or missing on a 429.
    public static func error(forStatus status: Int, rateLimitRemaining remaining: String?) -> UpdateError? {
        switch status {
        case 200..<300: return nil
        case 404: return .noRelease
        case 429: return .rateLimited
        case 403 where remaining == "0": return .rateLimited
        default: return .httpStatus(status)
        }
    }
}

/// When automatic checks run (spec §14.3): at launch, once the first capture is ready, and every 24 hours while Margin
/// runs. A launch within an hour of the last check (a relaunch, an update) doesn't check again.
public enum UpdateSchedule {
    public static let interval: TimeInterval = 24 * 60 * 60
    public static let relaunchGrace: TimeInterval = 60 * 60
    /// How far in the future a last check may be before it counts as wrong (the clock was set back).
    static let clockSlack: TimeInterval = 5 * 60

    public static func isDue(lastCheck: Date?, now: Date, atLaunch: Bool) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        if elapsed < -clockSlack { return true }
        return elapsed >= (atLaunch ? relaunchGrace : interval)
    }

    /// When the next automatic check is due while running: 24 hours after the last one, or now.
    public static func nextCheck(lastCheck: Date?, now: Date) -> Date {
        guard let lastCheck, isDue(lastCheck: lastCheck, now: now, atLaunch: false) == false else { return now }
        return lastCheck.addingTimeInterval(interval)
    }
}

/// `margin://update` (spec §14.3): opened from the website's Update Margin button. It runs a check and shows the result;
/// nothing is installed without a click in Margin's window. Its path and query are never read.
public enum MarginURL {
    public static let scheme = "margin"

    public static func isUpdateRequest(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme else { return false }
        if let host = url.host(percentEncoded: false), !host.isEmpty { return host.lowercased() == "update" }
        // `margin:update`, with no slashes.
        return url.path(percentEncoded: false).lowercased() == "update"
    }
}

/// Everything that stops a check or an install, with the sentence the update window shows.
public enum UpdateError: Error, Equatable, Sendable {
    case offline(String)
    case httpStatus(Int)
    case rateLimited
    case noRelease
    case unreadableAnswer
    case unreadableVersion(String)
    case noDownload(String)
    case download(String)
    case incompleteDownload
    case checksumMismatch
    case unzip(String)
    case noAppInDownload
    case wrongBundle(String?)
    case wrongVersion(found: String?, expected: String)
    case badSignature(String)
    case differentSigner
    case runningCopyUnsigned
    case notAnApp
    case translocated
    case folderNotWritable(String)
    case helper(String)
    /// The helper ran but didn't install `version` (found at the next launch): what it logged, if anything.
    case helperFailed(version: String, detail: String?)

    /// True for the install's errors, false for the check's: the window's title says which went wrong.
    public var isInstallError: Bool {
        switch self {
        case .offline, .httpStatus, .rateLimited, .noRelease, .unreadableAnswer, .unreadableVersion, .noDownload: false
        default: true
        }
    }

    /// True when installing it by hand from the releases page is the way out (and the window says so).
    public var opensReleasesPage: Bool {
        switch self {
        case .folderNotWritable, .runningCopyUnsigned, .notAnApp, .translocated: true
        default: false
        }
    }

    /// A description from the system or the helper, in the message's own sentence: without its full stop, so
    /// "(Could not connect to the server.)." reads "(Could not connect to the server).".
    static func clause(_ detail: String) -> String {
        var text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    public var message: String {
        switch self {
        case .offline(let detail):
            "Margin couldn’t reach GitHub (\(Self.clause(detail))). Check your internet connection and try again."
        case .httpStatus(let status):
            "GitHub answered with an error (HTTP \(status)). Try again later."
        case .rateLimited:
            "GitHub has had too many update checks from your network for now. Try again in an hour."
        case .noRelease:
            "GitHub has no published release of Margin."
        case .unreadableAnswer:
            "GitHub’s answer couldn’t be read."
        case .unreadableVersion(let tag):
            "The latest release, “\(tag)”, doesn’t have a version number Margin understands."
        case .noDownload(let version):
            "Margin \(version) has no \(GitHubRelease.assetName(for: version)) to download yet."
        case .download(let detail):
            "The download failed (\(Self.clause(detail)))."
        case .incompleteDownload:
            "The download is incomplete. Try again."
        case .checksumMismatch:
            "The download doesn’t match the file on GitHub: it may have been damaged on the way. Try again."
        case .unzip(let detail):
            "The download couldn’t be unzipped (\(Self.clause(detail)))."
        case .noAppInDownload:
            "The download doesn’t contain Margin.app."
        case .wrongBundle(let id):
            "The downloaded app isn’t Margin (its bundle ID is “\(id ?? "missing")”), so it wasn’t installed."
        case .wrongVersion(let found, let expected):
            "The downloaded app is version \(found ?? "unknown"), not \(expected), so it wasn’t installed."
        case .badSignature(let detail):
            "The downloaded app’s code signature isn’t valid (\(Self.clause(detail))), so it wasn’t installed."
        case .differentSigner:
            "The downloaded app isn’t signed with the same certificate as this copy of Margin, so it wasn’t installed."
        case .runningCopyUnsigned:
            "This copy of Margin isn’t signed with a certificate (it was built and signed ad hoc), so the download can’t be checked against it. Install the new version from the releases page instead."
        case .notAnApp:
            "This copy of Margin isn’t an app bundle, so it can’t replace itself. Install the new version from the releases page instead."
        case .translocated:
            "macOS is running Margin from a temporary, read-only copy. Move Margin.app to your Applications folder, open it from there and try again, or install the new version from the releases page."
        case .folderNotWritable(let folder):
            "Margin can’t replace itself: you don’t have permission to change “\(folder)”. Install the new version from the releases page, or ask an administrator."
        case .helper(let detail):
            "The installer couldn’t start (\(Self.clause(detail)))."
        case .helperFailed(_, let detail):
            // Under the window's title, "Margin X wasn't installed.": what the helper logged, as a sentence.
            "\(detail.map(Self.clause).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "The installer didn’t finish"). There’s more in ~/Library/Logs/Margin/Update.log."
        }
    }
}

/// The release notes as a few kinds of lines, for the update window: GitHub's Markdown (spec §14.3, "a simple markdown
/// rendering"). Inline styling (bold, `code`, links) is left in the text for `AttributedString(markdown:)`.
public enum ReleaseNotes {
    public enum Block: Equatable, Sendable {
        /// `##` (level 2) or `###` (level 3) and deeper.
        case heading(level: Int, text: String)
        case bullet(String)
        case paragraph(String)
    }

    /// The blocks of `markdown`, without what `scripts/release.sh` adds for people downloading by hand: the `### Install`
    /// section and everything after it, and the "Generated with" line.
    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var open: (bullet: Bool, text: String)?
        func close() {
            if let open { blocks.append(open.bullet ? .bullet(open.text) : .paragraph(open.text)) }
            open = nil
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                close()
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                close()
                if text.lowercased() == "install" { break }
                if !text.isEmpty { blocks.append(.heading(level: max(level, 2), text: text)) }
                continue
            }
            if line.hasPrefix("🤖") { close(); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                close()
                open = (true, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            // A line that wraps the one before (in a bullet or a paragraph) joins it.
            if let current = open {
                open = (current.bullet, current.text + " " + line)
            } else {
                open = (false, line)
            }
        }
        close()
        return blocks
    }
}
