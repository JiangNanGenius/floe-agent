// FloeCoreTests — Offline help library contract.
//
// Loads the real generated built-in package from the source tree and
// exercises search, references, exact reading with pagination, resource
// verification and package validation failures. The digest seam is injected
// here with CryptoKit, mirroring production's FloeDigest.sha256Hex.

import Foundation
import CryptoKit
import Testing
@testable import FloeCore

@Suite("FloeCore.HelpLibrary")
struct HelpLibraryTests {
    private static let packageRoot: URL = {
        // FloeAgent/Tests/FloeCoreTests/HelpLibraryTests.swift -> repo/FloeAgent
        let here = URL(fileURLWithPath: #filePath)
        let floeAgent = here
            .deletingLastPathComponent() // FloeCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // FloeAgent
        return floeAgent
            .appendingPathComponent("FloeApp")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Help")
    }()

    private static func loadFiles() throws -> [String: Data] {
        let root = packageRoot
        var files: [String: Data] = [:]
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { throw HelpLibraryError.missingFile("bundle root") }
        for case let url as URL in enumerator {
            if url.hasDirectoryPath { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            files[relative] = try Data(contentsOf: url)
        }
        return files
    }

    private let digest: @Sendable (Data) -> String = { data in
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeSnapshot(
        language: HelpLanguage,
        files: [String: Data]? = nil
    ) throws -> HelpLibrarySnapshot {
        try HelpLibrarySnapshot(
            files: files ?? Self.loadFiles(),
            language: language,
            digest: digest
        )
    }

    // MARK: Package

    @Test("Real built-in package validates for both locales")
    func realPackageValidates() throws {
        let files = try Self.loadFiles()
        try HelpLibrarySnapshot.validatePackage(files: files, digest: digest)
        let english = try makeSnapshot(language: .english, files: files)
        let chinese = try makeSnapshot(language: .simplifiedChinese, files: files)
        #expect(english.manifest.id == HelpBundleMetadata.packageID)
        #expect(english.manifest.version == HelpBundleMetadata.bundledVersion)
        #expect(english.manifest.indexPaths["en"] != nil)
        #expect(chinese.index.locale == .simplifiedChinese)
        let expectedArticleIDs: Set<String> = ["quickstart", "shared-basics", "user-manual", "workspaces",
                                               "input.keyboard", "voice.output", "environment.memory"]
        #expect(Set(english.index.articles.map(\.id)) == expectedArticleIDs)
        #expect(Set(chinese.index.articles.map(\.id)) == expectedArticleIDs)
        #expect(english.index.categories.count == 7)
        #expect(Set(english.index.articles.map(\.id)) == Set(chinese.index.articles.map(\.id)))
    }

    @Test("Article and section identifiers stay within the frozen grammar")
    func identifierGrammar() throws {
        let snapshot = try makeSnapshot(language: .english)
        let pattern = #"^[a-z0-9]+([.-][a-z0-9]+)*$"#
        for article in snapshot.index.articles {
            #expect(article.id.range(of: pattern, options: .regularExpression) != nil)
            var seen = Set<String>()
            for section in article.sections {
                #expect(section.id.range(of: pattern, options: .regularExpression) != nil)
                #expect(!seen.contains(section.id), "duplicate \(article.id)#\(section.id)")
                seen.insert(section.id)
            }
        }
    }

    // MARK: References

    @Test("References resolve known articles and sections, reject unknown ones")
    func references() throws {
        let snapshot = try makeSnapshot(language: .english)
        let article = try snapshot.reference(articleID: "user-manual")
        #expect(article.articleID == "user-manual")
        #expect(article.version == HelpBundleMetadata.bundledVersion)
        let section = try snapshot.reference(articleID: "user-manual", sectionID: "section-7")
        #expect(section.sectionID == "section-7")
        #expect(snapshot.article(id: "user-manual") != nil)
        #expect(snapshot.article(id: "nope") == nil)
        #expect(throws: HelpLibraryError.self) {
            try snapshot.reference(articleID: "nope")
        }
        #expect(throws: HelpLibraryError.self) {
            try snapshot.reference(articleID: "user-manual", sectionID: "nope")
        }
    }

    // MARK: Search

    @Test("Search finds the real corpus in English")
    func searchEnglish() throws {
        let snapshot = try makeSnapshot(language: .english)
        let pencil = snapshot.search("Apple Pencil")
        #expect(pencil.contains { $0.reference.articleID == "user-manual"
            && $0.reference.sectionID == "section-7" })
        let keyboard = snapshot.search("keyboard")
        #expect(keyboard.contains { $0.reference.articleID == "input.keyboard" })
        let voice = snapshot.search("voice output")
        #expect(voice.contains { $0.reference.articleID == "voice.output" })
        let memory = snapshot.search("Linux memory")
        #expect(memory.contains { $0.reference.articleID == "environment.memory" })
        #expect(snapshot.search("").isEmpty)
        #expect(snapshot.search("   ").isEmpty)
        #expect(snapshot.search("zzzz-no-such-term-qqqq").isEmpty)
        #expect(snapshot.search("notes", limit: 2).count <= 2)
        for hit in snapshot.search("temporary chat") {
            #expect(!hit.snippet.isEmpty)
            #expect(hit.reference.version == HelpBundleMetadata.bundledVersion)
        }
    }

    @Test("Search finds the real corpus in Simplified Chinese")
    func searchChinese() throws {
        let snapshot = try makeSnapshot(language: .simplifiedChinese)
        #expect(snapshot.search("手记").contains { $0.reference.sectionID == "section-7" })
        #expect(snapshot.search("语音").contains { $0.reference.articleID == "user-manual" })
        #expect(snapshot.search("临时会话").contains { $0.reference.sectionID == "section-19" })
        #expect(snapshot.search("权限").contains { $0.reference.articleID == "user-manual" })
        #expect(snapshot.search("内存").contains { $0.reference.articleID == "environment.memory" })
        #expect(snapshot.search("键盘").contains { $0.reference.articleID == "input.keyboard" })
        // Full-width and case variants normalise.
        #expect(snapshot.search("Ｐｅｎｃｉｌ").count > 0)
    }

    @Test("Whole-query alias hits outrank scattered token hits")
    func searchAliasPriority() throws {
        let snapshot = try makeSnapshot(language: .english)
        let hits = snapshot.search("Apple Pencil")
        #expect(hits.first?.reference.sectionID == "section-7")
        #expect(hits.first?.score ?? 0 >= 40)
    }

    // MARK: Reading

    @Test("Read returns section text with exact identity")
    func readSection() throws {
        let snapshot = try makeSnapshot(language: .english)
        let reference = try snapshot.reference(articleID: "user-manual", sectionID: "section-7")
        let result = try snapshot.read(reference)
        #expect(result.articleTitle == "Floe Agent User Manual")
        #expect(result.sectionTitle?.contains("Notes") == true)
        #expect(result.text.contains("Notes"))
        #expect(result.settingIDs.isEmpty)
        #expect(result.sourceRevision == snapshot.manifest.sourceRevision)
        #expect(result.isTruncated == false)
        #expect(result.nextOffset == nil)
    }

    @Test("How-to reads expose setting ids and paths")
    func readHowto() throws {
        let snapshot = try makeSnapshot(language: .simplifiedChinese)
        let reference = try snapshot.reference(articleID: "environment.memory")
        let result = try snapshot.read(reference)
        #expect(result.settingIDs == ["execution.memory"])
        #expect(result.text.contains("设置 > 执行环境 > 共享运行环境 > 内存"))
    }

    @Test("Pagination truncates and continues to the end")
    func pagination() throws {
        let snapshot = try makeSnapshot(language: .english)
        let reference = try snapshot.reference(articleID: "user-manual", sectionID: "section-15")
        var offset = 0
        var pages = 0
        var assembled = ""
        while true {
            let page = try snapshot.read(reference, offset: offset, maximumCharacters: 400)
            #expect(page.text.count <= 400)
            assembled += page.text
            pages += 1
            #expect(pages < 100)
            guard let next = page.nextOffset else {
                #expect(page.isTruncated == false)
                break
            }
            #expect(page.isTruncated)
            #expect(next > offset)
            offset = next
        }
        #expect(assembled.contains("Canvas"))
        // Offset beyond the end is a deterministic error, not a crash.
        #expect(throws: HelpLibraryError.self) {
            try snapshot.read(reference, offset: assembled.count + 10)
        }
    }

    @Test("Read rejects version and package mismatches exactly")
    func readVersionMismatch() throws {
        let snapshot = try makeSnapshot(language: .english)
        let good = try snapshot.reference(articleID: "quickstart")
        let wrongVersion = HelpReference(
            version: "0.0.1", language: good.language,
            articleID: good.articleID, sectionID: good.sectionID
        )
        #expect(throws: HelpLibraryError.self) { try snapshot.read(wrongVersion) }
        let wrongPackage = HelpReference(
            packageID: "floe.help.other", version: good.version,
            language: good.language, articleID: good.articleID, sectionID: good.sectionID
        )
        #expect(throws: HelpLibraryError.self) { try snapshot.read(wrongPackage) }
    }

    // MARK: Resources

    @Test("Resources return verified data and MIME types")
    func resources() throws {
        let snapshot = try makeSnapshot(language: .english)
        let home = try snapshot.resource(at: "help/assets/guide/home-current.webp")
        #expect(home.mimeType == "image/webp")
        #expect(home.data.count > 100_000)
        #expect(home.data.count <= HelpBundleMetadata.maximumFileBytes)
        let css = try snapshot.resource(at: "help/styles/help.css")
        #expect(css.mimeType.hasPrefix("text/css"))
        #expect(throws: HelpLibraryError.self) {
            try snapshot.resource(at: "help/assets/guide/missing.webp")
        }
        #expect(throws: HelpLibraryError.self) {
            try snapshot.resource(at: "../content.json")
        }
        #expect(throws: HelpLibraryError.self) {
            try snapshot.resource(at: "help/../../../etc/passwd")
        }
    }

    @Test("Package validation detects tampered and broken packages")
    func validationFailures() throws {
        let files = try Self.loadFiles()

        var missing = files
        missing["help/index/en.json"] = nil
        #expect(throws: HelpLibraryError.self) {
            try HelpLibrarySnapshot.validatePackage(files: missing, digest: self.digest)
        }

        var oversized = files
        oversized["help/articles/en/quickstart.html"] = Data(
            repeating: 0x61, count: HelpBundleMetadata.maximumFileBytes + 1
        )
        #expect(throws: HelpLibraryError.self) {
            try HelpLibrarySnapshot.validatePackage(files: oversized, digest: self.digest)
        }

        var malformed = files
        malformed["help/index/en.json"] = Data("not json".utf8)
        #expect(throws: HelpLibraryError.self) {
            try HelpLibrarySnapshot.validatePackage(files: malformed, digest: self.digest)
        }

        var unlisted = files
        unlisted["help/extra.txt"] = Data("extra".utf8)
        #expect(throws: HelpLibraryError.self) {
            try HelpLibrarySnapshot.validatePackage(files: unlisted, digest: self.digest)
        }

        var tampered = files
        let imagePath = "help/assets/guide/home-current.webp"
        var bytes = tampered[imagePath] ?? Data()
        bytes[0] = bytes[0] ^ 0xFF
        tampered[imagePath] = bytes
        #expect(throws: HelpLibraryError.self) {
            try HelpLibrarySnapshot.validatePackage(files: tampered, digest: self.digest)
        }

        var mismatched = files
        mismatched["content.json"] = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1, "id": HelpBundleMetadata.packageID,
                "version": HelpBundleMetadata.bundledVersion, "kind": "help",
                "helpManifest": HelpBundleMetadata.manifestPath,
                "sourceRevision": "not-a-revision",
                "documents": ["en": "index.md", "zh-Hans": "index.zh-Hans.md"],
            ]
        )
        #expect(throws: HelpLibraryError.self) {
            try HelpLibrarySnapshot.validatePackage(files: mismatched, digest: self.digest)
        }
    }

    @Test("Cross-locale chapter identity mismatch is rejected")
    func crossLocaleMismatch() throws {
        let files = try Self.loadFiles()
        var broken = files
        let indexPath = "help/index/zh-Hans.json"
        let index = try JSONDecoder().decode(HelpIndex.self, from: broken[indexPath] ?? Data())
        var articles = index.articles
        guard let manualIndex = articles.firstIndex(where: { $0.id == "user-manual" }) else {
            Issue.record("user-manual missing")
            return
        }
        var manual = articles[manualIndex]
        manual.sections = manual.sections.filter { $0.id != "section-1" }
        articles[manualIndex] = manual
        let rewritten = try JSONEncoder().encode(HelpIndex(
            locale: index.locale, categories: index.categories, articles: articles
        ))
        broken[indexPath] = rewritten
        broken["help/articles/zh-Hans/user-manual.html"] = Data(
            rewritten + Data("<!--pad-->".utf8) // keep digest distinct from index bytes
        )
        // Rebuild manifest resource digests for the two changed files.
        var manifest = try JSONDecoder().decode(
            HelpPackageManifest.self, from: broken[HelpBundleMetadata.manifestPath] ?? Data()
        )
        manifest.resources = manifest.resources.map { descriptor in
            var descriptor = descriptor
            if let data = broken[descriptor.path] {
                descriptor.byteCount = data.count
                descriptor.sha256 = self.digest(data)
            }
            return descriptor
        }
        broken[HelpBundleMetadata.manifestPath] = try JSONEncoder().encode(manifest)
        #expect(throws: HelpLibraryError.self) {
            try HelpLibrarySnapshot.validatePackage(files: broken, digest: self.digest)
        }
    }
}
