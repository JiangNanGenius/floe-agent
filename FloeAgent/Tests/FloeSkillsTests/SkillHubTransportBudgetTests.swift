import Testing
@testable import FloeSkills

struct SkillHubTransportBudgetTests {
    @Test func independentKnownEngineHasItsOwnBudget() {
        let path = "engines/impeccable/dist/impeccable-0.1.17+floe.1.0.0/riscv64gc-unknown-linux-musl/floe-impeccable"
        #expect(SkillHubTransportBudget.maximumBytes(owner: "JiangNanGenius", repository: "floe-skill-hub", path: path) == 16_777_216)
        #expect(SkillHubTransportBudget.maximumBytes(owner: "other", repository: "floe-skill-hub", path: path) == 2_097_152)
        #expect(SkillHubTransportBudget.maximumBytes(owner: "JiangNanGenius", repository: "other", path: path) == 2_097_152)
    }

    @Test func engineBudgetRefusesOtherArtifactsAndEncodedPaths() {
        let prefix = "engines/impeccable/dist/"
        for path in [
            prefix + "impeccable-0.1.17/aarch64-unknown-linux-musl/floe-impeccable",
            prefix + "impeccable-0.1.17/riscv64gc-unknown-linux-musl/other-engine",
            prefix + "impeccable-0.1.17/riscv64gc-unknown-linux-musl/floe-impeccable.zip",
            prefix + "impeccable-/riscv64gc-unknown-linux-musl/floe-impeccable",
            prefix + "impeccable-0.1.17%2fextra/riscv64gc-unknown-linux-musl/floe-impeccable",
            prefix + "impeccable-0.1.17/../riscv64gc-unknown-linux-musl/floe-impeccable",
            prefix + "impeccable-0.1.17//riscv64gc-unknown-linux-musl/floe-impeccable",
        ] {
            #expect(SkillHubTransportBudget.maximumBytes(owner: "JiangNanGenius", repository: "floe-skill-hub", path: path) == 2_097_152)
        }
    }

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
