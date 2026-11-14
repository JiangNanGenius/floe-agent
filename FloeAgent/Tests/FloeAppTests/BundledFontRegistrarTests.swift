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
