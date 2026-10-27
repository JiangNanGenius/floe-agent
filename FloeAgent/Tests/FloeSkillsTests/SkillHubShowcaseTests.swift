// FloeSkillsTests — strict contract tests for the native Skill Hub showcase
// validator (lane file, mirrors web/src/skills/hub-showcase.ts behavior).
//
// These cover the publication pin, path/key/bounds rejection, caption
// truthfulness, bilingual text rules, byte-size caps, magic-byte mismatch
// and the static SVG scanner — every rule that must reject BEFORE any native
// renderer sees a byte. No UI, no network, deterministic fixtures only.

import XCTest
import FloeSkills

final class SkillHubShowcaseTests: XCTestCase {

    private static let commit = String(repeating: "a", count: 40)

    private func bilingual(_ en: String, _ zh: String) -> [String: String] {
        ["en": en, "zh-Hans": zh]
    }

    private func validEditorial() -> [String: Any] {
        [
            "overview": bilingual("Summarize sources into a brief.", "把资料汇总成简报。"),
            "useCases": [bilingual("Merge weekly notes.", "合并每周笔记。")],
            "examples": [[
                "prompt": bilingual("Summarize this PDF.", "总结这份 PDF。"),
                "output": bilingual("A short brief.", "一份简短简报。"),
            ]],
            "cover": [
                "path": "showcase/media/covers/demo-skill.png",
                "kind": "illustration",
                "credit": bilingual("Floe original, AI-assisted illustration.", "Floe 原创，AI 辅助示意图。"),
                "alt": bilingual("Abstract ribbons form a cover.", "抽象飘带组成封面。"),
            ] as [String: Any],
            "gallery": [[
                "path": "showcase/media/gallery/demo-shot.jpg",
                "kind": "app-screenshot",
                "credit": bilingual("Floe app screenshot.", "Floe 应用截图。"),
                "caption": bilingual("The editor after one command.", "执行一条命令后的编辑器。"),
            ]],
        ]
    }

    private func validDocument(entries: [String: Any]? = nil,
                               picks: [String]? = nil) -> [String: Any] {
        [
            "schemaVersion": 1,
            "editorPicks": picks ?? ["demo-skill"],
            "entries": entries ?? ["demo-skill": validEditorial()],
        ]
    }

