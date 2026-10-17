import Foundation
import MarginKit
import Testing

@Suite struct GitHubReleaseTests {
    /// The fixture's JSON with `change` applied to its top-level object.
    static func release(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> GitHubRelease {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(releaseFixtureJSON.utf8)) as? [String: Any])
        change(&object)
        return try GitHubRelease.decode(JSONSerialization.data(withJSONObject: object))
    }

    /// The fixture's asset, renamed and changed by `change`.
    static func asset(_ name: String, _ change: (inout [String: Any]) -> Void = { _ in }) throws -> [String: Any] {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(releaseFixtureJSON.utf8)) as? [String: Any])
        var asset = try #require((object["assets"] as? [[String: Any]])?.first)
        asset["name"] = name
        asset["browser_download_url"] = "https://github.com/Jenish-Shobhit/margin/releases/download/v0.0.15/\(name)"
        change(&asset)
        return asset
    }

    @Test func readsGitHubsAnswer() throws {
        let release = try GitHubRelease.decode(Data(releaseFixtureJSON.utf8))
        #expect(release.tagName == "v0.0.15")
        #expect(release.versionString == "0.0.15")
        #expect(release.version == SemanticVersion("0.0.15"))
        #expect(release.name == "Margin 0.0.15")
        #expect(release.htmlURL.absoluteString == "https://github.com/Jenish-Shobhit/margin/releases/tag/v0.0.15")
        #expect(!release.draft)
        #expect(!release.prerelease)
        #expect(release.publishedAt == ISO8601DateFormatter().date(from: "2026-10-15T04:00:55Z"))
        #expect(release.body?.hasPrefix("## 0.0.15 — 2026-10-15") == true)
        #expect(release.assets.count == 1)
        let asset = try #require(release.assets.first)
        #expect(asset.name == "Margin-0.0.15.zip")
        #expect(asset.size == 1_945_999)
        #expect(asset.state == "uploaded")
        #expect(asset.contentType == "application/zip")
        #expect(asset.downloadURL.absoluteString
                == "https://github.com/Jenish-Shobhit/margin/releases/download/v0.0.15/Margin-0.0.15.zip")
        #expect(asset.sha256 == "44b912c434e492dc22663146ae38838d47371f9b30b23d1f8ca591ad861bc226")
    }

    @Test func picksTheAppZipByItsExactName() throws {
        let release = try Self.release {
            $0["assets"] = [
                try! Self.asset("Margin-0.0.14.zip"),
                try! Self.asset("margin-0.0.15.zip"),
                try! Self.asset("Margin-0.0.15.zip.sha256"),
                try! Self.asset("Source code.zip"),
                try! Self.asset("Margin-0.0.15.zip"),
            ]
        }
        #expect(release.assets.count == 5)
        #expect(release.appAsset?.name == "Margin-0.0.15.zip")
        #expect(release.appAsset?.downloadURL.lastPathComponent == "Margin-0.0.15.zip")
        #expect(GitHubRelease.assetName(for: "0.0.20") == "Margin-0.0.20.zip")
    }

    @Test func noAppZipWithoutThatName() throws {
        let none = try Self.release { $0["assets"] = [try! Self.asset("Margin.zip"), try! Self.asset("Margin-0.0.16.zip")] }
        #expect(none.appAsset == nil)
        let empty = try Self.release { $0["assets"] = [] }
        #expect(empty.appAsset == nil)
        let missing = try Self.release { $0.removeValue(forKey: "assets") }
        #expect(missing.assets.isEmpty)
    }

    @Test func anUnfinishedUploadDoesntCount() throws {
        let release = try Self.release { $0["assets"] = [try! Self.asset("Margin-0.0.15.zip") { $0["state"] = "starter" }] }
        #expect(release.appAsset == nil)
    }

    @Test func anUnreadableAssetDoesntHideTheOthers() throws {
        let release = try Self.release {
            $0["assets"] = [["name": "broken"], try! Self.asset("Margin-0.0.15.zip")]
        }
        #expect(release.assets.map(\.name) == ["Margin-0.0.15.zip"])
        #expect(release.appAsset != nil)
    }

    @Test func checksumNeedsSHA256() throws {
        let url = URL(string: "https://example.com/Margin-1.0.0.zip")!
        #expect(GitHubRelease.Asset(name: "a", downloadURL: url, size: 1, digest: nil).sha256 == nil)
        #expect(GitHubRelease.Asset(name: "a", downloadURL: url, size: 1, digest: "md5:abc").sha256 == nil)
        #expect(GitHubRelease.Asset(name: "a", downloadURL: url, size: 1, digest: "sha256:1234").sha256 == nil)
        let hex = String(repeating: "AB", count: 32)
        #expect(GitHubRelease.Asset(name: "a", downloadURL: url, size: 1, digest: "SHA256:" + hex).sha256 == hex.lowercased())
    }

    @Test func toleratesNullsAndMissingFlags() throws {
        let release = try Self.release {
            $0["body"] = NSNull()
            $0["name"] = NSNull()
            $0["published_at"] = NSNull()
            $0.removeValue(forKey: "draft")
            $0.removeValue(forKey: "prerelease")
        }
        #expect(release.body == nil)
        #expect(release.name == nil)
        #expect(release.publishedAt == nil)
        #expect(!release.draft && !release.prerelease)
    }

    @Test func refusesWhatIsntARelease() {
        #expect(throws: (any Error).self) { try GitHubRelease.decode(Data("{\"message\": \"Not Found\"}".utf8)) }
        #expect(throws: (any Error).self) { try GitHubRelease.decode(Data("<html>".utf8)) }
        #expect(throws: (any Error).self) { try GitHubRelease.decode(Data()) }
    }

    @Test func tagWithoutV() throws {
        let release = try Self.release { $0["tag_name"] = "0.0.15" }
        #expect(release.versionString == "0.0.15")
        #expect(release.appAsset?.name == "Margin-0.0.15.zip")
    }
}
