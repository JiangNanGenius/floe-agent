// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameNarrativeKit

final class InkAdapterTests: XCTestCase {
    func testCreateBuildAndPackageArtifact() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("ink")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try GameInkAdapter.createProject(at: project, title: "Forest Postie")

        // Original source, declared runtime, and full license notices exist.
        let story = try NarrativeTestSupport.text(project.appendingPathComponent("story.ink"))
        XCTAssertTrue(story.contains("=== forest_path ==="))
        XCTAssertTrue(story.contains("VAR letters = 3"))
        XCTAssertTrue(story.contains("+ [沿着溪流走] -> stream"))
        let config = try JSONSerialization.jsonObject(with: try NarrativeTestSupport.read(project.appendingPathComponent("project.json"))) as? [String: Any]
        XCTAssertEqual(config?["engine"] as? String, "ink")
        XCTAssertEqual(config?["runtime"] as? String, "inkjs 2.4.0")
        XCTAssertNotNil(config?["unknownFieldsExample"]) // unknown fields preserved across edits
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("licenses/INKJS-MIT.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt").path))

        // Build the real Web artifact from the pinned resource pack.
        let artifact = work.appendingPathComponent("artifact")
        try GameInkAdapter.buildArtifact(projectAt: project, to: artifact, resources: NarrativeTestSupport.resources)
        let html = try NarrativeTestSupport.text(artifact.appendingPathComponent("index.html"))
        let support = try NarrativeTestSupport.supportText(in: artifact)
        XCTAssertTrue(html.contains("support/ink-bridge.js"))
        XCTAssertFalse(html.contains("window.FloeGame"))
        XCTAssertTrue(support.contains("window.FloeGame"))
        XCTAssertTrue(support.contains("inkjs.Compiler"))
        XCTAssertTrue(support.contains("story.state.LoadJson"))
        XCTAssertFalse(support.contains("=== forest_path ==="))
        let vendor = try NarrativeTestSupport.read(artifact.appendingPathComponent("vendor/inkjs.js"))
        XCTAssertEqual(GameDigest.sha256(vendor), GameInkAdapter.engineSHA256)
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("story.ink")), try NarrativeTestSupport.read(project.appendingPathComponent("story.ink")))

        // The existing byte-verified artifact package accepts the engine artifact.
        let package = try NarrativeTestSupport.artifactPackage(sourceRoot: artifact, engine: .ink)
        try package.verify()
        XCTAssertEqual(package.prepared.engine, .ink)
        XCTAssertEqual(package.prepared.entry.value, "index.html")
        XCTAssertTrue(package.files.contains { $0.path.value == "vendor/inkjs.js" })
    }

    func testImportPreservesOriginalBytesAndUnknownFiles() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("ink-import")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let mainStory = "VAR x = 1\n-> start\n=== start ===\nhello {x}\n-> END\n"
        try Data(mainStory.utf8).write(to: source.appendingPathComponent("main.ink"))
        try Data("include\n".utf8).write(to: source.appendingPathComponent("nested/extra.ink"))
        let unknown = Data([0x00, 0x01, 0xFE, 0xFF, 0x7A])
        try unknown.write(to: source.appendingPathComponent("notes.bin"))
        // Full import: hidden files and names containing dots are legal and kept.
        let hidden = Data("hidden config".utf8)
        try hidden.write(to: source.appendingPathComponent(".floe-unknown.txt"))
        let dotted = Data("dotted name".utf8)
        try dotted.write(to: source.appendingPathComponent("notes..bin"))

        let target = work.appendingPathComponent("imported")
        try GameInkAdapter.importProject(from: source, to: target, title: "Imported")
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("main.ink")), Data(mainStory.utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("nested/extra.ink")), Data("include\n".utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("notes.bin")), unknown)
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent(".floe-unknown.txt")), hidden)
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("notes..bin")), dotted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("project.json").path))
    }

    func testRepositoryEditSaveReopenRoundtrip() async throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("ink-repo")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("source")
        try GameInkAdapter.createProject(at: source, title: "Forest Postie")
        let repository = try FileGameProjectRepository(directory: work.appendingPathComponent("repository"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let imported = try await repository.importProject(from: source, projectID: id, owner: owner, title: "Forest Postie", engine: .ink)
        let editedStory = try NarrativeTestSupport.text(source.appendingPathComponent("story.ink"))
            + "\n// AI edit: extra author's note\n"
        let committed = try await repository.commit(id, owner: owner, expectedRevision: imported.revision,
            changes: [.write(try GameRelativePath("story.ink"), Data(editedStory.utf8))])
        let reopened = try FileGameProjectRepository(directory: work.appendingPathComponent("repository"))
        let loaded = try await reopened.open(id, owner: owner)
        XCTAssertEqual(loaded.revision, committed.revision)
        let bytes = try await reopened.read(id, owner: owner, revision: loaded.revision, path: GameRelativePath("story.ink"))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("AI edit: extra author's note"))
        let exported = try await reopened.export(id, owner: owner, expectedRevision: loaded.revision, to: work.appendingPathComponent("exported"))
        let artifact = work.appendingPathComponent("artifact")
        try GameInkAdapter.buildArtifact(projectAt: exported.rootURL, to: artifact, resources: NarrativeTestSupport.resources)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("index.html").path))
    }
}

