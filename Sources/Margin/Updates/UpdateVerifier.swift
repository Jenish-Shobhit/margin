import CryptoKit
import Foundation
import MarginKit
import Security

/// What a download must pass before it replaces Margin (spec §14.3). Everything here blocks: call it off the main thread.
///
/// 1. The zip is the size GitHub listed, with the SHA-256 GitHub recorded when it has one.
/// 2. `/usr/bin/ditto -x -k` unzips it, and `Margin.app` is at its top level (a folder, not a link).
/// 3. Its `Info.plist` has Margin's bundle ID and exactly the release's version.
/// 4. Its code signature is valid, as `codesign --verify --deep --strict` checks it: every architecture, nested code, strict
///    validation, no symbolic links out of the bundle.
/// 5. It satisfies the running copy's designated requirement: the same bundle ID signed by the same certificate, so the
///    Screen Recording permission (which macOS keys to that requirement) carries over. A copy that's signed ad hoc has a
///    requirement only it can meet (its own code hash), so it can't update itself.
enum UpdateVerifier {
    nonisolated static let bundleID = "io.github.jenish-shobhit.margin"

    /// `codesign --verify --deep --strict`, as Security framework flags.
    nonisolated private static var validityFlags: SecCSFlags {
        SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode)
                   | UInt32(kSecCSStrictValidate) | UInt32(kSecCSRestrictSymlinks))
    }

    // MARK: The zip

    nonisolated static func checkDownload(_ zip: URL, asset: GitHubRelease.Asset) throws {
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        guard asset.size <= 0 || size == asset.size else { throw UpdateError.incompleteDownload }
        guard let expected = asset.sha256 else { return }
        guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe) else { throw UpdateError.incompleteDownload }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksumMismatch }
    }

    /// Unzips `zip` into the empty folder `folder` and returns the `Margin.app` at its top level.
    nonisolated static func unzip(_ zip: URL, into folder: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        let errors = Pipe()
        ditto.standardError = errors
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardInput = FileHandle.nullDevice
        do {
            try ditto.run()
        } catch {
            throw UpdateError.unzip(error.localizedDescription)
        }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.unzip(text.isEmpty ? "ditto exited with status \(ditto.terminationStatus)" : text)
        }
        let app = folder.appendingPathComponent(UpdateInstall.appName)
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { throw UpdateError.noAppInDownload }
        return app
    }

    // MARK: The app

    nonisolated static func verify(_ app: URL, expectedVersion: String) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        try UpdateInstall.checkBundleInfo(info, bundleID: bundleID, expectedVersion: expectedVersion)

        var created: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &created)
        guard status == errSecSuccess, let code = created else { throw UpdateError.badSignature(describe(status, nil)) }
        var error: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, validityFlags, nil, &error)
        guard status == errSecSuccess else { throw UpdateError.badSignature(describe(status, error)) }

        let requirement = try runningRequirement()
        status = SecStaticCodeCheckValidityWithErrors(code, validityFlags, requirement, &error)
        if status == errSecCSReqFailed {
            _ = error?.takeRetainedValue()
            throw UpdateError.differentSigner
        }
        guard status == errSecSuccess else { throw UpdateError.badSignature(describe(status, error)) }
    }

    /// The running copy's designated requirement, as macOS checks it for its permissions. Throws
    /// `runningCopyUnsigned` when it isn't signed with a certificate.
    nonisolated static func runningRequirement() throws -> SecRequirement {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { throw UpdateError.runningCopyUnsigned }
        var onDisk: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &onDisk) == errSecSuccess, let onDisk else { throw UpdateError.runningCopyUnsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(onDisk, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty else { throw UpdateError.runningCopyUnsigned }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(onDisk, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.runningCopyUnsigned
        }
        return requirement
    }

    /// Whether this copy could check an update at all (signed with a certificate): asked before downloading.
    nonisolated static var runningCopyIsSigned: Bool { (try? runningRequirement()) != nil }

    nonisolated private static func describe(_ status: OSStatus, _ error: Unmanaged<CFError>?) -> String {
        // The status's own sentence ("a sealed resource is missing or invalid") says more than the error's description
        // ("The operation couldn't be completed. (OSStatus error -67054.)").
        let fromError = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String? ?? "" } ?? ""
        var text = SecCopyErrorMessageString(status, nil) as String? ?? ""
        if text.isEmpty || text.hasPrefix("OSStatus") { text = fromError.isEmpty ? "error \(status)" : fromError }
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }
}
