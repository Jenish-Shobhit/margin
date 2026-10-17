import AppKit
import MarginKit
import Observation
import os

/// Updates from GitHub (spec §14.3): the checks, the update window's state, and installing a release.
///
/// - **Checks** ask GitHub's public API for the latest release, and nothing else: automatically (Settings "Check for
///   updates automatically", on) once the launch's prewarm is done and every 24 hours, never during a capture; and when
///   asked (Check for Updates…, `margin://update`). With the setting off and nothing asked, Margin makes no request.
/// - **The window** offers a newer release with its notes: Install and Relaunch, Later, Skip This Version. A check the
///   user asked for also says when Margin is up to date, and what went wrong.
/// - **Installing** downloads `Margin-<version>.zip`, unzips and checks it (`UpdateVerifier`), and hands the swap to a
///   detached helper (`UpdateInstall.helperScript`) that waits for Margin to quit. The next launch says how it went.
@MainActor @Observable
final class UpdateController {
    static let shared = UpdateController()
    nonisolated static let log = Logger(subsystem: AppCoordinator.subsystem, category: "updates")

    enum Phase: Equatable {
        case idle
        /// A check the user asked for is running.
        case checking
        /// A check the user asked for found nothing newer.
        case upToDate
        case available(AvailableUpdate)
        /// `fraction` is nil until the size is known.
        case downloading(AvailableUpdate, fraction: Double?, received: Int64, total: Int64)
        case verifying(AvailableUpdate)
        /// Verified: the helper is waiting for Margin to quit.
        case relaunching(AvailableUpdate)
        /// `update` is the release being installed, or nil when the check failed.
        case failed(UpdateError, update: AvailableUpdate?)

        var update: AvailableUpdate? {
            switch self {
            case .available(let u), .downloading(let u, _, _, _), .verifying(let u), .relaunching(let u): u
            case .failed(_, let u): u
            case .idle, .checking, .upToDate: nil
            }
        }