final class TwineAdapterTests: XCTestCase {
    func testCreateBuildAndParseBack() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("twine")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try GameTwineAdapter.createProject(at: project, title: "Forest Postie")

        let artifact = work.appendingPathComponent("artifact")
        try GameTwineAdapter.buildArtifact(projectAt: project, to: artifact, resources: NarrativeTestSupport.resources)
        let html = try NarrativeTestSupport.text(artifact.appendingPathComponent("index.html"))
        let support = try NarrativeTestSupport.supportText(in: artifact)
        let storyData = try NarrativeTestSupport.read(artifact.appendingPathComponent("game/story.twine.json"))
        let story = try GameTwineAdapter.decode(storyData)
        let storyElement = GameTwineAdapter.storyDataElement(for: story)
        XCTAssertTrue(storyElement.contains("<tw-storydata"))
        XCTAssertTrue(storyElement.contains("startnode=\"1\""))
        XCTAssertTrue(storyElement.contains("<tw-passagedata"))
        XCTAssertFalse(html.contains("<tw-storydata"))
        XCTAssertTrue(html.contains("support/twine-bootstrap.js"))
        XCTAssertTrue(html.contains("vendor/sugarcube-libraries.js"))
        XCTAssertFalse(html.contains("/*! SugarCube JS */"))
        XCTAssertFalse(html.contains("{{STORY_NAME}}"))
        XCTAssertFalse(html.contains("{{STORY_DATA}}"))
        XCTAssertTrue(support.contains("window.FloeGame"))
        XCTAssertTrue(support.contains("SugarCube.State"))
        // Restore must use the real SugarCube save-state path and render once
        // (Engine.show), never re-execute the passage via Engine.play.
        XCTAssertTrue(support.contains("State.marshalForSave()"))
        XCTAssertTrue(support.contains("State.unmarshalForSave(state.save)"))
        XCTAssertTrue(support.contains("Engine.show()"))
        XCTAssertFalse(support.contains("Engine.play(state.passage)"))
        XCTAssertFalse(html.contains("$letters"))
        XCTAssertFalse(support.contains("$letters"))
        // The extracted upstream engine is real and byte-carried; the format's
        // own token substitution is the only published-page transformation.
        let engine = try NarrativeTestSupport.text(artifact.appendingPathComponent("vendor/sugarcube-engine.js"))
        XCTAssertTrue(engine.contains("SugarCube JS") || engine.contains("Story"))
        XCTAssertFalse(engine.contains("{{STORY_NAME}}"))
        // The pinned format package stays in the resource pack, not as a page script.
        let format = try NarrativeTestSupport.read(NarrativeTestSupport.resources.appendingPathComponent("sugarcube/sugarcube-format.js"))
        XCTAssertEqual(GameDigest.sha256(format), GameTwineAdapter.formatSHA256)
        let published = try GameTwineAdapter.publishedSource(from: format)
        XCTAssertTrue(published.contains("{{STORY_DATA}}"))
        XCTAssertThrowsError(try GameTwineAdapter.publishedSource(from: Data("not a format".utf8)))

