// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG && targetEnvironment(simulator)
import Foundation
import XCTest
import FloeCore
import FloeModels
@testable import FloeApp

@MainActor final class CADM30SelectionAttachmentContractTests: XCTestCase {
    func testContextStagesWithoutRecentAndUnadoptedWrongOwnerCannotDeleteIt() async throws {
        let environment=try await appQualificationEnvironment(), owner=UUID()
        let files=environment.filesCenter, recent=files.recentFiles
        let data=Data(#"{"schema":1,"kind":"cad_selection","selection":{"datum_plane":{"id":"00000000-0000-4000-8000-000000000030"}}}"#.utf8)
        let attachment=try files.registerContextJSON(data,displayName:"Selected 3D Part.json",conversationID:owner)
        let url=try files.resolveURL(for:attachment)
        defer{try? files.discardUnadoptedContextJSON(attachment,conversationID:owner)}
        XCTAssertEqual(try Data(contentsOf:url),data)
        XCTAssertEqual(attachment.sha256,FloeDigest.sha256Hex(data))
        XCTAssertEqual(files.recentFiles,recent,"Selection snapshots are not imported into recent/My Files")
        XCTAssertThrowsError(try files.discardUnadoptedContextJSON(attachment,conversationID:UUID()))
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        try files.discardUnadoptedContextJSON(attachment,conversationID:owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
    func testStaleDraftCASPreservesTextAttachmentsAndReleasesOnlyNewContext() async throws {
        let environment=try await appQualificationEnvironment(), owner=UUID()
        let store=ComposerDraftStore.shared, files=environment.filesCenter
        defer{store.clear(conversationID:owner)}
        let old=AttachmentRef(kind:.document,displayName:"Existing user attachment",storage:.none)
        _=store.save(text:"Original unsent text",attachments:[old],conversationID:owner)
        let revision=try XCTUnwrap(store.entry(for:owner)?.revision)
        let data=Data(#"{"schema":1,"kind":"cad_selection"}"#.utf8)
        let context=try files.registerContextJSON(data,displayName:"Selected 3D Part.json",conversationID:owner)
        let url=try files.resolveURL(for:context)
        _=store.save(text:"Newer user text",attachments:[old],conversationID:owner)
        XCTAssertNil(store.save(text:"Original unsent text",attachments:[old,context],conversationID:owner,expectedRevision:revision))
        try files.discardUnadoptedContextJSON(context,conversationID:owner)
        XCTAssertEqual(store.text(for:owner),"Newer user text")
        XCTAssertEqual(store.attachments(for:owner),[old])
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
    func testContextRejectsInvalidOrOversizeJSONWithoutRecentMutation() async throws {
        let files=try await appQualificationEnvironment().filesCenter, recent=files.recentFiles
        XCTAssertThrowsError(try files.registerContextJSON(Data("broken".utf8),displayName:"Part.json",conversationID:UUID()))
        XCTAssertThrowsError(try files.registerContextJSON(Data(repeating:32,count:65537),displayName:"Part.json",conversationID:UUID()))
        XCTAssertEqual(files.recentFiles,recent)
    }
}
#endif
