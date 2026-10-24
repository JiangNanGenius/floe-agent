import Foundation
import Testing
@testable import FloeSkills

@Suite("FloeSkills.SkillBulkUpdatePlan")
struct SkillBulkUpdatePlanTests {
    private func item(_ id: String, source: Bool = true, version: String? = "2.0.0", digest: String = "installed") -> SkillBulkUpdatePlan.Item {
        .init(id: id, installedDigest: digest, hasKnownSource: source, availableVersion: version)
    }

    @Test("Unknown, local and creator sources cannot enter either batch even with a claimed version")
    func unknownSources() {
        let items = [item("official"), item("local", source: false), item("created", source: false)]
        #expect(SkillBulkUpdatePlan.checks(items) == ["official"])
        #expect(SkillBulkUpdatePlan.updates(items, states: [:]) == ["official"])
    }

    @Test("The complete installed snapshot is stable and de-duplicated")
    func completeSnapshot() {
        let items = [item("outside-current-search"), item("visible"), item("outside-current-search")]
        #expect(SkillBulkUpdatePlan.checks(items) == ["outside-current-search", "visible"])
        #expect(SkillBulkUpdatePlan.updates(items, states: [:]) == ["outside-current-search", "visible"])
    }

    @Test("Review and busy rows do not block unrelated available updates or failed retries")
    func partialBatch() {
        let items = [item("review"), item("failed"), item("busy"), item("ready"), item("unknown-version", version: nil)]
        let states: [String: SkillUpdateAvailability] = [
            "review": .init(installedDigest: "installed", version: "2.0.0", phase: .reviewRequired),
            "failed": .init(installedDigest: "installed", version: "2.0.0", phase: .failed, error: "offline"),
            "busy": .init(installedDigest: "installed", version: "2.0.0", phase: .updating),
            "ready": .init(installedDigest: "installed", version: "2.0.0", phase: .available)
        ]
        #expect(SkillBulkUpdatePlan.updates(items, states: states) == ["failed", "ready"])
    }

    @Test("Old review metadata cannot suppress a newly installed package")
    func staleDigest() {
        let old = SkillUpdateAvailability(installedDigest: "old", version: "2.0.0", phase: .reviewRequired)
        #expect(SkillBulkUpdatePlan.updates([item("changed", digest: "new")], states: ["changed": old]) == ["changed"])
    }

    @Test("Availability belongs to the exact installed digest and source")
    func sourceBinding() {
        let state = SkillUpdateAvailability(installedDigest: "old", sourceIdentity: "owner/repo/main/SKILL.md", version: "2", phase: .available)
        #expect(state.isCurrent(installedDigest: "old", sourceIdentity: "owner/repo/main/SKILL.md"))
        #expect(!state.isCurrent(installedDigest: "new", sourceIdentity: "owner/repo/main/SKILL.md"))
        #expect(!state.isCurrent(installedDigest: "old", sourceIdentity: "different/repo/main/SKILL.md"))
    }

    @Test("GitHub package path and ref are preserved without deriving from the skill ID")
    func exactSource() throws {
        let source = try #require(SkillBulkUpdatePlan.githubReference("https://github.com/owner/repository/blob/release/packages/example/SKILL.md"))
        #expect(source.owner == "owner")
        #expect(source.repository == "repository")
        #expect(source.ref == "release")
        #expect(source.path == "packages/example/SKILL.md")
    }

    @Test("Only actual unambiguous GitHub blob sources are candidates", arguments: [
        "floe-creator://local/example", "file:///tmp/SKILL.md", "https://github.com/owner/repo",
        "https://github.com/owner/repo/tree/main/example", "https://github.com/owner/repo/blob/main",
        "https://github.com.evil.test/owner/repo/blob/main/SKILL.md",
        "https://user:secret@github.com/owner/repo/blob/main/SKILL.md",
        "https://github.com/owner/repo/blob/main/SKILL.md?token=value",
        "https://github.com/owner/repo/blob/feature%2Fbranch/SKILL.md",
        "https://github.com/owner/repo/blob/main/../SKILL.md"
    ])
    func rejectsUnprovenSources(_ text: String) {
        #expect(SkillBulkUpdatePlan.githubReference(text) == nil)
    }

    @Test("Equal or older versions never claim a new release")
    func numericVersion() {
        #expect(SkillBulkUpdatePlan.isNewer("1.10.0", than: "1.9.0"))
        #expect(!SkillBulkUpdatePlan.isNewer("1.9.0", than: "1.10.0"))
        #expect(!SkillBulkUpdatePlan.isNewer("1.9.0", than: "1.9.0"))
    }
}
