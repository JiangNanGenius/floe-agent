// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

final class GameCIWorkflowTemplateTests: XCTestCase {
    func testAllFiveTemplatesValidateAndCarryProvenance() throws {
        for engine in [GameEngineID.unity, .godot, .cocosCreator, .gdevelop, .phaser] {
            let template = try XCTUnwrap(GameCIWorkflowTemplates.template(for: engine), engine.rawValue)
            XCTAssertFalse(template.actuallyDispatched, "templates are exported, never auto-dispatched")
            XCTAssertNoThrow(try GameCIWorkflowTemplates.validate(template))
            XCTAssertFalse(template.provenance.documentation.isEmpty)
            XCTAssertFalse(template.provenance.actionReferences.isEmpty)
            XCTAssertTrue(template.provenance.actionReferences.allSatisfy { $0.contains("@") || $0.contains(":") })
            XCTAssertTrue(template.yaml.contains("workflow_dispatch"))
            XCTAssertTrue(template.yaml.contains("Write build provenance"))
            if engine == .cocosCreator {
                XCTAssertTrue(template.inputs.contains("build_android"))
                XCTAssertTrue(template.yaml.contains("build_android:"))
            }
            XCTAssertTrue(template.yaml.contains("Verify source digest"))
            // Deterministic: exporting twice yields identical bytes.
            let again = try XCTUnwrap(GameCIWorkflowTemplates.template(for: engine))
            XCTAssertEqual(template.yaml, again.yaml)
        }
    }

    func testUnityTemplateReferencesOnlyDeclaredSecrets() throws {
        let template = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .unity))
        XCTAssertEqual(Set(template.requiredSecrets), ["UNITY_LICENSE", "UNITY_EMAIL", "UNITY_PASSWORD"])
        for secret in ["UNITY_LICENSE", "UNITY_EMAIL", "UNITY_PASSWORD"] {
            XCTAssertTrue(template.yaml.contains("${{ secrets.\(secret) }}"))
        }
    }

    func testValidatorRejectsTamperedTemplates() throws {
        let good = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .godot))
        var bad = good
        bad.yaml = good.yaml.replacingOccurrences(of: "workflow_dispatch", with: "push")
        XCTAssertThrowsError(try GameCIWorkflowTemplates.validate(bad)) { error in
            XCTAssertEqual(error as? GameCIWorkflowError, .missingDispatchTrigger)
        }
        var secretLeak = good
        secretLeak.yaml += "\n      - name: x\n        run: echo \"${{ secrets.NOT_DECLARED }}\"\n"
        XCTAssertThrowsError(try GameCIWorkflowTemplates.validate(secretLeak)) { error in
            XCTAssertEqual(error as? GameCIWorkflowError, .embeddedSecretValue("run: echo \"${{ secrets.NOT_DECLARED }}\""))
        }
        var noDigest = good
        noDigest.yaml = good.yaml.replacingOccurrences(of: "Verify source digest", with: "Skip digest")
        XCTAssertThrowsError(try GameCIWorkflowTemplates.validate(noDigest)) { error in
            XCTAssertEqual(error as? GameCIWorkflowError, .missingDigestVerification)
        }
    }
}

extension GameCIWorkflowTemplateTests {
    func testAllGeneratedTemplatesDeclareAnExplicitSourceTransportAndPinnedActions() throws {
        let templates = try GameCIWorkflowTemplates.all()
        XCTAssertEqual(templates.count, 7)
        for template in templates {
            XCTAssertFalse(template.actuallyDispatched)
            XCTAssertFalse(template.sourceTransportKinds.isEmpty, template.id)
            XCTAssertTrue(template.yaml.contains("source_commit"), template.id)
            XCTAssertTrue(template.yaml.contains("source_run_id"), template.id)
            XCTAssertTrue(template.yaml.contains("source_artifact_name"), template.id)
            XCTAssertTrue(template.yaml.contains("Verify source digest"), template.id)
            XCTAssertTrue(template.yaml.contains("Write build provenance"), template.id)
            XCTAssertTrue(template.yaml.contains("floe-source-provenance"), template.id)
            XCTAssertTrue(template.yaml.contains("floe-build-provenance"), template.id)
            XCTAssertFalse(template.yaml.contains("cp index.html"), template.id)
            for reference in template.provenance.actionReferences {
                XCTAssertTrue(GameCIWorkflowTemplates.isPinned(reference), "\(template.id): \(reference)")
            }
        }
    }