        // Re-parse our own genuine Twine 2 document (byte-level roundtrip of passages).
        let parsed = try StoryParser.parse(html: storyElement)
        XCTAssertEqual(parsed.startPID, "1")
        XCTAssertEqual(parsed.passages.count, 6)
        let start = try XCTUnwrap(parsed.passages.first { $0.pid == "1" })
        XCTAssertEqual(start.name, "Start")
        XCTAssertTrue(start.text.contains("$letters"))
        XCTAssertTrue(start.text.contains("[[沿着溪流走|Stream]]"))
        let count = try XCTUnwrap(parsed.passages.first { $0.name == "Count" })
        XCTAssertTrue(count.text.contains("<<set $letters = $letters + 1>>"))

        let package = try NarrativeTestSupport.artifactPackage(sourceRoot: artifact, engine: .twine)
        try package.verify()
        XCTAssertEqual(package.prepared.engine, .twine)
    }

    func testImportTwineExportPreservesUnknownAttributes() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("twine-import")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let exported = """
        <!doctype html><html><body>
        <tw-storydata name="Imported Story" startnode="7" creator="Twine" creator-version="2.5.1" ifid="ABC-123" format="SugarCube" format-version="2.37.3" options="debug" hidden data-floe-extra="kept">
        <style role="stylesheet" id="twine-user-stylesheet" type="text/twine-css">body { color: red }</style>
        <tw-passagedata pid="7" name="Start" tags="intro" position="120,80" size="100,100" data-extra="passage-kept">Hello &lt;b&gt;world&lt;/b&gt; &amp; friends.</tw-passagedata>
        <tw-passagedata pid="8" name="Next" tags="" position="320,80" size="100,100">Second passage.</tw-passagedata>
        </tw-storydata></body></html>
        """
        try Data(exported.utf8).write(to: source.appendingPathComponent("story.html"))
        let target = work.appendingPathComponent("imported")
        try GameTwineAdapter.importProject(from: source, to: target, title: "Imported Story")
        let model = try NarrativeTestSupport.read(target.appendingPathComponent("story.twine.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: model) as? [String: Any])
        XCTAssertEqual(object["start"] as? String, "7")
        let storyAttributes = try XCTUnwrap(object["storyAttributes"] as? [String: String])
        XCTAssertEqual(storyAttributes["data-floe-extra"], "kept")
        let passages = try XCTUnwrap(object["passages"] as? [[String: Any]])
        XCTAssertEqual(passages.count, 2)
        let start = try XCTUnwrap(passages.first { ($0["pid"] as? String) == "7" })
        XCTAssertEqual(start["text"] as? String, "Hello <b>world</b> & friends.")
        XCTAssertEqual((start["attributes"] as? [String: String])?["data-extra"], "passage-kept")
        // Original export preserved byte-exact under original/.
        XCTAssertEqual(try NarrativeTestSupport.read(target.appendingPathComponent("original/story.html")), Data(exported.utf8))
        // Reconstructing the story-data element keeps the unknown attributes.
        let rebuilt = GameTwineAdapter.storyDataElement(for: try GameTwineAdapter.decode(model))
        XCTAssertTrue(rebuilt.contains("data-floe-extra=\"kept\""))
        XCTAssertTrue(rebuilt.contains("data-extra=\"passage-kept\""))
        XCTAssertTrue(rebuilt.contains("startnode=\"7\""))
        // And it parses back to the same passages.
        let roundtrip = try StoryParser.parse(html: rebuilt)
        XCTAssertEqual(roundtrip.passages.count, 2)
        XCTAssertEqual(roundtrip.startPID, "7")
    }

    func testHTMLAttributeParserRejectsUnterminatedValues() {
        XCTAssertThrowsError(try HTML.attributes(in: "<tw-passagedata name=\"broken>"))
        let parsed = try? HTML.attributes(in: "<tw-storydata name=\"A &amp; B\" startnode='1' hidden>")
        XCTAssertEqual(parsed?["name"], "A & B")
        XCTAssertEqual(parsed?["startnode"], "1")
        XCTAssertEqual(parsed?["hidden"], "")
    }
}
