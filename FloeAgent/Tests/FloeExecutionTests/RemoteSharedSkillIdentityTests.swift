import Foundation
import Testing
@testable import FloeExecution

@Suite("Remote shared Skill identity")
struct RemoteSharedSkillIdentityTests {
    private func skill(path: String? = nil, digest: String? = nil) -> RemoteSharedSkill {
        let hash = digest ?? String(repeating: "a", count: 64)
        return RemoteSharedSkill(id: "sample", name: "Sample", version: "1.0.0",
            repository: "https://example.invalid/skills.git", ref: "main", subdirectory: "sample",
            revision: String(repeating: "b", count: 40), digest: hash,
            relativePath: path ?? "packages/sample/\(hash)", updatedAt: 0)
    }
    @Test("A version is pinned to the exact digest directory")
    func digestDirectory() {
        let pinned = skill()
        #expect(RemoteSharedSkillsService.isValid(pinned))
        #expect(pinned.containerPath == "/opt/floe/skills/packages/sample/" + pinned.digest)
        #expect(!RemoteSharedSkillsService.isValid(skill(path: "packages/sample/current")))
        #expect(!RemoteSharedSkillsService.isValid(skill(path: "packages/sample/../../private")))
        #expect(!RemoteSharedSkillsService.isValid(skill(digest: "not-a-digest")))
    }
}