    func testEveryTemplateResolvesAndVerifiesTheSelectedGameRoot() throws {
        for template in try GameCIWorkflowTemplates.all() {
            XCTAssertTrue(template.inputs.contains("game_root"), template.id)
            XCTAssertTrue(template.inputs.contains("selected_source_sha256"), template.id)
            XCTAssertTrue(template.yaml.contains("Resolve selected game root"), template.id)
            XCTAssertTrue(template.yaml.contains("Materialize selected game source"), template.id)
            XCTAssertTrue(template.yaml.contains("FLOE_GAME_ROOT"), template.id)
            XCTAssertTrue(template.yaml.contains("selectedSourceSHA256"), template.id)
            XCTAssertTrue(template.yaml.contains("FLOE_SELECTED_SOURCE_SHA256"), template.id)
            XCTAssertTrue(template.yaml.contains("selected-src"), template.id)
            // The whole project stays at src; only the selected subtree is the
            // build cwd. A download path is never narrowed.
            XCTAssertTrue(template.yaml.contains("path: src"), template.id)
            // The template must not silently upgrade an unverified root.
            XCTAssertTrue(template.yaml.contains("selected source digest does not match selected_source_sha256"),
                          template.id)
            XCTAssertTrue(template.yaml.contains("game_root must not start or end with '/'"), template.id)
        }
    }

    func testEveryTemplateRecordsSelectionSchemaAndHonestProjectRootCompatibility() throws {
        for template in try GameCIWorkflowTemplates.all() {
            XCTAssertTrue(template.yaml.contains("\\\"selectionSchemaVersion\\\": source.get(\\\"selectionSchemaVersion\\\", 0)"),
                          template.id)
            XCTAssertTrue(template.yaml.contains("\\\"gameRoot\\\": source.get(\\\"gameRoot\\\", \\\"\\\")"), template.id)
            XCTAssertTrue(template.yaml.contains("\\\"selectedSourceSHA256\\\": source.get(\\\"selectedSourceSHA256\\\", \\\"\\\")"),
                          template.id)
            XCTAssertTrue(template.yaml.contains("if raw and actual != expected"), template.id)
            XCTAssertFalse(template.yaml.contains("cp index.html"), template.id)
        }
    }

    func testIOSAndCocosTemplatesDoNotClaimInstallersTheyCannotProduce() throws {
        let unity = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .unity))
        XCTAssertTrue(unity.yaml.contains("unity-ios-xcodeproj.zip"))
        XCTAssertTrue(unity.yaml.contains("not an IPA"))
        XCTAssertFalse(unity.yaml.lowercased().contains(".ipa"))
        let cocos = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .cocosCreator))
        XCTAssertTrue(cocos.yaml.contains("stage=make"))
        XCTAssertTrue(cocos.yaml.contains("AndroidManifest.xml"))
        XCTAssertFalse(cocos.yaml.contains("--build \"platform=android"))
    }
}

