// SPDX-License-Identifier: MPL-2.0
// App-host check for the single-copy bundled font contract.
//
// The build stages each curated family once in program/resource/common/fonts
// and removes the duplicate font binaries from Bundled/. The native Office host
// also contributes its own OpenSymbol font (opens___.ttf) to that engine
// directory; it is a legitimate host file, not a duplicate of a curated family.
//
// This test runs inside the real App host, calls the production activation
// first, then independently asks CoreText what the process can actually
// resolve. It does not open the native Office engine or claim Office PDF
// export; that remains the Office qualification/device step.

#if canImport(UIKit) && canImport(PDFKit)
import XCTest
import UIKit
import PDFKit
@testable import FloeApp

final class BundledFontRegistrarTests: XCTestCase {
    func testManagementSelectionNeverIncludesBuiltInFonts() {
        let first = FontManagementItemID.design(UUID()), second = FontManagementItemID.imported(String(repeating: "a", count: 64))
        let builtIn = FontManagementItemID.bundled("MiSans")
        var selection = FontManagementSelection()
        selection.toggle(builtIn)
        XCTAssertTrue(selection.items.isEmpty)
        selection.selectAll([first, second, builtIn])
        XCTAssertEqual(selection.items, [first, second])
        selection.toggle(first)
        XCTAssertEqual(selection.items, [second])
        selection.retainAvailable([first, builtIn])
        XCTAssertTrue(selection.items.isEmpty)
        selection.selectAll([first, second]); selection.clear()
        XCTAssertTrue(selection.items.isEmpty)
    }

    func testManagementCatalogListsEveryCuratedFaceOnce() throws {
        let families = BundledFontRegistrar.families(in: Bundle.main.bundleURL)
        let actual = families.flatMap(\.faces).map(\.id)
        let expected = try XCTUnwrap(BundledFontRegistrar.existingFontRoots(in: Bundle.main.bundleURL).first)
        for file in Self.curatedFontFiles {
            for name in CoreTextFontRegistration.declaredPostScriptNames(at: expected.appendingPathComponent(file)) {
                XCTAssertEqual(actual.filter { $0 == name }.count, 1, "Missing or repeated management entry: \(name)")
            }
        }
        XCTAssertGreaterThanOrEqual(families.count, 9)
        XCTAssertGreaterThanOrEqual(actual.count, 23)
        XCTAssertEqual(Set(actual).count, actual.count)
    }

    func testManagementCatalogDeduplicatesTheLegacyFallbackCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-catalog-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = BundledFontRegistrar.fontRoots(in: root)
        for directory in roots { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let original = try XCTUnwrap(BundledFontRegistrar.existingFontRoots(in: Bundle.main.bundleURL).first)
            .appendingPathComponent("MiSans-Regular.ttf")
        for directory in roots {
            try FileManager.default.linkItem(at: original, to: directory.appendingPathComponent("MiSans-Regular.ttf"))
        }
        let families = BundledFontRegistrar.families(in: root)
        XCTAssertEqual(families.flatMap(\.faces).count, CoreTextFontRegistration.declaredPostScriptNames(at: original).count)
    }