        var isInstalling: Bool {
            switch self {
            case .downloading, .verifying, .relaunching: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle

    nonisolated static var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    let currentVersion = SemanticVersion(UpdateController.currentVersionString) ?? SemanticVersion(major: 0, minor: 0, patch: 0)

    /// How long after the launch's prewarm the first automatic check waits, so it never competes with launch work.
    static let launchDelay: Duration = .seconds(3)
    /// How often the running app looks at whether a check is due (`UpdateSchedule`).
    static let pollInterval: TimeInterval = 60 * 60

    @ObservationIgnored let prefs = Preferences.shared
    @ObservationIgnored private var started = false
    /// A check was asked for (`margin://update` at launch) before `start`.
    @ObservationIgnored private var checkAskedBeforeStart = false
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    /// The running check shows its result: a manual check, or an automatic one the user asked for while it ran.
    @ObservationIgnored private var checkIsManual = false
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var staging: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastProgressUpdate = Date.distantPast
    /// True during a capture or a recording: an automatic check waits for it to end (its window would be in it).
    @ObservationIgnored private var isBusy: () -> Bool = { false }
    /// Shows a line in the shelf ("Updated to Margin 0.1.2").
    @ObservationIgnored private var showToast: (String) -> Void = { _ in }
    #if DEBUG || MARGIN_BENCH
    /// `scripts/debug.sh update-check <feed>`: a local release instead of GitHub's.
    @ObservationIgnored var debugFeed: URL?
    /// `update-trash <folder>`: where the helper puts the old copy (a folder it can't write tests its failure path).
    @ObservationIgnored var debugTrash: URL?
    /// `update-readonly on`: Install and Relaunch acts as if the app's folder couldn't be written.
    @ObservationIgnored var debugReadOnly = false
    /// What Open Releases Page would have opened, with a local feed (which never opens the browser).
    @ObservationIgnored private(set) var debugOpenedURL: URL?
    /// The last install's staging folder, to check it's gone afterwards (`update-state`).
    @ObservationIgnored private(set) var debugLastStaging: URL?
    /// With a local feed, a test is running on a Mac someone may be using: the window never takes the keyboard (Return
    /// would press its default button) and Open Releases Page opens nothing.
    private var isTesting: Bool { feedURL != UpdateCheck.latestReleaseURL }
    #else
    private var isTesting: Bool { false }
    #endif

    /// GitHub's API; in DEBUG and bench builds a local feed when one is set (the `update-check` debug command, or the
    /// `debugUpdateFeedURL` default).
    var feedURL: URL {
        #if DEBUG || MARGIN_BENCH
        if let debugFeed { return debugFeed }
        if let text = UserDefaults.standard.string(forKey: "debugUpdateFeedURL"), let url = URL(string: text) { return url }
        #endif
        return UpdateCheck.latestReleaseURL
    }

    // MARK: - Lifecycle

    /// Called once at launch, after everything else is wired: reports how an update installed before this launch went,
    /// runs a check `margin://update` asked for meanwhile, and starts the automatic checks once `prewarm` is done.
    func start(after prewarm: Task<Void, Never>?, isBusy: @escaping () -> Bool, showToast: @escaping (String) -> Void) {
        guard !started else { return }
        started = true
        self.isBusy = isBusy
        self.showToast = showToast
        reportInstalledUpdate()
        if checkAskedBeforeStart {
            checkAskedBeforeStart = false
            checkForUpdates()
        }
        Task(priority: .utility) { [weak self] in
            await prewarm?.value
            try? await Task.sleep(for: Self.launchDelay)
            self?.automaticCheck(atLaunch: true)
        }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.automaticCheck(atLaunch: false) }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Checking

    /// Check for Updates… and `margin://update`: checks now (skipped versions too) and shows the result.
    func checkForUpdates() {
        guard started else {
            checkAskedBeforeStart = true
            return
        }
        if phase.isInstalling {
            showWindow(activate: true)
            return
        }
        phase = .checking
        showWindow(activate: true)
        if checkTask != nil {
            checkIsManual = true // the automatic check already running answers this one
            return
        }
        runCheck(manual: true)
    }

    /// `application(_:open:)`. Returns false for a URL that isn't Margin's.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard MarginURL.isUpdateRequest(url) else {
            Self.log.notice("Ignoring the URL \(url.absoluteString, privacy: .public)")
            return false
        }
        Self.log.notice("margin://update: checking for updates")
        checkForUpdates()
        return true
    }

    /// At launch and every hour: checks when the setting is on and one is due, unless the update window is open (it shows
    /// something the user hasn't answered yet, a failed install's report among them) or a capture or recording is under way
    /// (then a minute later).
    private func automaticCheck(atLaunch: Bool) {
        guard prefs.checksForUpdates, checkTask == nil, installTask == nil,
              !UpdateWindowController.shared.isVisible, !phase.isInstalling else { return }
        guard UpdateSchedule.isDue(lastCheck: prefs.lastUpdateCheck, now: Date(), atLaunch: atLaunch) else { return }
        if isBusy() {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.automaticCheck(atLaunch: atLaunch)
            }
            return
        }
        runCheck(manual: false)
    }

    private func runCheck(manual: Bool) {
        checkIsManual = manual
        let feed = feedURL
        Self.log.notice("Checking for updates (\(manual ? "asked" : "automatic", privacy: .public))")
        checkTask = Task(priority: manual ? .userInitiated : .utility) { [weak self] in
            let result: Result<GitHubRelease, UpdateError>
            do {
                result = .success(try await UpdateNetwork.latestRelease(from: feed))
            } catch is CancellationError {
                return
            } catch let error as UpdateError {
                result = .failure(error)
            } catch {
                result = .failure(.offline(error.localizedDescription))
            }
            self?.checkFinished(result)
        }
    }

