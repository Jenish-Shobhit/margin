import MarginKit
import Testing

@Suite struct SemanticVersionTests {
    private func v(_ s: String) -> SemanticVersion {
        guard let version = SemanticVersion(s) else {
            Issue.record("\(s) didn't parse")
            return SemanticVersion(major: -1, minor: 0, patch: 0)
        }
        return version
    }

    @Test func comparesNumericallyNotAsText() {
        #expect(v("0.0.9") < v("0.0.10"))
        #expect(v("0.0.10") < v("0.1.0"))
        #expect(v("0.1.0") < v("1.0.0"))
        #expect(v("0.0.19") < v("0.0.20"))
        #expect(v("0.9.99") < v("0.10.0"))
        #expect(!(v("0.0.20") < v("0.0.20")))
        #expect(v("2.0.0") > v("1.99.99"))
    }

    @Test func tagsWithAndWithoutV() {
        #expect(v("v0.0.20") == v("0.0.20"))
        #expect(v("V1.2.3") == v("1.2.3"))
        #expect(v(" v0.0.20\n") == v("0.0.20"))
        #expect(v("v0.0.15") < v("0.0.19"))
        #expect(v("v0.0.20").description == "0.0.20")
    }

    @Test func missingComponentsAreZero() {
        #expect(v("1") == v("1.0.0"))
        #expect(v("1.2") == v("1.2.0"))
        #expect(v("1.2").description == "1.2.0")
    }

    @Test func preReleasesComeBeforeTheirRelease() {
        #expect(v("1.0.0-beta") < v("1.0.0"))
        #expect(v("0.1.0-rc.1") < v("0.1.0"))
        #expect(v("0.0.19") < v("0.1.0-beta.1"))   // still after every earlier release
        #expect(v("1.0.0-beta").isPreRelease)
        #expect(!v("1.0.0").isPreRelease)
        #expect(v("1.0.0-beta.2").description == "1.0.0-beta.2")
    }

    /// semver.org's own example: 1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0-beta.2 <
    /// 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0.
    @Test func preReleasesOrderAsSemverSays() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"].map(v)
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            #expect(a < b, "\(a) < \(b)")
            #expect(!(b < a), "not \(b) < \(a)")
        }
        #expect(ordered.shuffled().sorted() == ordered)
    }

    @Test func buildMetadataIsIgnored() {
        #expect(v("1.2.3+build.7") == v("1.2.3"))
        #expect(v("1.2.3-beta+exp.sha.5114f85") == v("1.2.3-beta"))
    }

    @Test func rejectsWhatIsntAVersion() {
        for s in ["", "v", "latest", "1.2.3.4", "1..2", "1.2.", ".1", "-1.0.0", "1.0.0-", "1.0.0-beta..1", "1.x.0",
                  "1.0.0-be ta", "١.٢.٣", "1234567890.0.0"] {
            #expect(SemanticVersion(s) == nil, "\(s)")
        }
    }
}
