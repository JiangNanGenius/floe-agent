import Foundation

public extension CuratedSkillHub.StagedSkill {
    /// Only an actual verified production stage can enter the existing
    /// rollback/CAS upgrade workflow. A loose URL is never official proof.
    func upgradeCandidate(installed: SkillContentSnapshot) throws -> SkillUpgradeCandidate {
        try SkillUpgradeCandidate(verifiedCurated: self, installed: installed)
    }
}