    private func checkFinished(_ result: Result<GitHubRelease, UpdateError>) {
        checkTask = nil
        let manual = checkIsManual
        checkIsManual = false
        // The window may have moved on meanwhile (Cancel, or an install started from an earlier answer).
        if manual, phase != .checking { return }
        if !manual, phase.isInstalling { return }
        let decision: UpdateDecision
        do {
            let release = try result.get()
            prefs.lastUpdateCheck = Date()
            decision = try UpdateCheck.decide(release, current: currentVersion, skipped: prefs.skippedUpdateVersion,
                                              manual: manual)
        } catch {
            let error = error as? UpdateError ?? .unreadableAnswer
            Self.log.error("Update check failed: \(error.message, privacy: .public)")
            if manual { phase = .failed(error, update: nil) }
            return
        }
        switch decision {
        case .available(let update):
            Self.log.notice("Margin \(update.versionString, privacy: .public) is available")
            phase = .available(update)
            if manual { showWindow(activate: true) } else { showOfferWhenIdle() }
        case .upToDate:
            Self.log.notice("Margin \(self.currentVersion.description, privacy: .public) is up to date")
            if manual { phase = .upToDate }
        case .skipped(let version):
            Self.log.notice("Margin \(version, privacy: .public) is available, but skipped")
        }
    }

