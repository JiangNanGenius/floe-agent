import XCTest
import UIKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloeTools
@testable import FloeApp

final class AppleImagePlaygroundTests: XCTestCase {
    @MainActor func testTheAppleCapabilityHasARealSystemSymbol() {
        XCTAssertNotNil(UIImage(systemName: AppleCapability.imagePlayground.icon))
    }

    @MainActor func testOldWorkspaceArtifactIsHiddenOnlyBehindItsOwnMatchingOutputReceipt() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let output = try AppleImagePlaygroundOutput.persist(fixture.image, context: fixture.context,
            snapshotRoot: fixture.directory.appendingPathComponent("snapshots"))
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        let path = try XCTUnwrap(receipt["path"] as? String)
        let legacy = ToolArtifactReference(id: UUID(), relativePath: path, mimeType: fixture.image.mimeType,
            byteCount: fixture.image.data.count, sha256: fixture.image.sha256)
        let context = RunOutputReceiptContext(runID: fixture.context.runID, conversationID: fixture.context.conversationID,
            callID: fixture.context.toolCallID, toolName: "image.playground")
        XCTAssertTrue(ToolArtifactPresentation.withoutLegacyPlaygroundDuplicates([legacy], outputs: output.outputFiles, context: context).isEmpty)
        var wrong = context; wrong.runID = UUID()
        XCTAssertEqual(ToolArtifactPresentation.withoutLegacyPlaygroundDuplicates([legacy], outputs: output.outputFiles, context: wrong), [legacy])
        XCTAssertEqual(ToolArtifactPresentation.withoutLegacyPlaygroundDuplicates([legacy], outputs: [], context: context), [legacy])
    }

    func testWorkspaceCommitAndRunSnapshotPreserveActualPNGBytes() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let output = try AppleImagePlaygroundOutput.persist(fixture.image, context: fixture.context,
            snapshotRoot: fixture.directory.appendingPathComponent("snapshots"))
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.artifacts.isEmpty, "A task-workspace path must not be advertised as an App artifact")
        XCTAssertEqual(output.outputFiles.count, 1)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        let path = try XCTUnwrap(receipt["path"] as? String)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(path)), fixture.image.data)
        XCTAssertEqual(output.outputFiles.first?.sha256, fixture.image.sha256)
        XCTAssertEqual(output.outputFiles.first?.mimeType, "image/png")
        XCTAssertTrue((receipt["inlineMarkdown"] as? String ?? "").contains(output.outputFiles[0].outputID))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("original.png")), fixture.image.data)
        let replay = try AppleImagePlaygroundOutput.persist(fixture.image, context: fixture.context,
            snapshotRoot: fixture.directory.appendingPathComponent("snapshots"))
        XCTAssertEqual(replay.outputFiles.first?.id, output.outputFiles.first?.id)
    }

    func testCancelledOrTemporaryCallNeverCreatesOutputDirectory() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.context.cancellation.cancel()
        XCTAssertThrowsError(try AppleImagePlaygroundOutput.persist(fixture.image, context: fixture.context,
            snapshotRoot: fixture.directory.appendingPathComponent("snapshots")))
        var temporary = fixture.context
        temporary.cancellation = CancellationToken()
        temporary.temporaryReadOnly = true
        XCTAssertThrowsError(try AppleImagePlaygroundOutput.persist(fixture.image, context: temporary,
            snapshotRoot: fixture.directory.appendingPathComponent("snapshots")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("GeneratedImages").path))
    }

    func testPersistedFileScopeAndSymlinkContainmentRemainAuthoritative() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var scoped = fixture.context
        scoped.allowedWorkspacePaths = ["original.png"]
        XCTAssertThrowsError(try AppleImagePlaygroundOutput.persist(fixture.image, context: scoped,
            snapshotRoot: fixture.directory.appendingPathComponent("snapshots")))
        let outside = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("GeneratedImages"),
                                                  withDestinationURL: outside)
        XCTAssertThrowsError(try AppleImagePlaygroundOutput.persist(fixture.image, context: fixture.context,
            snapshotRoot: fixture.directory.appendingPathComponent("snapshots")))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testMissingTaskBindingCannotCreateOutput() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var context = fixture.context
        context.conversationID = nil
        XCTAssertThrowsError(try AppleImagePlaygroundOutput.persist(fixture.image, context: context,
            snapshotRoot: fixture.directory.appendingPathComponent("snapshots")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("GeneratedImages").path))
    }

    private func fixture() throws -> (directory: URL, root: URL, image: AppleImagePlaygroundImage, context: ToolContext) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floe-playground-\(UUID())")
        let root = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8,
            bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let cgImage = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = try AppleImagePlaygroundImage(data: data as Data)
        try image.data.write(to: root.appendingPathComponent("original.png"))
        var toolContext = ToolContext(runID: UUID(), toolCallID: "image-playground-test",
            workspaceRootURL: root, cancellation: CancellationToken())
        toolContext.conversationID = UUID()
        return (directory, root, image, toolContext)
    }
}