    func testManagedDeletionRejectsBundleRootsAndFontSymlinks() async throws {
        let engine = try XCTUnwrap(BundledFontRegistrar.existingFontRoots(in: Bundle.main.bundleURL).first)
        let protectedStore = DeviceFontStore(rootURL: engine)
        do {
            try await protectedStore.remove(id: String(repeating: "a", count: 64))
            XCTFail("An included-font root reached deletion")
        } catch DeviceFontError.protectedFont { }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-delete-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = engine.appendingPathComponent("MiSans-Regular.ttf")
        let before = try Data(contentsOf: source)
        let link = root.appendingPathComponent(String(repeating: "a", count: 64) + ".ttf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let store = DeviceFontStore(rootURL: root)
        let listed = await store.list()
        XCTAssertTrue(listed.isEmpty)
        do {
            try await store.remove(id: String(repeating: "a", count: 64))
            XCTFail("A symlink to an included font reached deletion")
        } catch DeviceFontError.notFound { }
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testRemovingAnImportedDuplicateKeepsTheIncludedFontResolvable() async throws {
        _ = BundledFontRegistrar.activateBundledFonts()
        defer { _ = BundledFontRegistrar.activateBundledFonts() }
        let engine = try XCTUnwrap(BundledFontRegistrar.existingFontRoots(in: Bundle.main.bundleURL).first)
        let included = engine.appendingPathComponent("MiSans-Regular.ttf")
        let originalBytes = try Data(contentsOf: included)
        let names = CoreTextFontRegistration.declaredPostScriptNames(at: included)
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.allSatisfy(CoreTextFontRegistration.resolves(postScriptName:)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-duplicate-delete-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceFontStore(rootURL: root)
        let imported = try await store.importFont(from: included)
        let installed = await store.list()
        XCTAssertEqual(installed.map(\.id), [imported.id])
        try await store.remove(id: imported.id)
        let afterRemoval = await store.list()
        XCTAssertTrue(afterRemoval.isEmpty)
        XCTAssertEqual(try Data(contentsOf: included), originalBytes)
        XCTAssertTrue(names.allSatisfy(CoreTextFontRegistration.resolves(postScriptName:)),
                      "Deleting an added copy unregistered its included counterpart")
    }

    /// The 23 curated files staged from FloeApp/Resources/Fonts/Bundled.
    /// Keep this explicit: a count-only assertion would hide a deleted family
    /// or a newly duplicated copy.
    private static let curatedFontFiles = [
        "AlibabaPuHuiTi-3-55-Regular.ttf",
        "AlibabaPuHuiTi-3-65-Medium.ttf",
        "AlibabaPuHuiTi-3-85-Bold.ttf",
        "HarmonyOS_Sans_SC_Bold.ttf",
        "HarmonyOS_Sans_SC_Medium.ttf",
        "HarmonyOS_Sans_SC_Regular.ttf",
        "LXGWWenKai-Medium.ttf",
        "LXGWWenKai-Regular.ttf",
        "MiSans-Bold.ttf",
        "MiSans-Medium.ttf",
        "MiSans-Regular.ttf",
        "SarasaMonoSC-Bold.ttf",
        "SarasaMonoSC-Regular.ttf",
        "SourceHanSansSC-Bold.otf",
        "SourceHanSansSC-Medium.otf",
        "SourceHanSansSC-Regular.otf",
        "SourceHanSansTC-Bold.otf",
        "SourceHanSansTC-Medium.otf",
        "SourceHanSansTC-Regular.otf",
        "SourceHanSerifSC-Bold.otf",
        "SourceHanSerifSC-Regular.otf",
        "SourceHanSerifTC-Bold.otf",
        "SourceHanSerifTC-Regular.otf",
    ]

    func testCuratedFamiliesResolveOnceAndHostOpenSymbolIsRetained() throws {
        let appRoot = Bundle.main.bundleURL
        let roots = BundledFontRegistrar.existingFontRoots(in: appRoot)
        guard let engineRoot = roots.first else {
            XCTFail("No staged font root in the App host: \(appRoot.path)")
            return
        }
        XCTAssertEqual(engineRoot.lastPathComponent, "fonts")
        XCTAssertTrue(engineRoot.path.hasSuffix("program/resource/common/fonts"),
                      "the engine-scanned root must be the registrar's first root")

        // Activate first; the report below is an independent discovery check,
        // not a byproduct of AppEnvironment having already registered fonts.
        let failures = BundledFontRegistrar.activateBundledFonts()
        XCTAssertTrue(failures.isEmpty, "font activation failures: \(failures)")
        let report = BundledFontRegistrar.discoveryReport(in: engineRoot)

        // Exactly the 23 curated files, plus the pinned Office host's own
        // OpenSymbol font when that host was embedded. A no-Office simulator
        // build legitimately has no opens___.ttf; it must still have exactly
        // the 23 curated files (never a missing family or an extra duplicate).
        let hostFont = engineRoot.appendingPathComponent("opens___.ttf")
        let hostFontPresent = FileManager.default.fileExists(atPath: hostFont.path)
        XCTAssertEqual(report.stagedFiles,
                       Self.curatedFontFiles.count + (hostFontPresent ? 1 : 0),
                       "unexpected engine font set: \(report.unresolvedFiles)")
        XCTAssertEqual(report.resolvedFiles, report.stagedFiles,
                       "unresolved after activation: \(report.unresolvedFiles)")
        XCTAssertTrue(report.unresolvedFiles.isEmpty)
        XCTAssertFalse(Self.curatedFontFiles.contains(hostFont.lastPathComponent))
        if hostFontPresent {
            XCTAssertFalse(CoreTextFontRegistration.declaredPostScriptNames(at: hostFont).isEmpty,
                           "OpenSymbol must remain a parseable host font")
        }

        for name in Self.curatedFontFiles {
            let url = engineRoot.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing curated font: \(name)")
            let declared = CoreTextFontRegistration.declaredPostScriptNames(at: url)
            XCTAssertTrue(declared.contains(where: CoreTextFontRegistration.resolves(postScriptName:)),
                          "curated font does not resolve: \(name)")
        }

        // The packaged App-resource folder keeps only licences/provenance.
        let bundled = appRoot.appendingPathComponent("Bundled", isDirectory: true)
        let bundledFonts = FileManager.default.enumerator(at: bundled, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { ["ttf", "otf", "ttc", "otc"].contains($0.pathExtension.lowercased()) } ?? []
        XCTAssertTrue(bundledFonts.isEmpty,
                      "duplicate font binaries remain in Bundled/: \(bundledFonts.map(\.lastPathComponent))")
        for family in ["source-han-sans-tc", "source-han-serif-tc", "misans", "harmonyos-sans",
                       "source-han-sans-sc", "source-han-serif-sc", "lxgw-wenkai",
                       "sarasa-mono-sc", "alibaba-puhuiti-3"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: bundled.appendingPathComponent(family).appendingPathComponent("LICENSE.txt").path),
                "missing font licence for \(family)")
        }
        // The Traditional Chinese families are the compatibility-critical ones.
        for name in ["SourceHanSansTC-Regular", "SourceHanSansTC-Bold", "SourceHanSerifTC-Regular"] {
            XCTAssertTrue(CoreTextFontRegistration.resolves(postScriptName: name),
                          "Traditional Chinese font does not resolve: \(name)")
        }
    }

    func testTraditionalChineseRendersIntoAppPDF() throws {
        let failures = BundledFontRegistrar.activateBundledFonts()
        XCTAssertTrue(failures.isEmpty, "font activation failures: \(failures)")
        guard let font = UIFont(name: "SourceHanSansTC-Regular", size: 18) else {
            return XCTFail("SourceHanSansTC-Regular is not available to UIKit")
        }
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 200)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("繁體中文測試" as NSString).draw(
                at: CGPoint(x: 24, y: 80),
                withAttributes: [.font: font, .foregroundColor: UIColor.black])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(document.string)
        // PDFKit may map the shared 文 glyph to Kangxi radical U+2F42.
        // Compare its Unicode compatibility form while requiring all six
        // characters, so a missing or substituted glyph still fails.
        let semanticText = text.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(semanticText, "繁體中文測試",
                       "PDF text lost the Traditional Chinese run: \(text)")
    }
}
#endif
