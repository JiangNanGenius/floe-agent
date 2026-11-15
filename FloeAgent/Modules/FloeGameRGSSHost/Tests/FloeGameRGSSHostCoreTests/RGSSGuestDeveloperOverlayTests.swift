// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameRGSS
import FloeGameRGSSHostCore
import FloeRPGCore

final class RGSSGuestDeveloperOverlayTests: XCTestCase {
    private let overlayScript = Data("""
    # Floe developer overlay fixture
    module FloeDeveloper
      VERSION = '1.0.0'
    end
    """.utf8)

    func testProjectRevisionReadsSourceWithoutWriting() throws {
        let source = try RGSSGuestTestSupport.makeProject(validScriptArchive: true)
        let scriptPath = source.appendingPathComponent("Data/Scripts.rxdata")
        let before = try Data(contentsOf: scriptPath)
        let plan = try RGSSGuestDeveloperOverlay.projectRevisionChanges(
            sourceRoot: source, engine: .rpgMakerXP, overlayScript: overlayScript)
        XCTAssertFalse(plan.alreadyInstalled)
        XCTAssertEqual(plan.changes.count, 2)
        let afterPlan = try Data(contentsOf: scriptPath)
        XCTAssertEqual(afterPlan, before,
                       "planning must not rewrite the imported archive")
        let overlayPath = source.appendingPathComponent("floe-developer/floe_developer.rb")
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlayPath.path))
    }

    func testApplyInstallsOnlyIntoRunCopyAndIsIdempotent() async throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject(validScriptArchive: true)
        let sourceArchive = source.appendingPathComponent("Data/Scripts.rxdata")
        let sourceBytes = try Data(contentsOf: sourceArchive)
        let context = try RGSSGuestTestSupport.context(for: projectID, owner: owner, root: source)
        let request = try RGSSGuestRunRequest(
            workspaceID: UUID(), context: context, engine: .rpgMakerXP,
            displayServiceID: "display-1")
        let staged = try await RGSSGuestTestSupport.staged(request)
        XCTAssertFalse(RGSSGuestDeveloperOverlay.isInstalled(
            in: staged.runRoot, engine: .rpgMakerXP))

        let first = try RGSSGuestDeveloperOverlay.apply(to: staged,
                                                        overlayScript: overlayScript)
        XCTAssertFalse(first.alreadyInstalled)
        XCTAssertTrue(RGSSGuestDeveloperOverlay.isInstalled(
            in: staged.runRoot, engine: .rpgMakerXP))
        let sourceAfter = try Data(contentsOf: sourceArchive)
        XCTAssertEqual(sourceAfter, sourceBytes,
                       "the source archive is unchanged")

        let stagedArchive = staged.runRoot.appendingPathComponent("Data/Scripts.rxdata")
        let patched = try RPGScriptArchive.decode(Data(contentsOf: stagedArchive))
        XCTAssertTrue(patched.contains { $0.title.utf8String == "Floe Developer" })
        XCTAssertEqual(patched.count, 3)
        let overlayFile = staged.runRoot.appendingPathComponent(
            RGSSGuestDeveloperOverlay.overlayRelativePath)
        let overlayBytes = try Data(contentsOf: overlayFile)
        XCTAssertEqual(overlayBytes, overlayScript)

        let second = try RGSSGuestDeveloperOverlay.apply(to: staged,
                                                         overlayScript: overlayScript)
        XCTAssertTrue(second.alreadyInstalled)
        let patchedAgain = try RPGScriptArchive.decode(Data(contentsOf: stagedArchive))
        XCTAssertEqual(patchedAgain.count, 3, "re-applying must not duplicate the entry")
    }

    func testEncryptedOnlyProjectCannotInstallOverlay() throws {
        let source = try RGSSGuestTestSupport.makeProject(validScriptArchive: true)
        try FileManager.default.removeItem(at: source.appendingPathComponent("Data/Scripts.rxdata"))
        do {
            _ = try RGSSGuestDeveloperOverlay.projectRevisionChanges(
                sourceRoot: source, engine: .rpgMakerXP, overlayScript: overlayScript)
            XCTFail("missing loose scripts must fail")
        } catch let error as RGSSGuestRunError {
            guard case .developerOverlayUnsupported = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }
}