    private func data(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root)
    }

    private func decodeFails(_ root: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        let payload: Data
        do {
            payload = try data(root)
        } catch {
            XCTFail("fixture serialization failed: \(error)", file: file, line: line)
            return
        }
        do {
            _ = try SkillHubShowcase.decode(data: payload)
            XCTFail("expected rejection", file: file, line: line)
        } catch is SkillHubShowcaseValidationError {
            // expected
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }

    // MARK: Happy path

    func testValidDocumentDecodesWithLookupsAndLocale() throws {
        let showcase = try SkillHubShowcase.decode(data: data(validDocument()))
        XCTAssertEqual(showcase.editorPicks, ["demo-skill"])
        let cover = try XCTUnwrap(showcase.cover(for: "demo-skill"))
        XCTAssertEqual(cover.path, "showcase/media/covers/demo-skill.png")
        XCTAssertEqual(cover.kind, .illustration)
        XCTAssertTrue(cover.isNativelyRenderable)
        let gallery = showcase.gallery(for: "demo-skill")
        XCTAssertEqual(gallery.count, 1)
        XCTAssertEqual(gallery[0].kind, .appScreenshot)
        XCTAssertNil(showcase.editorial(for: "other-skill"))
        // Locale selection mirrors the signed-feed text rule.
        XCTAssertEqual(cover.credit.value(preferredLanguages: ["zh-Hans-CN", "en"]),
                       "Floe 原创，AI 辅助示意图。")
        XCTAssertEqual(cover.credit.value(preferredLanguages: ["en-US"]),
                       "Floe original, AI-assisted illustration.")
        XCTAssertEqual(cover.credit.value(preferredLanguages: ["fr", "en-GB"]),
                       "Floe original, AI-assisted illustration.")
    }

    func testNullCoverAndEmptyArraysAreValid() throws {
        var editorial = validEditorial()
        editorial["cover"] = NSNull()
        editorial["gallery"] = [Any]()
        editorial["examples"] = [Any]()
        editorial["useCases"] = [Any]()
        let root = ["schemaVersion": 1, "editorPicks": [String](),
                    "entries": ["demo-skill": editorial]] as [String: Any]
        let showcase = try SkillHubShowcase.decode(data: data(root))
        XCTAssertNil(showcase.cover(for: "demo-skill"))
        XCTAssertTrue(showcase.gallery(for: "demo-skill").isEmpty)
    }

    // MARK: Root shape

    func testUnknownRootKeyRejected() { decodeFails([
        "schemaVersion": 1, "editorPicks": [Any](), "entries": [String: Any](), "extra": 1,
    ] as [String: Any]) }

    func testMissingRootKeyRejected() { decodeFails([
        "schemaVersion": 1, "editorPicks": [Any](),
    ] as [String: Any]) }

    func testSchemaVersionMustBeExactlyOne() {
        for bad: Any in [2, 1.5, "1", true, NSNull()] {
            decodeFails(["schemaVersion": bad, "editorPicks": [Any](), "entries": [String: Any]()] as [String: Any])
        }
    }

    func testManifestOverSizeBoundRejected() {
        // Padding the bilingual overview with whitespace beyond the manifest
        // bound must trip the SIZE guard before any structural decode.
        let pad = String(repeating: " ", count: SkillHubShowcase.maximumManifestBytes)
        var editorial = validEditorial()
        editorial["overview"] = bilingual(pad, pad)
        let big = ["schemaVersion": 1, "editorPicks": ["demo-skill"],
                   "entries": ["demo-skill": editorial]] as [String: Any]
        do {
            let payload = try data(big)
            XCTAssertGreaterThan(payload.count, SkillHubShowcase.maximumManifestBytes)
            XCTAssertThrowsError(try SkillHubShowcase.decode(data: payload))
        } catch {
            XCTFail("serialization failed: \(error)")
        }
    }

    // MARK: Editorial/media shape and bounds

    func testEditorialKeysMustBeExact() {
        var editorial = validEditorial()
        editorial["notes"] = bilingual("x", "x")
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
    }

    func testMediaUnknownFieldRejected() {
        var editorial = validEditorial()
        var cover = editorial["cover"] as! [String: Any]
        cover["mime"] = "image/png"
        editorial["cover"] = cover
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
    }

    func testUnknownMediaKindRejected() {
        var editorial = validEditorial()
        var cover = editorial["cover"] as! [String: Any]
        cover["kind"] = "proof-of-work"
        editorial["cover"] = cover
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
    }

    func testNonIllustrationRequiresTruthfulCaption() {
        var editorial = validEditorial()
        var cover = editorial["cover"] as! [String: Any]
        cover["kind"] = "app-screenshot"
        editorial["cover"] = cover
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
    }

    func testExampleKeysMustBeExactlyPromptOutput() {
        var editorial = validEditorial()
        var example = (editorial["examples"] as! [[String: Any]])[0]
        example["verdict"] = bilingual("fine", "可以")
        editorial["examples"] = [example]
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
    }

    func testArrayItemBounds() {
        let text = bilingual("use case", "用例")
        var editorial = validEditorial()
        editorial["useCases"] = Array(repeating: text, count: SkillHubShowcase.maximumArrayItems + 1)
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
        editorial["useCases"] = [text]
        editorial["gallery"] = Array(repeating: [
            "path": "showcase/media/gallery/g.jpg", "kind": "illustration",
            "credit": text,
        ], count: SkillHubShowcase.maximumArrayItems + 1)
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
    }

    func testEditorPicksBoundsUniquenessAndEntryRequirement() {
        decodeFails(validDocument(picks: ["demo-skill", "demo-skill"]))
        decodeFails(validDocument(picks: ["missing-skill"]))
        let many = (0...SkillHubShowcase.maximumEditorPicks).map { "skill-\($0)" }
        let entries = Dictionary(uniqueKeysWithValues: many.map { ($0, validEditorial()) })
        decodeFails(validDocument(entries: entries, picks: many))
    }

    func testEntryCountBound() {
        var entries: [String: Any] = [:]
        for index in 0...SkillHubShowcase.maximumEntries {
            entries["skill-\(index)"] = validEditorial()
        }
        decodeFails(validDocument(entries: entries, picks: []))
    }

    func testMediaReferenceCountBound() {
        // 256 entries each declaring a cover + one gallery item exceed the
        // 256-file contract bound even though the entry count itself fits.
        var entries: [String: Any] = [:]
        for index in 0..<SkillHubShowcase.maximumEntries {
            var editorial = validEditorial()
            var cover = editorial["cover"] as! [String: Any]
            cover["path"] = "showcase/media/covers/skill-\(index).png"
            editorial["cover"] = cover
            editorial["gallery"] = [[
                "path": "showcase/media/gallery/skill-\(index).jpg", "kind": "illustration",
                "credit": bilingual("c", "c"),
            ]]
            entries["skill-\(index)"] = editorial
        }
        decodeFails(validDocument(entries: entries, picks: []))
    }

    // MARK: Skill ids

    func testSkillIdRules() {
        XCTAssertTrue(SkillHubShowcase.isSkillID("demo-skill"))
        XCTAssertTrue(SkillHubShowcase.isSkillID("a1"))
        XCTAssertFalse(SkillHubShowcase.isSkillID("Demo"))
        XCTAssertFalse(SkillHubShowcase.isSkillID("1demo"))
        XCTAssertFalse(SkillHubShowcase.isSkillID("-demo"))
        XCTAssertFalse(SkillHubShowcase.isSkillID("demo-"))
        XCTAssertFalse(SkillHubShowcase.isSkillID("de--mo"))
        XCTAssertFalse(SkillHubShowcase.isSkillID("demo_skill"))
        XCTAssertFalse(SkillHubShowcase.isSkillID(""))
        XCTAssertFalse(SkillHubShowcase.isSkillID(String(repeating: "a", count: 65)))
        decodeFails(validDocument(entries: ["Demo-Skill": validEditorial()], picks: []))
    }

    // MARK: Bilingual text rules

    func testTextKeysAndTypes() {
        var editorial = validEditorial()
        editorial["overview"] = ["en": "only english"]
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
        editorial["overview"] = ["en": "x", "zh-Hans": 5]
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
    }

    func testTextLengthBound() {
        var editorial = validEditorial()
        let long = String(repeating: "a", count: SkillHubShowcase.maximumTextLength + 1)
        editorial["overview"] = bilingual(long, "短")
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
    }

    func testEmptyTextRejected() {
        var editorial = validEditorial()
        editorial["overview"] = bilingual("   ", "简介")
        decodeFails(validDocument(entries: ["demo-skill": editorial]))
    }

    func testMarkupNeverAccepted() {
        var editorial = validEditorial()
        for injected in ["<b>bold</b>", "<!-- c -->", "</p>", "<A href=x>"] {
            editorial["overview"] = bilingual("ok \(injected)", "正常")
            decodeFails(validDocument(entries: ["demo-skill": editorial]))
        }
        // A lone less-than sign is plain text, not markup.
        editorial["overview"] = bilingual("3 < 4", "3 < 4")
        XCTAssertNoThrow(try SkillHubShowcase.decode(data: data(validDocument(entries: ["demo-skill": editorial]))))
    }

    // MARK: Publication pin and media paths

    func testCanonicalCommitPin() {
        XCTAssertTrue(SkillHubShowcase.isCanonicalPublicationCommit(Self.commit))
        XCTAssertFalse(SkillHubShowcase.isCanonicalPublicationCommit(String(repeating: "A", count: 40)))
        XCTAssertFalse(SkillHubShowcase.isCanonicalPublicationCommit(String(repeating: "a", count: 39)))
        XCTAssertFalse(SkillHubShowcase.isCanonicalPublicationCommit(String(repeating: "a", count: 41)))
        XCTAssertFalse(SkillHubShowcase.isCanonicalPublicationCommit("main"))
        XCTAssertFalse(SkillHubShowcase.isCanonicalPublicationCommit(String(repeating: "g", count: 40)))
        XCTAssertFalse(SkillHubShowcase.isCanonicalPublicationCommit(String(repeating: "a", count: 40) + "é"))
    }

    func testSafeMediaPaths() {
        XCTAssertTrue(SkillHubShowcase.isSafeMediaPath("showcase/media/covers/demo.jpg"))
        XCTAssertTrue(SkillHubShowcase.isSafeMediaPath("showcase/media/a/b/c.webp"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("packages/demo.png"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media/../secrets.png"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media/./x.png"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media/.hidden/x.png"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media//x.png"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media/x.png?rev=2"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media/x.png#t"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media/x%20y.png"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media\\x.png"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media/x\tno.png"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media/x.gif"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("showcase/media/x"))
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath("https://raw.example/x.png"))
        let deep = "showcase/media/" + String(repeating: "a", count: 600) + ".png"
        XCTAssertFalse(SkillHubShowcase.isSafeMediaPath(deep))
    }

    func testMimeByExtension() {
        XCTAssertEqual(SkillHubShowcase.mediaMIME(for: "a/b.PNG"), "image/png")
        XCTAssertEqual(SkillHubShowcase.mediaMIME(for: "a/b.jpeg"), "image/jpeg")
        XCTAssertEqual(SkillHubShowcase.mediaMIME(for: "a/b.webp"), "image/webp")
        XCTAssertEqual(SkillHubShowcase.mediaMIME(for: "a/b.svg"), "image/svg+xml")
        XCTAssertNil(SkillHubShowcase.mediaMIME(for: "a/b.gif"))
        XCTAssertNil(SkillHubShowcase.mediaMIME(for: "a/b"))
    }

    // MARK: Magic bytes

    private func png(_ payload: [UInt8] = []) -> [UInt8] {
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + payload
    }

    func testMagicBytesMatchAndMismatch() {
        XCTAssertTrue(SkillHubShowcase.bytesMatchPath(png(), path: "showcase/media/x.png"))
        XCTAssertFalse(SkillHubShowcase.bytesMatchPath([0x89, 0x50, 0x4E, 0x00], path: "showcase/media/x.png"))
        XCTAssertTrue(SkillHubShowcase.bytesMatchPath([0xFF, 0xD8, 0xFF, 0xE0], path: "showcase/media/x.jpg"))
        XCTAssertFalse(SkillHubShowcase.bytesMatchPath([0xFF, 0xD8, 0xFE], path: "showcase/media/x.jpeg"))
        var webp: [UInt8] = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8) + [0x56]
        XCTAssertTrue(SkillHubShowcase.bytesMatchPath(webp, path: "showcase/media/x.webp"))
        webp[9] = 0x41
        XCTAssertFalse(SkillHubShowcase.bytesMatchPath(webp, path: "showcase/media/x.webp"))
        // The web contract's 0x56 ('V') typo payload must NOT pass the
        // native gate: real WebP format bytes are W,E,B,P.
        var wevp: [UInt8] = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEVP".utf8) + [0x56]
        XCTAssertFalse(SkillHubShowcase.bytesMatchPath(wevp, path: "showcase/media/x.webp"))
        wevp[10] = 0x42
        XCTAssertTrue(SkillHubShowcase.bytesMatchPath(wevp, path: "showcase/media/x.webp"))
        // PNG bytes served at a .jpg path are a declared-type mismatch.
        XCTAssertFalse(SkillHubShowcase.bytesMatchPath(png(), path: "showcase/media/x.jpg"))
        // Too-short input cannot claim a signature it does not have.
        XCTAssertFalse(SkillHubShowcase.bytesMatchPath([0xFF, 0xD8], path: "showcase/media/x.jpg"))
        XCTAssertFalse(SkillHubShowcase.bytesMatchPath([UInt8](), path: "showcase/media/x.png"))
        XCTAssertFalse(SkillHubShowcase.bytesMatchPath(png(), path: "showcase/media/x.gif"))
    }

    // MARK: Static SVG scanner (contract parity; App still never executes SVG)

    private let safeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><title>t</title>\
    <defs><linearGradient id="g"><stop offset="0"/><stop offset="1"/></linearGradient></defs>\
    <rect width="10" height="10" fill="url(#g)"/></svg>
    """

    func testStaticSVGPassesScanner() {
        XCTAssertTrue(SkillHubShowcase.inspectSVGSafety(safeSVG).safe)
        XCTAssertTrue(SkillHubShowcase.bytesMatchPath(Array(safeSVG.utf8), path: "showcase/media/x.svg"))
    }

    func testSVGRefusals() {
        let hostile: [(String, String)] = [
            (#"<svg xmlns="http://www.w3.org/2000/svg"><script>fetch()</script></svg>"#, "script"),
            (#"<svg xmlns="http://www.w3.org/2000/svg"><g onclick="x()">a</g></svg>"#, "event handler"),
            (#"<svg xmlns="http://www.w3.org/2000/svg"><foreignObject>html</foreignObject></svg>"#, "foreignObject"),
            (#"<svg xmlns="http://www.w3.org/2000/svg"><image href="http://x/y.png"/></svg>"#, "external image"),
            (##"<svg xmlns="http://www.w3.org/2000/svg"><use href="#frag"/></svg>"##, "use element"),
            (#"<svg xmlns="http://www.w3.org/2000/svg"><animate attributeName="x"/></svg>"#, "animate"),
            ("<!DOCTYPE svg [<!ENTITY x \"y\">]><svg xmlns=\"http://www.w3.org/2000/svg\"></svg>", "DTD"),
            (#"<svg xmlns="http://www.w3.org/2000/svg"><style>@import "evil.css";</style></svg>"#, "CSS import"),
            (#"<svg xmlns="http://www.w3.org/2000/svg"><rect fill="url(http://x/a.svg)"/></svg>"#, "external url()"),
            (#"<svg xmlns="http://www.w3.org/2000/svg"><a><text href="javascript:alert(1)">t</text></a></svg>"#, "link attribute"),
            (#"<svg xmlns="http://www.w3.org/2000/svg"><customel/></svg>"#, "unknown element"),
        ]
        for (source, label) in hostile {
            let result = SkillHubShowcase.inspectSVGSafety(source)
            XCTAssertFalse(result.safe, "expected rejection for \(label): \(source)")
        }
        // And the byte-level gate refuses hostile SVG too.
        XCTAssertFalse(SkillHubShowcase.bytesMatchPath(
            Array(#"<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>"#.utf8),
            path: "showcase/media/x.svg"))
    }

    func testEmptySVGRefused() {
        XCTAssertFalse(SkillHubShowcase.inspectSVGSafety("").safe)
        // No elements at all:
        XCTAssertFalse(SkillHubShowcase.inspectSVGSafety("just text").safe)
    }

    // MARK: Showcase MediaRef native render policy (App-side gate input)

    func testNativelyRenderableFlag() throws {
        var editorial = validEditorial()
        var cover = editorial["cover"] as! [String: Any]
        cover["path"] = "showcase/media/covers/demo.svg"
        cover["kind"] = "illustration"
        editorial["cover"] = cover
        let showcase = try SkillHubShowcase.decode(data: data(validDocument(entries: ["demo-skill": editorial])))
        let svg = try XCTUnwrap(showcase.cover(for: "demo-skill"))
        XCTAssertEqual(svg.mimeType, "image/svg+xml")
        XCTAssertFalse(svg.isNativelyRenderable,
                       "SVG must never mark itself renderable: the App falls back to bundled raster")
    }

    func testCommitAndLookupsAfterDecode() throws {
        // Sanity: the document is keyed by skill id and does NOT invent ids.
        let showcase = try SkillHubShowcase.decode(data: data(validDocument()))
        XCTAssertEqual(showcase.editorial(for: "demo-skill")?.useCases.count, 1)
        XCTAssertEqual(showcase.editorial(for: "demo-skill")?.examples.count, 1)
    }
}