extension GameCIWorkflowTemplateTests {
    func testUnityWebOnlySelectionDoesNotRequireDesktopTargets() throws {
        let unity = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .unity))
        let selection = try unity.selection(forRequestedArtifacts: ["unity-web.zip"],
                                            inputs: ["artifact_prefix": "unity"])
        XCTAssertEqual(selection.targetIDSet, Set(["web"]))
        XCTAssertEqual(selection.artifactSet, Set(["unity-web.zip"]))
        XCTAssertFalse(selection.artifactSet.contains("unity-windows.zip"))
        XCTAssertFalse(selection.artifactSet.contains("unity-macos.zip"))
        XCTAssertFalse(selection.artifactSet.contains("unity-ios-xcodeproj.zip"))
        let defaults = try unity.defaultSelection(inputs: ["artifact_prefix": "unity"])
        XCTAssertEqual(defaults.targetIDSet, Set(["web", "windows", "macos", "ios"]))
    }

    func testUnsupportedTargetArtifactsAreRejected() throws {
        let unity = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .unity))
        XCTAssertThrowsError(try unity.selection(forRequestedArtifacts: ["unity-android.apk"],
                                                 inputs: ["artifact_prefix": "unity"])) { error in
            XCTAssertEqual(error as? GameCIWorkflowError, .unsupportedTarget("unity-android.apk"))
        }
        let cocos = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .cocosCreator))
        XCTAssertThrowsError(try cocos.selection(forRequestedArtifacts: Set<String>(),
                                                 inputs: ["artifact_prefix": "cocos"])) { error in
            XCTAssertEqual(error as? GameCIWorkflowError, .missingRequestedTarget)
        }
    }

    func testCocosAndroidTargetIsAtomicProjectAndAPK() throws {
        let cocos = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .cocosCreator))
        let apkOnly = try cocos.selection(forRequestedArtifacts: ["cocos-android.apk"],
                                          inputs: ["artifact_prefix": "cocos"])
        XCTAssertEqual(apkOnly.targetIDSet, Set(["android"]))
        XCTAssertEqual(apkOnly.artifactSet,
                       Set(["cocos-android-project.zip", "cocos-android.apk"]))
        let projectOnly = try cocos.selection(forRequestedArtifacts: ["cocos-android-project.zip"],
                                              inputs: ["artifact_prefix": "cocos"])
        XCTAssertEqual(projectOnly.targetIDSet, Set(["android"]))
        XCTAssertEqual(projectOnly.artifactSet,
                       Set(["cocos-android-project.zip", "cocos-android.apk"]))
    }

    func testCocosTemplateUsesSupportedMacRunnerAndSameWorkspaceMake() throws {
        let cocos = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .cocosCreator))
        XCTAssertTrue(cocos.inputs.contains("targets"))
        XCTAssertTrue(cocos.inputs.contains("cocos_runner"))
        XCTAssertTrue(cocos.inputs.contains("cocos_sdk_mode"))
        XCTAssertFalse(cocos.yaml.lowercased().contains("xvfb"))
        XCTAssertTrue(cocos.yaml.contains("GUI-capable macOS runner"))
        XCTAssertTrue(cocos.yaml.contains("platform.system()"))
        XCTAssertTrue(cocos.yaml.contains("Darwin"))
        XCTAssertTrue(cocos.yaml.contains("runs-on: ${{ inputs.cocos_runner }}"))
        XCTAssertTrue(cocos.yaml.contains("stage=make"))
        XCTAssertTrue(cocos.yaml.contains("-ne 36"))
        XCTAssertFalse(cocos.yaml.contains("always enabled"))
        let start = try XCTUnwrap(cocos.yaml.range(of: "\n  android:"))
        let end = try XCTUnwrap(cocos.yaml.range(of: "\n  provenance:",
                                                 range: start.upperBound..<cocos.yaml.endIndex))
        let androidJob = String(cocos.yaml[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(androidJob.contains("stage=build;configPath=./floe-cocos-android.json"))
        XCTAssertTrue(androidJob.contains("stage=make;configPath=./floe-cocos-android.json"))
        XCTAssertTrue(androidJob.contains("test -d selected-src/build/android/proj"))
        XCTAssertTrue(androidJob.contains("Upload cocos-android-project.zip"))
        XCTAssertTrue(androidJob.contains("Upload cocos-android.apk"))
        XCTAssertEqual(androidJob.components(separatedBy: "Download verified source").count - 1, 1,
                       "the android target must build and make in one workspace from one source download")
    }

    func testEveryTemplateGatesBuildJobsOnTheResolvedTargets() throws {
        let templates = try GameCIWorkflowTemplates.all()
        XCTAssertEqual(templates.count, 7)
        for template in templates {
            XCTAssertFalse(template.targets.isEmpty, template.id)
            XCTAssertFalse(template.defaultTargetIDs.isEmpty, template.id)
            XCTAssertTrue(template.yaml.contains("Resolve and validate requested targets"), template.id)
            XCTAssertTrue(template.yaml.contains("needs.prepare.outputs.targets"), template.id)
            for target in template.targets {
                XCTAssertTrue(template.yaml.contains("\n  \(target.job):"), "\(template.id): \(target.job)")
                XCTAssertTrue(template.yaml.contains(
                    "contains(format(',{0},', needs.prepare.outputs.targets), ',\(target.id),')"),
                    "\(template.id): missing condition for \(target.id)")
            }
        }
    }

    func testRunStepsUseEnvironmentValuesNotDirectInputs() throws {
        for template in try GameCIWorkflowTemplates.all() {
            for line in template.yaml.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("run:") {
                    XCTAssertFalse(trimmed.contains("${{ inputs."),
                                   "\(template.id): run step interpolates a free-form input: \(trimmed.prefix(120))")
                }
            }
        }
        let script = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .phaser))
        XCTAssertTrue(script.yaml.contains("$FLOE_ARTIFACT_PREFIX-web.zip"))
        XCTAssertFalse(script.yaml.contains("test -s \"${{ inputs.artifact_prefix }}"))
        let wasm = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .wasm4))
        XCTAssertTrue(wasm.yaml.contains("--title \"$FLOE_ENGINE_VERSION\""))
        XCTAssertFalse(wasm.yaml.contains("--title \"${{ inputs.engine_version }}\""))
    }
}
