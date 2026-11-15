// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Reviewed constants for the project-side developer hook installer.
public enum GameDeveloperInstrumentationConstants {
    public static let packageName = "FloeGameInstrumentation"
    public static let version = "1.1.0"
    public static let schemaVersion = 1
    public static let licenseIdentifier = "MPL-2.0"

    /// Frozen predevelopment source baseline supplied with this task.
    public static let frozenSourceRevision = "3763b5ce836c0fb7b980b02a2becaa5c6234100f"

    /// The host-owned page object created by GameWebPlayer.enableDeveloperBridge.
    public static let hostObjectName = "FloeDeveloper"

    public static let supportedEngines: [GameEngineID] = [.unity, .godot, .gdevelop, .cocosCreator]

    /// GDevelop source projects are never rewritten. A reviewed bridge file is
    /// installed in the project revision for provenance; the private exported
    /// playable copy is decorated by the exporter and run preparer.
    public static let gdevelopBridgePath = "floe-developer.js"
    public static let gdevelopBridgeResource = "Templates/gdevelop-floe-developer.js"
    public static let gdevelopMaximumProjectJSONBytes = 262_144
    public static let gdevelopMaximumProjectCandidates = 16

    /// Cocos Creator 3.8 project-side component. The scene is edited with a
    /// byte-preserving insertion; every unknown field and component is kept.
    public static let cocosBridgeResource = "Templates/cocos-floe-developer.ts"
    public static let cocosBridgePath = "assets/scripts/FloeDeveloper.ts"
    public static let cocosBridgeMetaPath = "assets/scripts/FloeDeveloper.ts.meta"
    public static let cocosBuildSettingsPath = "floe-cocos-build.json"
    public static let cocosSupportedMajor = 3
    public static let cocosSupportedMinor = 8
    public static let cocosMetaVersion = "4.0.23"
    public static let cocosMaximumScenes = 64
    public static let cocosMaximumSceneBytes = 4 * 1_024 * 1_024
    public static let cocosMaximumMetaBytes = 65_536

    /// Conservative template compatibility floor. This is not a claim that the
    /// host has that Unity toolchain installed.
    public static let unityMinimumMajor = 2019
    public static let unityMinimumMinor = 4

    public static let godotSupportedConfigVersion = 5

    public static let unityJSLibraryPath = "Assets/Plugins/WebGL/FloeDeveloper.jslib"
    public static let unityBridgePath = "Assets/Scripts/FloeDeveloperBridge.cs"
    public static let unityBehaviourPath = "Assets/Scripts/FloeDeveloperBridgeBehaviour.cs"
    public static let godotProjectPath = "project.godot"
    public static let godotAutoloadPath = "floe_developer.gd"
    public static let godotAutoloadKey = "FloeDeveloper"
    public static let godotAutoloadValue = "*res://floe_developer.gd"

    public static let maximumMetadataBytes = 1_048_576
    public static let maximumDependencyScanFiles = 500
    public static let maximumDependencyScanBytes = 8 * 1_048_576
    public static let maximumSourceBundleBytes = 8 * 1_048_576
}
