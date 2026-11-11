// SPDX-License-Identifier: MPL-2.0
// Focused qualification host for the offline help library.
//
// This harness directly compiles the real production Core files
// (HelpContracts.swift + HelpLibrary.swift) together with this driver and
// exercises format, search, reference, read and resource boundaries against
// the real generated built-in package. The digest seam uses CryptoKit's
// SHA-256 on macOS — the same algorithm production injects through
// FloeDigest.sha256Hex. It never stubs product types.
//
// Run through FloeAgent/Qualification/HelpCore/run_help_core_qualification.sh.

import Foundation
import CryptoKit

private let packageRoot: URL = {
    // The build script exports HELP_CORE_PACKAGE_ROOT.
    let raw = ProcessInfo.processInfo.environment["HELP_CORE_PACKAGE_ROOT"] ?? ""
    precondition(!raw.isEmpty, "HELP_CORE_PACKAGE_ROOT not set")
    return URL(fileURLWithPath: raw)
}()

private let digest: @Sendable (Data) -> String = { data in
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private var failures = 0
private var checks = 0

@MainActor
private func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    checks += 1
    if condition {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail)")
    }
}

@MainActor
private func expectError<T>(_ name: String, _ block: () throws -> T) {
    checks += 1
    do {
        _ = try block()
        failures += 1
        print("FAIL \(name) expected error, got success")
    } catch {
        print("PASS \(name) -> \(type(of: error))")
    }
}

