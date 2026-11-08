// SPDX-License-Identifier: MPL-2.0
//
// N07-platform-guides67 (job-21d5d72113e9417f): regression source for the
// app-bundled Android guides. Authored, NOT executed by this package; the
// primary owner runs the suite during grouped qualification.
//
// These tests pin the model-facing contract of `AndroidBundledSkillGuides`:
//  * every bundled guide is registry-true — never references an iOS-only
//    editor alias or retired runtime name, and never makes the Linux
//    graphical desktop a prerequisite;
//  * seeded packages validate through the ORIGINAL SkillPackageValidator
//    and decode as the Android guidance-only manifest;
//  * required tool names stay inside the Android registry root set.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeSkills
import FloePersistence

final class AndroidBundledSkillGuidesTests: XCTestCase {

    /// iOS-only editor aliases and retired runtime names that must never
    /// appear in an Android-bundled guide (substring scan keeps this honest
    /// for both prose and embedded recipe code).
    let forbiddenReferences = [
        "document.pdf.", "document.createWord", "document.createWorkbook",
        "document.readSheet", "document.presentation.", "document.office.inspect",
        "document.office.updateText", "document.convert",
        "apple.", "vnc.", "ssh.execute", "ssh.shellOpen", "ssh.taskStatus",
        "remote.connection", "cloudWorkspace.", "remoteHosting.", "bluetooth.serial",
        "credential.manage", "crypto.cipher", "canvas.", "image.process",
        "image.svgDocument", "image.inspect", "image.ocr", "image.barcode",
        "image.qr.", "video.inspect", "video.transcode", "video.remux", "audio.",
        "exec.localPython", "exec.javascript", "exec.compatEvaluator", "exec.wasm",
        "python.packages", "design.", "cad.", "PDFKit", "CoreText", " Vision ",
        "Keychain", "UIKit",
    ]

    /// Roots the Android registry can actually register today (the static
    /// tool inventory of the shared modules). requiredToolNames must stay
    /// inside this set; the runtime intersects again at activation.
    let androidRegistryRoots: Set<String> = [
        "exec", "shell", "jobs", "workspace", "git", "github",
        "network", "web", "browser", "document", "image", "video", "media",
        "preview", "memory", "conversation", "checklist", "calendar", "contacts",
        "todo", "mail", "font", "device", "nfc", "location", "health",
        "task", "user", "delegate", "tools", "skill", "ssh", "bluetooth",
    ]

