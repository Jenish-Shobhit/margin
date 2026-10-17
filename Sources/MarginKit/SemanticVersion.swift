import Foundation

/// A version number as releases are tagged (`v0.0.20`) and as `CFBundleShortVersionString` says it (`0.0.20`), ordered
/// as semantic versions are (spec §14.3): numerically, so 0.0.9 < 0.0.10 < 0.1.0.
///
/// - A leading `v` (or `V`) and surrounding whitespace are ignored, and so is build metadata (`+…`).
/// - One to three numeric components; missing ones are 0, so `1.2` is `1.2.0`.
/// - A pre-release (`1.0.0-beta.2`) comes before its release, and pre-releases order by their dot-separated parts:
///   numbers numerically, words alphabetically, a number before a word, and fewer parts first (semver.org, rule 11).
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The pre-release's dot-separated parts (`["beta", "2"]`); empty for a release.
    public let preRelease: [String]

    public init(major: Int, minor: Int, patch: Int, preRelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    /// Nil for anything that isn't a version: an empty string, words, a negative or fourth component, an empty part.
    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            let tail = s[s.index(after: dash)...]
            pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy(Self.isIdentifierCharacter) }) else { return nil }
            s = s[..<dash]
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], preRelease: pre)
    }

    public var isPreRelease: Bool { !preRelease.isEmpty }

    /// `0.0.20`, or `1.0.0-beta.2`.
    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return preRelease.isEmpty ? core : core + "-" + preRelease.joined(separator: ".")
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.preRelease.isEmpty, b.preRelease.isEmpty) {
        case (true, _): return false          // a release is never before anything with its numbers
        case (false, true): return true       // a pre-release is before its release
        case (false, false): return preReleaseIsBefore(a.preRelease, b.preRelease)
        }
    }

    private static func preReleaseIsBefore(_ a: [String], _ b: [String]) -> Bool {
        for (x, y) in zip(a, b) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true       // a number comes before a word
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.count < b.count
    }

    private static func isIdentifierCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-")
    }
}
