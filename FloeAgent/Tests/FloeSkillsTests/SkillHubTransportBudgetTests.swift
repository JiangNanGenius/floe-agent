import Testing
@testable import FloeSkills

struct SkillHubTransportBudgetTests {
    @Test func curatedChannelsHaveBoundedFeedAndArchiveBudgets() {
        for path in ["catalog.json", "android/catalog.json"] {
            #expect(SkillHubTransportBudget.maximumBytes(owner: "JiangNanGenius", repository: "floe-skill-hub", path: path) == 4_194_304)
        }
        for path in ["packages/example/1.0.0/example.zip", "android/packages/example/1.0.0/example.zip"] {
            #expect(SkillHubTransportBudget.maximumBytes(owner: "JiangNanGenius", repository: "floe-skill-hub", path: path) == 8_388_608)
        }
    }
    @Test func unrelatedRepositoriesAndPathsKeepTheirOriginalLimit() {
        for (owner, repository, path) in [
            ("other", "floe-skill-hub", "packages/a.zip"),
            ("JiangNanGenius", "other", "catalog.json"),
            ("JiangNanGenius", "floe-skill-hub", "reviews/example.review.json"),
            ("JiangNanGenius", "floe-skill-hub", "packages/../a.zip"),
            ("JiangNanGenius", "floe-skill-hub", "packages//a.zip")
        ] {
            #expect(SkillHubTransportBudget.maximumBytes(owner: owner, repository: repository, path: path) == 2_097_152)
        }
        #expect(SkillHubTransportBudget.maximumBytes(owner: "JiangNanGenius", repository: "floe-skill-hub", path: nil) == 2_097_152)
        #expect(SkillHubTransportBudget.maximumBytes(owner: "JiangNanGenius", repository: "floe-agent", path: "skill-hub/packages/example.zip") == 8_388_608)
    }
}
