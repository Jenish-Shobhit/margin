import Foundation

/// The parts of GitHub's release JSON (`GET /repos/{owner}/{repo}/releases/latest`) the updater reads (spec §14.3).
/// Everything else in the answer (the author, upload URLs, counts) is ignored.
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let downloadURL: URL
        /// In bytes, as uploaded.
        public let size: Int
        public let contentType: String?
        /// `uploaded` once the upload has finished (GitHub lists unfinished uploads as `starter`).
        public let state: String?
        /// `sha256:<64 hex digits>` for assets uploaded since GitHub began recording it (June 2025).
        public let digest: String?

        public init(name: String, downloadURL: URL, size: Int, contentType: String? = "application/zip",
                    state: String? = "uploaded", digest: String? = nil) {
            self.name = name
            self.downloadURL = downloadURL
            self.size = size
            self.contentType = contentType
            self.state = state
            self.digest = digest
        }

        enum CodingKeys: String, CodingKey {
            case name, size, state, digest
            case downloadURL = "browser_download_url"
            case contentType = "content_type"
        }

        /// The SHA-256 GitHub recorded, as 64 lowercase hex digits; nil without one, or in another format.
        public var sha256: String? {
            guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
            let hex = digest.dropFirst("sha256:".count).lowercased()
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
            return String(hex)
        }
    }

    public let tagName: String
    public let name: String?
    /// The release notes, in GitHub's Markdown.
    public let body: String?
    /// The release's page on github.com.
    public let htmlURL: URL
    public let draft: Bool
    public let prerelease: Bool
    public let publishedAt: Date?
    public let assets: [Asset]

    public init(tagName: String, name: String? = nil, body: String? = nil, htmlURL: URL, draft: Bool = false,
                prerelease: Bool = false, publishedAt: Date? = nil, assets: [Asset]) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.draft = draft
        self.prerelease = prerelease
        self.publishedAt = publishedAt
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        htmlURL = try c.decode(URL.self, forKey: .htmlURL)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        // One asset that doesn't read (a field GitHub changed) doesn't hide the others.
        assets = try c.decodeIfPresent([LenientAsset].self, forKey: .assets)?.compactMap(\.asset) ?? []
    }

    private struct LenientAsset: Decodable {
        let asset: Asset?
        init(from decoder: any Decoder) throws { asset = try? Asset(from: decoder) }
    }

    /// Reads GitHub's JSON (ISO 8601 dates).
    public static func decode(_ data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    /// The tag without its `v`, as `scripts/release.sh` writes it into the asset's name: `v0.0.20` → `0.0.20`.
    public var versionString: String {
        let tag = tagName.trimmingCharacters(in: .whitespaces)
        return tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
    }

    /// The tag as a version; nil when it isn't one.
    public var version: SemanticVersion? { SemanticVersion(tagName) }

    /// The name of the zip the updater installs from: `Margin-0.0.20.zip` (`scripts/release.sh` names it so).
    public static func assetName(for versionString: String) -> String { "Margin-\(versionString).zip" }

    /// The release's app: the asset named `Margin-<version>.zip`, exactly, once its upload has finished. Nothing else
    /// counts (a source archive, another version's zip, a renamed file).
    public var appAsset: Asset? {
        let wanted = Self.assetName(for: versionString)
        return assets.first { $0.name == wanted && ($0.state == nil || $0.state == "uploaded") }
    }
}