    func testGuideSetIsNonEmptyAndIdentityStable() throws {
        XCTAssertFalse(AndroidBundledSkillGuides.all.isEmpty)
        let ids = AndroidBundledSkillGuides.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "bundled guide ids must be unique")
        // The four hub-visible guides keep their historical identities.
        for id in ["floe-pdf", "floe-office", "floe-network", "floe-video"] {
            let definition = try XCTUnwrap(AndroidBundledSkillGuides.definition(id: id))
            XCTAssertTrue(definition.exposed, "\(id) stays hub-visible")
        }
        // iOS-only domains are never bundled on Android.
        XCTAssertNil(AndroidBundledSkillGuides.definition(id: "floe-apple"))
        XCTAssertNil(AndroidBundledSkillGuides.definition(id: "floe-remote"))
        XCTAssertNil(AndroidBundledSkillGuides.definition(id: "floe-design"))
    }

    func testGuidesNeverReferenceIosOnlyToolsOrDesktopPrerequisites() throws {
        for definition in AndroidBundledSkillGuides.all {
            for forbidden in forbiddenReferences {
                XCTAssertFalse(definition.markdown.contains(forbidden),
                               "\(definition.id) must not reference \(forbidden)")
                XCTAssertFalse(definition.description.contains(forbidden),
                               "\(definition.id) description must not reference \(forbidden)")
            }
            // No mandatory-desktop language anywhere in model-facing text.
            XCTAssertFalse(definition.markdown.lowercased().contains("start the desktop"),
                           "\(definition.id) must not make a desktop a prerequisite")
        }
    }

    func testGuideVersionsAreCanonicalSemver() throws {
        for definition in AndroidBundledSkillGuides.all {
            XCTAssertNoThrow(try SignedContentVersion(definition.version),
                             "\(definition.id) version must parse as canonical x.y.z")
        }
    }

    func testSeedManifestIsGuidanceOnlyAndroidIdentity() throws {
        for definition in AndroidBundledSkillGuides.all {
            let manifest = AndroidBundledSkillGuides.seedManifest(
                id: definition.id, version: definition.version)
            XCTAssertEqual(manifest["schemaVersion"] as? Int, 1)
            XCTAssertEqual(manifest["id"] as? String, definition.id)
            XCTAssertEqual(manifest["version"] as? String, definition.version)
            XCTAssertEqual(manifest["capabilities"] as? [String], [])
            XCTAssertEqual(manifest["tools"] as? [String], [])
            XCTAssertEqual(manifest["platforms"] as? [String], ["android"])
            XCTAssertEqual(manifest["scriptRuntime"] as? String, "none")
            XCTAssertEqual((manifest["pythonPackages"] as? [Any])?.isEmpty, true)
        }
    }

    func testSeedPackagesValidateThroughOriginalValidator() throws {
        let validator = SkillPackageValidator()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-android-guides-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for definition in AndroidBundledSkillGuides.all {
            let packageRoot = root.appendingPathComponent(definition.id)
            try FileManager.default.createDirectory(at: packageRoot,
                                                    withIntermediateDirectories: true)
            for (name, data) in AndroidBundledSkillGuides.seedPackageFiles(definition) {
                try data.write(to: packageRoot.appendingPathComponent(name))
            }
            let package = try validator.validate(packageAt: packageRoot)
            XCTAssertEqual(package.manifest.id, definition.id)
            XCTAssertEqual(package.manifest.version, definition.version)
            XCTAssertEqual(package.manifest.platforms, ["android"])
            XCTAssertEqual(package.manifest.scriptRuntime, .none)
            XCTAssertEqual(package.metadata.name, definition.id,
                           "frontmatter name is the stable identity")
            XCTAssertFalse(package.metadata.instructions.isEmpty)
        }
    }

    func testRequiredToolNamesStayInsideAndroidRegistry() throws {
        for definition in AndroidBundledSkillGuides.all {
            for name in definition.automaticallyLoadedToolNames {
                let root = String(name.split(separator: ".").first ?? "")
                XCTAssertTrue(androidRegistryRoots.contains(root),
                              "\(definition.id) activates unknown root \(root) (\(name))")
            }
        }
        // The PDF guide exposes the real task-Linux path and nothing else.
        let pdf = try XCTUnwrap(AndroidBundledSkillGuides.definition(id: "floe-pdf"))
        XCTAssertTrue(pdf.automaticallyLoadedToolNames.contains("exec.shell"))
        XCTAssertFalse(pdf.automaticallyLoadedToolNames.contains { $0.hasPrefix("document.pdf.") })
        // Recipe guides never scrape code for dotted names.
        for id in ["floe-image-edit", "floe-svg", "floe-text-edit"] {
            let definition = try XCTUnwrap(AndroidBundledSkillGuides.definition(id: id))
            XCTAssertFalse(definition.automaticallyLoadedToolNames.contains { $0.hasPrefix("image.save") },
                           "\(id) must not scrape recipe code for tool names")
        }
    }

    func testBundledSourceIdentityScoping() throws {
        // Only floe-builtin:// rows are augmented by bundled definitions.
        var row = PersistedSkill(
            id: "floe-pdf", name: "floe-pdf", version: "1.0.0", status: "enabled",
            skillMarkdown: "# x", manifestJSON: "{}",
            rewrittenDigest: String(repeating: "a", count: 64))
        row.sourceURL = nil
        XCTAssertNil(SkillsDomain.bundledDefinition(for: row),
                     "a source-less row is not bundled-owned")
        row.sourceURL = "https://github.com/example/guide"
        XCTAssertNil(SkillsDomain.bundledDefinition(for: row),
                     "a hub/community row is not bundled-owned")
        row.sourceURL = AndroidBundledSkillGuides.sourceURL(for: "floe-pdf")
        XCTAssertEqual(SkillsDomain.bundledDefinition(for: row)?.id, "floe-pdf",
                       "an app-bundled row resolves the Android definition")
    }

    func testBundledVersionComparison() {
        XCTAssertTrue(SkillsDomain.isBundledVersion("1.10.0", newerThan: "1.4.0"))
        XCTAssertTrue(SkillsDomain.isBundledVersion("2.0.0", newerThan: "1.9.9"))
        XCTAssertFalse(SkillsDomain.isBundledVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(SkillsDomain.isBundledVersion("1.4.0", newerThan: "1.10.0"))
        XCTAssertFalse(SkillsDomain.isBundledVersion("1.0", newerThan: "1.0.0"),
                      "non-canonical versions never upgrade")
    }
}