do {
    print("HelpCore qualification: package \(packageRoot.path)")
    var files: [String: Data] = [:]
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(
        at: packageRoot, includingPropertiesForKeys: [.isRegularFileKey]
    ) else { throw HelpLibraryError.missingFile("package root") }
    for case let url as URL in enumerator {
        if url.hasDirectoryPath { continue }
        let relative = String(url.path.dropFirst(packageRoot.path.count + 1))
        files[relative] = try Data(contentsOf: url)
    }
    print("loaded \(files.count) package files, \(files.values.map(\.count).reduce(0,+)) bytes")

    // MARK: Validation

    try HelpLibrarySnapshot.validatePackage(files: files, digest: digest)
    check(true, "validatePackage real built-in")

    let english = try HelpLibrarySnapshot(files: files, language: .english, digest: digest)
    let chinese = try HelpLibrarySnapshot(files: files, language: .simplifiedChinese, digest: digest)
    check(english.manifest.version == HelpBundleMetadata.bundledVersion, "manifest version")
    check(english.index.articles.count == 6, "six articles", "\(english.index.articles.count)")
    check(english.index.categories.count == 7, "seven categories")
    check(Set(english.index.articles.map(\.id)) == Set(chinese.index.articles.map(\.id)),
          "cross-locale article identity")

    // MARK: Identifiers

    let pattern = #"^[a-z0-9]+([.-][a-z0-9]+)*$"#
    var identifiersOK = true
    for article in english.index.articles {
        if article.id.range(of: pattern, options: .regularExpression) == nil { identifiersOK = false }
        var seen = Set<String>()
        for section in article.sections where !seen.insert(section.id).inserted {
            identifiersOK = false
        }
    }
    check(identifiersOK, "identifier grammar + uniqueness")

    // MARK: References

    let manual = try english.reference(articleID: "user-manual", sectionID: "section-7")
    check(manual.version == HelpBundleMetadata.bundledVersion, "reference carries package version")
    expectError("reference unknown article") { try english.reference(articleID: "missing") }
    expectError("reference unknown section") {
        try english.reference(articleID: "user-manual", sectionID: "missing")
    }

    // MARK: Search (real corpus)

    let pencil = english.search("Apple Pencil")
    check(pencil.contains { $0.reference.articleID == "user-manual"
        && $0.reference.sectionID == "section-7" }, "search 'Apple Pencil' -> notes section")
    check(english.search("keyboard").contains { $0.reference.articleID == "input.keyboard" },
          "search 'keyboard' -> input.keyboard")
    check(english.search("voice output").contains { $0.reference.articleID == "voice.output" },
          "search 'voice output' -> voice.output")
    check(english.search("Linux memory").contains { $0.reference.articleID == "environment.memory" },
          "search 'Linux memory' -> environment.memory")
    check(chinese.search("手记").contains { $0.reference.sectionID == "section-7" },
          "search '手记' -> notes section")
    check(chinese.search("临时会话").contains { $0.reference.sectionID == "section-19" },
          "search '临时会话' -> temporary chat")
    check(chinese.search("内存").contains { $0.reference.articleID == "environment.memory" },
          "search '内存' -> environment.memory")
    check(english.search("").isEmpty, "empty query empty")
    check(english.search("zzzz-absent-qqqq").isEmpty, "no-match query empty")
    check(english.search("notes", limit: 2).count <= 2, "limit respected")
    check(english.search("Apple Pencil").first?.reference.sectionID == "section-7",
          "alias whole-query outranks scattered hits")

    // MARK: Read + pagination

    let readRef = try english.reference(articleID: "user-manual", sectionID: "section-15")
    var offset = 0
    var pages = 0
    var assembled = ""
    var truncatedOK = false
    while true {
        let page = try english.read(readRef, offset: offset, maximumCharacters: 400)
        if page.text.count > 400 { check(false, "page bound", "\(page.text.count)") }
        assembled += page.text
        pages += 1
        if pages > 100 { check(false, "pagination terminates"); break }
        guard let next = page.nextOffset else { break }
        truncatedOK = true
        offset = next
    }
    check(truncatedOK, "section pagination truncates and continues")
    check(assembled.contains("Canvas"), "assembled section text")
    check(pages >= 2, "multiple pages", "\(pages)")

    let howto = try chinese.read(try chinese.reference(articleID: "environment.memory"))
    check(howto.settingIDs == ["execution.memory"], "howto setting id")
    check(howto.text.contains("共享运行环境"), "howto localized path")

    expectError("read version mismatch") {
        try english.read(HelpReference(version: "0.0.1", language: .english,
                                       articleID: "quickstart", sectionID: nil))
    }
    expectError("read package mismatch") {
        try english.read(HelpReference(packageID: "floe.help.other",
                                       version: HelpBundleMetadata.bundledVersion,
                                       language: .english, articleID: "quickstart", sectionID: nil))
    }
    expectError("read offset out of range") {
        try english.read(readRef, offset: assembled.count + 5)
    }

    // MARK: Resources

    let home = try english.resource(at: "help/assets/guide/home-current.webp")
    check(home.mimeType == "image/webp", "image mime")
    check(home.data.count > 100_000 && home.data.count <= HelpBundleMetadata.maximumFileBytes,
          "image bounded", "\(home.data.count)")
    let css = try english.resource(at: "help/styles/help.css")
    check(css.mimeType.hasPrefix("text/css"), "css mime")
    expectError("resource missing") { try english.resource(at: "help/assets/none.webp") }
    expectError("resource traversal") { try english.resource(at: "../content.json") }
    expectError("resource absolute") { try english.resource(at: "/etc/passwd") }

    // MARK: Negative packages

    var missing = files; missing["help/index/en.json"] = nil
    expectError("validate missing index") {
        try HelpLibrarySnapshot.validatePackage(files: missing, digest: digest)
    }

    var oversized = files
    oversized["help/articles/en/quickstart.html"] = Data(
        repeating: 0x61, count: HelpBundleMetadata.maximumFileBytes + 1)
    expectError("validate oversized file") {
        try HelpLibrarySnapshot.validatePackage(files: oversized, digest: digest)
    }

    var malformed = files
    malformed["help/index/en.json"] = Data("nope".utf8)
    expectError("validate malformed index") {
        try HelpLibrarySnapshot.validatePackage(files: malformed, digest: digest)
    }

    var unlisted = files
    unlisted["help/extra.txt"] = Data("x".utf8)
    expectError("validate unlisted file") {
        try HelpLibrarySnapshot.validatePackage(files: unlisted, digest: digest)
    }

    var tampered = files
    let imagePath = "help/assets/guide/home-current.webp"
    var bytes = tampered[imagePath] ?? Data()
    bytes[0] = bytes[0] ^ 0xFF
    tampered[imagePath] = bytes
    expectError("validate digest mismatch") {
        try HelpLibrarySnapshot.validatePackage(files: tampered, digest: digest)
    }
    expectError("resource digest mismatch at read time") {
        let snapshot = try HelpLibrarySnapshot(files: tampered, language: .english, digest: digest)
        return try snapshot.resource(at: imagePath)
    }

    var badRevision = files
    var contentObject = try JSONSerialization.jsonObject(
        with: files["content.json"] ?? Data()) as? [String: Any] ?? [:]
    contentObject["sourceRevision"] = "NOTHEX"
    badRevision["content.json"] = try JSONSerialization.data(withJSONObject: contentObject)
    expectError("validate bad sourceRevision") {
        try HelpLibrarySnapshot.validatePackage(files: badRevision, digest: digest)
    }

    // Cross-locale chapter identity: rewrite zh index without section-1.
    var crossBroken = files
    let zhPath = "help/index/zh-Hans.json"
    let zhIndex = try JSONDecoder().decode(HelpIndex.self, from: crossBroken[zhPath] ?? Data())
    var articles = zhIndex.articles
    if let index = articles.firstIndex(where: { $0.id == "user-manual" }) {
        var manual = articles[index]
        manual.sections = manual.sections.filter { $0.id != "section-1" }
        articles[index] = manual
    }
    let rewrittenIndex = try JSONEncoder().encode(HelpIndex(
        locale: zhIndex.locale, categories: zhIndex.categories, articles: articles))
    crossBroken[zhPath] = rewrittenIndex
    var manifest = try JSONDecoder().decode(
        HelpPackageManifest.self, from: crossBroken[HelpBundleMetadata.manifestPath] ?? Data())
    manifest.resources = manifest.resources.map { descriptor in
        var descriptor = descriptor
        if let data = crossBroken[descriptor.path] {
            descriptor.byteCount = data.count
            descriptor.sha256 = digest(data)
        }
        return descriptor
    }
    crossBroken[HelpBundleMetadata.manifestPath] = try JSONEncoder().encode(manifest)
    expectError("validate cross-locale chapter mismatch") {
        try HelpLibrarySnapshot.validatePackage(files: crossBroken, digest: digest)
    }

    print("RESULT checks=\(checks) failures=\(failures)")
    exit(failures == 0 ? 0 : 1)
} catch {
    print("QUALIFICATION ERROR: \(error)")
    exit(2)
}