    /// An automatic check's offer, once no capture or recording is under way: one may have started while it asked, and
    /// the window would be in it. Nothing, if the offer was answered meanwhile (a manual check, Later).
    private func showOfferWhenIdle() {
        guard case .available = phase else { return }
        guard !isBusy() else {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.showOfferWhenIdle()
            }
            return
        }
        showWindow(activate: false)
    }

    // MARK: - The window's buttons

    /// Install and Relaunch.
    func install() {
        guard installTask == nil, let update = phase.update else { return }
        let app = Bundle.main.bundleURL.standardizedFileURL
        do {
            try UpdateInstall.checkLocation(bundlePath: app.path)
            let folder = app.deletingLastPathComponent()
            let fm = FileManager.default
            var writable = fm.isWritableFile(atPath: folder.path) && fm.isWritableFile(atPath: app.path)
            #if DEBUG || MARGIN_BENCH
            if debugReadOnly { writable = false }
            #endif
            guard writable else { throw UpdateError.folderNotWritable(folder.path) }
            guard UpdateVerifier.runningCopyIsSigned else { throw UpdateError.runningCopyUnsigned }
        } catch {
            fail(error, update)
            return
        }
        Self.log.notice("Installing Margin \(update.versionString, privacy: .public) over \(app.path, privacy: .public)")
        phase = .downloading(update, fraction: nil, received: 0, total: Int64(update.asset.size))
        installTask = Task { [weak self] in await self?.runInstall(update, app: app) }
    }

    private func runInstall(_ update: AvailableUpdate, app: URL) async {
        do {
            // On the app's own volume, so the helper's last step is a rename.
            let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: app, create: true)
            self.staging = staging
            #if DEBUG || MARGIN_BENCH
            debugLastStaging = staging
            #endif
            let zip = staging.appendingPathComponent(update.asset.name)
            let expected = Int64(update.asset.size)
            let limit = UpdateInstall.downloadLimit(listedSize: update.asset.size)
            try await UpdateNetwork.download(update.asset.downloadURL, to: zip, limit: limit) { [weak self] received, total in
                Task { @MainActor in self?.downloaded(received, of: total > 0 ? total : expected) }
            }
            try Task.checkCancellation()
            phase = .verifying(update)
            let asset = update.asset, version = update.versionString
            let newApp = try await Task.detached(priority: .userInitiated) {
                try UpdateVerifier.checkDownload(zip, asset: asset)
                let app = try UpdateVerifier.unzip(zip, into: staging.appendingPathComponent("extracted", isDirectory: true))
                try UpdateVerifier.verify(app, expectedVersion: version)
                return app
            }.value
            try Task.checkCancellation()
            phase = .relaunching(update)
            // Accepted right after launch (the launch check's offer), the relaunch waits until Margin has run 30 s.
            let delay = UpdateInstall.relaunchDelay(launchedAt: NSRunningApplication.current.launchDate, now: Date())
            if delay > 0 {
                Self.log.notice("Relaunching in \(delay, format: .fixed(precision: 1)) s, 30 s after launch")
                try await Task.sleep(for: .seconds(delay))
            }
            try launchHelper(app: app, newApp: newApp, staging: staging)
            prefs.pendingUpdate = (update.versionString, Date())
            installTask = nil
            Self.log.notice("Margin \(update.versionString, privacy: .public) verified; quitting so the helper can install it")
            quit()
            // Quitting waits for saves (3 s) or a recording (15 s), never this long: still here, Margin didn't quit, and the helper has given up.
            try? await Task.sleep(for: .seconds(Double(UpdateInstall.quitWaitTenths) / 10 + 5))
            if case .relaunching = phase {
                prefs.pendingUpdate = nil
                fail(UpdateError.helperFailed(version: update.versionString, detail: "Margin didn’t quit"), update)
            }
        } catch is CancellationError {
            removeStaging()
            installTask = nil
            if phase.isInstalling { phase = .available(update) }
        } catch {
            removeStaging()
            installTask = nil
            fail(error, update)
        }
    }

    private func downloaded(_ received: Int64, of total: Int64) {
        guard case .downloading(let update, _, _, _) = phase else { return }
        // A few redraws a second is plenty.
        let now = Date()
        guard received >= total || now.timeIntervalSince(lastProgressUpdate) > 0.1 else { return }
        lastProgressUpdate = now
        let fraction = total > 0 ? min(1, Double(received) / Double(total)) : nil
        phase = .downloading(update, fraction: fraction, received: received, total: total)
    }

    /// Starts the detached helper (`/bin/sh`), which outlives Margin: it waits for this process to exit, puts the new app
    /// in place of `app` (the old one goes to the Trash), and opens it.
    private func launchHelper(app: URL, newApp: URL, staging: URL) throws {
        let fm = FileManager.default
        var trash: URL
        do {
            trash = try fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        } catch {
            trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        }
        #if DEBUG || MARGIN_BENCH
        if let debugTrash { trash = debugTrash }
        #endif
        let log = UpdateInstall.logFile
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = UpdateInstall.helperArguments(
            app: app, newApp: newApp, staging: staging, pid: ProcessInfo.processInfo.processIdentifier, trash: trash,
            trashName: UpdateInstall.trashName(oldVersion: Self.currentVersionString), log: log)
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            throw UpdateError.helper(error.localizedDescription)
        }
        self.staging = nil // the helper deletes it now
    }

    /// Later (and closing the window): stops a download, and the next automatic check offers it again.
    func later() {
        cancelInstall()
        phase = .idle
        UpdateWindowController.shared.close()
    }

    /// Skip This Version: automatic checks don't offer this version again.
    func skip() {
        if let update = phase.update {
            prefs.skippedUpdateVersion = update.versionString
            Self.log.notice("Skipping Margin \(update.versionString, privacy: .public)")
        }
        later()
    }

    /// Cancel, while checking or downloading.
    func cancel() {
        switch phase {
        case .checking:
            checkIsManual = false
            if checkTask != nil {
                checkTask?.cancel()
                checkTask = nil
            }
            phase = .idle
            UpdateWindowController.shared.close()
        case .downloading, .verifying:
            cancelInstall()
        default:
            later()
        }
    }

    /// The window closed (its close button, ⌘W): as Later, except once the helper is waiting.
    func windowClosed() {
        if case .relaunching = phase { return }
        if case .checking = phase { cancel(); return }
        cancelInstall()
        phase = .idle
    }

    private func cancelInstall() {
        if case .relaunching = phase { return }
        installTask?.cancel()
    }

    /// From the run loop, not from this main-actor task (a main-queue block): quitting may wait for saves, whose
    /// completions come through the main queue, which can't run again inside the block that's waiting.
    private func quit() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    func openReleasesPage() {
        let page = phase.update?.releasePage ?? UpdateCheck.releasesPage
        #if DEBUG || MARGIN_BENCH
        if isTesting {
            Self.log.notice("Open Releases Page (testing, not opened): \(page.absoluteString, privacy: .public)")
            debugOpenedURL = page
            return
        }
        #endif
        NSWorkspace.shared.open(page)
    }

    private func fail(_ error: any Error, _ update: AvailableUpdate?) {
        let error = error as? UpdateError ?? .download(error.localizedDescription)
        Self.log.error("Update failed: \(error.message, privacy: .public)")
        phase = .failed(error, update: update)
        showWindow(activate: true)
        // The way out is installing by hand.
        if error.opensReleasesPage { openReleasesPage() }
    }

    private func removeStaging() {
        guard let staging else { return }
        self.staging = nil
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staging) }
    }

    private func showWindow(activate: Bool) {
        UpdateWindowController.shared.show(activate: activate && !isTesting)
    }

    // MARK: - After the relaunch

    /// The launch after Install and Relaunch: "Updated to Margin X" on the shelf, or the window with what went wrong
    /// (the helper reopens the old copy when it couldn't install the new one).
    private func reportInstalledUpdate() {
        guard let pending = prefs.pendingUpdate else { return }
        prefs.pendingUpdate = nil
        // A day later it's old news (the helper never got to relaunch, and the user opened Margin themselves).
        guard Date().timeIntervalSince(pending.date) < 24 * 60 * 60 else { return }
        if UpdateCheck.isSameVersion(pending.version, Self.currentVersionString) {
            Self.log.notice("Updated to Margin \(pending.version, privacy: .public)")
            showToast("Updated to Margin \(pending.version)")
            return
        }
        let detail = (try? String(contentsOf: UpdateInstall.logFile, encoding: .utf8))
            .flatMap { UpdateInstall.lastFailure(inLog: $0, since: pending.date) }
        Self.log.error("Margin \(pending.version, privacy: .public) wasn't installed: \(detail ?? "no reason logged", privacy: .public)")
        phase = .failed(.helperFailed(version: pending.version, detail: detail), update: nil)
        showWindow(activate: true)
    }

    #if DEBUG || MARGIN_BENCH
    /// `update-check-auto`: an automatic check now, whatever the schedule says.
    func debugAutomaticCheck() {
        guard checkTask == nil else { return }
        runCheck(manual: false)
    }

    var debugState: [String: Any] {
        let name: String, message: Any
        switch phase {
        case .idle: (name, message) = ("idle", NSNull())
        case .checking: (name, message) = ("checking", NSNull())
        case .upToDate: (name, message) = ("upToDate", NSNull())
        case .available(let u): (name, message) = ("available \(u.versionString)", NSNull())
        case .downloading(let u, let f, let r, let t): (name, message) = ("downloading \(u.versionString)", "\(f ?? -1) \(r)/\(t)")
        case .verifying(let u): (name, message) = ("verifying \(u.versionString)", NSNull())
        case .relaunching(let u): (name, message) = ("relaunching \(u.versionString)", NSNull())
        case .failed(let e, let u): (name, message) = ("failed \(u?.versionString ?? "-")", e.message)
        }
        return [
            "phaseName": name,
            "message": message,
            "phase": "\(phase)",
            "checking": checkTask != nil,
            "installing": installTask != nil,
            "checksForUpdates": prefs.checksForUpdates,
            "skippedUpdateVersion": prefs.skippedUpdateVersion ?? NSNull(),
            "lastUpdateCheck": prefs.lastUpdateCheck.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "pendingUpdate": prefs.pendingUpdate?.version ?? NSNull(),
            "feed": feedURL.absoluteString,
            "currentVersion": Self.currentVersionString,
            "windowVisible": UpdateWindowController.shared.isVisible,
            "windowIsKey": UpdateWindowController.shared.isKey,
            "windowNumber": UpdateWindowController.shared.windowNumber ?? NSNull(),
            "openedURL": debugOpenedURL?.absoluteString ?? NSNull(),
            "lastStaging": debugLastStaging?.path ?? NSNull(),
            "lastStagingExists": debugLastStaging.map { FileManager.default.fileExists(atPath: $0.path) } ?? NSNull(),
            "trash": debugTrash?.path ?? NSNull(),
            "readOnly": debugReadOnly,
            "bundlePath": Bundle.main.bundlePath,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
    }
    #endif
}
