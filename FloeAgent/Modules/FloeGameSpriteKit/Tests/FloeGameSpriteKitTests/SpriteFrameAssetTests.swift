// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameEditingCore
import FloeGameSpriteCore

@Suite("Sliced frames use the existing project asset lifecycle")
@MainActor
struct SpriteFrameAssetTests {
    @Test("Selected-frame pixels survive undo, save and reopening without changing the sheet")
    func frameAssetLifecycle() async throws {
        let sheet = try SpriteTestSupport.sheet(columns: 12, rows: 8, frameWidth: 4, frameHeight: 4)
        let (repository, session, path, unknown) = try await SpriteTestSupport.makeProject(name: "slice", sheet: sheet)
        let original = try await session.documentBytes(at: path)
        let model = SpriteEditorDocument(session: session, path: path)
        await model.load()
        model.applyPreset(.rpgMakerMV, scope: .fullSheet)
        model.selectFrame(13)
        let target = try #require(await model.addSelectedFrameAsAsset())
        #expect(target.value == "assets/hero-frame-0014.png")
        #expect(model.issue == nil)
        let frameBytes = try await session.documentBytes(at: target)
        let frame = try SpritePNG.decode(frameBytes)
        #expect(frame == sheet.cropped(to: SpritePixelRect(x: 4, y: 4, width: 4, height: 4)))
        #expect(try await session.documentBytes(at: path) == original)
        #expect(session.history.count == 1)
        try await session.undo()
        #expect(!session.existingPaths().contains(target))
        try await session.redo()
        #expect(try await session.documentBytes(at: target) == frameBytes)
        _ = try await session.save(title: "Add sliced frame")
        let reopened = try await GameEditingSession.open(
            repository: repository, projectID: session.projectID, owner: SpriteTestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .rpgMakerMV))
        #expect(try await reopened.documentBytes(at: target) == frameBytes)
        #expect(try await reopened.documentBytes(at: path) == original)
        #expect([UInt8](try await reopened.documentBytes(at: GameRelativePath("notes/keep.bin"))) == unknown)
    }

    @Test("Repeated slices get unique names and an in-flight stroke cannot be exported")
    func uniqueNamesAndCommittedPixels() async throws {
        let sheet = try SpriteTestSupport.sheet(columns: 3, rows: 4, frameWidth: 4, frameHeight: 4)
        let (_, session, path, _) = try await SpriteTestSupport.makeProject(name: "slice-names", sheet: sheet)
        let model = SpriteEditorDocument(session: session, path: path)
        await model.load()
        model.applyPreset(.rpgMakerMV, scope: .character)
        model.color = SpriteRGBA(red: 1, green: 2, blue: 3, alpha: 0)
        #expect(model.beginStroke(at: SpritePixelPoint(x: 1, y: 1)))
        #expect(await model.addSelectedFrameAsAsset() == nil)
        #expect(!session.isDirty)
        await model.endStroke()
        let first = try #require(await model.addSelectedFrameAsAsset())
        let firstBytes = try await session.documentBytes(at: first)
        let second = try #require(await model.addSelectedFrameAsAsset())
        #expect(first.value == "assets/hero-frame-0001.png")
        #expect(second.value == "assets/hero-frame-0001-2.png")
        #expect(try await session.documentBytes(at: first) == firstBytes)
        #expect(try await session.documentBytes(at: second) == firstBytes)
        let pixels = try SpritePNG.decode(firstBytes)
        #expect(pixels.color(x: 1, y: 1) == model.color)
    }
}
