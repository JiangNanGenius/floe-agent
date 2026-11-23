// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GamePackageFormat: String, Sendable, CaseIterable {
    case zip, installerEXE, appBundle, apk, aab, ipa, xcodeProject
}

/// An honest standalone-target recipe: real engine tool, real configuration,
/// and an explicit label of what the template alone can deliver. An iOS IPA is
/// never claimed installable from a template — that always requires the user's
/// signing pipeline. A native project or a user-editor package is labeled as
/// such, not as a signed installer.
public struct GameNativePackagingRecipe: Equatable, Sendable {
    public let engine: GameEngineID
    public let platform: GameBuildPlatform
    public let configuration: String
    public let format: GamePackageFormat
    public let toolCommand: String
    public let notes: [String]
    public let installableFromTemplate: Bool
}

public enum GameNativePackaging {
    public static func recipes(for engine: GameEngineID) -> [GameNativePackagingRecipe] {
        switch engine {
        case .tyranoScript, .kirikiri, .ons:
            return []
        case .unity:
            return [
                .init(engine: engine, platform: .windows, configuration: "release", format: .installerEXE,
                      toolCommand: "game-ci/unity-builder targetPlatform: StandaloneWindows64",
                      notes: ["Unsigned exe; the user signs/distributes."], installableFromTemplate: true),
                .init(engine: engine, platform: .macOS, configuration: "release", format: .appBundle,
                      toolCommand: "game-ci/unity-builder targetPlatform: StandaloneOSX",
                      notes: ["User signs for Gatekeeper; zip the .app for transport."], installableFromTemplate: true),
                .init(engine: engine, platform: .linux, configuration: "release", format: .zip,
                      toolCommand: "game-ci/unity-builder targetPlatform: StandaloneLinux64",
                      notes: ["Unsigned binary in a zip."], installableFromTemplate: true),
                .init(engine: engine, platform: .ios, configuration: "release", format: .xcodeProject,
                      toolCommand: "game-ci/unity-builder targetPlatform: iOS",
                      notes: ["Produces an Xcode project only. Not installable from a template; requires the user's signing/App Store pipeline."],
                      installableFromTemplate: false),
            ]
        case .godot:
            return [
                .init(engine: engine, platform: .windows, configuration: "release", format: .zip,
                      toolCommand: "godot --headless --path src --export-release \"Windows Desktop\" build/windows/game.exe",
                      notes: ["Unsigned; user signs."], installableFromTemplate: true),
                .init(engine: engine, platform: .macOS, configuration: "release", format: .appBundle,
                      toolCommand: "godot --headless --path src --export-release \"macOS\" build/macos/game.zip",
                      notes: ["Exported .app in zip; user signs for Gatekeeper."], installableFromTemplate: true),
                .init(engine: engine, platform: .linux, configuration: "release", format: .zip,
                      toolCommand: "godot --headless --path src --export-release \"Linux\" build/linux/game.x86_64",
                      notes: ["Unsigned binary in a zip."], installableFromTemplate: true),
                .init(engine: engine, platform: .android, configuration: "release", format: .apk,
                      toolCommand: "godot --headless --path src --export-release \"Android\" build/android/game.apk",
                      notes: ["Unsigned APK/AAB; user signs with their keystore."], installableFromTemplate: true),
            ]
        case .cocosCreator:
            return [
                .init(engine: engine, platform: .web, configuration: "release", format: .zip,
                      toolCommand: "CocosCreator --project src --build \"stage=build;configPath=./floe-cocos-build.json\"",
                      notes: ["Static web bundle playable through WebKit."], installableFromTemplate: true),
                .init(engine: engine, platform: .android, configuration: "release", format: .apk,
                      toolCommand: "CocosCreator --project src --build \"stage=make;configPath=./floe-cocos-android.json\"",
                      notes: ["--build alone produces a native project. Only a successful stage=make/Gradle run produces an unsigned APK; user signs."],
                      installableFromTemplate: true),
            ]
        case .gdevelop:
            return [
                .init(engine: engine, platform: .web, configuration: "release", format: .zip,
                      toolCommand: "GameGDevelopExportPlanner.plan / gdevelop-export.py with the official 5.6.287 SDK",
                      notes: ["Actual official-SDK export; the old manual-editor-only route is retired. 77-file export is byte-bound."],
                      installableFromTemplate: true),
            ]
        case .love:
            return [
                .init(engine: engine, platform: .web, configuration: "release", format: .zip,
                      toolCommand: "GamePortableLoveAdapter / love.js artifact",
                      notes: ["Actual Web adapter; distribution requires the paired source/relink bundle."], installableFromTemplate: true),
                .init(engine: engine, platform: .windows, configuration: "release", format: .installerEXE,
                      toolCommand: "Package the user's .love with the user's official LÖVE runtime",
                      notes: ["User-supplied runtime; Floe does not redistribute it."], installableFromTemplate: false),
            ]
        case .renpy:
            return [
                .init(engine: engine, platform: .web, configuration: "release", format: .zip,
                      toolCommand: "GamePortableRenPyAdapter / renpy-web artifact",
                      notes: ["Actual Web adapter; distribution requires the paired source/relink bundle."], installableFromTemplate: true),
                .init(engine: engine, platform: .windows, configuration: "release", format: .zip,
                      toolCommand: "Ren'Py SDK launcher distribute",
                      notes: ["User-supplied SDK; user distributes under Ren'Py's terms."], installableFromTemplate: false),
                .init(engine: engine, platform: .macOS, configuration: "release", format: .appBundle,
                      toolCommand: "Ren'Py SDK launcher distribute",
                      notes: ["User-supplied SDK and signing choice."], installableFromTemplate: false),
                .init(engine: engine, platform: .linux, configuration: "release", format: .zip,
                      toolCommand: "Ren'Py SDK launcher distribute",
                      notes: ["User-supplied SDK."], installableFromTemplate: false),
            ]
        case .rpgMakerMV:
            return [
                .init(engine: engine, platform: .web, configuration: "release", format: .zip,
                      toolCommand: "GamePortableMVAdapter / official MIT CoreScript Web assembly",
                      notes: ["Actual Web route; existing deployed MV web trees are served unchanged."], installableFromTemplate: true),
                .init(engine: engine, platform: .windows, configuration: "release", format: .installerEXE,
                      toolCommand: "RPG Maker MV editor deployment (user-licensed)",
                      notes: ["User editor/runtime; no NW.js runtime is redistributed."], installableFromTemplate: false),
            ]
        case .rpgMakerMZ, .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            return [
                .init(engine: engine, platform: .windows, configuration: "release", format: .installerEXE,
                      toolCommand: "User-licensed RPG Maker editor deployment / RGSS runtime",
                      notes: ["No RTP, RGSS player, MZ runtime or missing script is redistributed or invented."],
                      installableFromTemplate: false),
            ]
        case .tic80, .microStudio, .wasm4, .ink, .twine:
            return [
                .init(engine: engine, platform: .web, configuration: "release", format: .zip,
                      toolCommand: "Prepared per-engine Web artifact",
                      notes: ["Static Web artifact playable through WebKit; no native installer is invented."],
                      installableFromTemplate: true),
            ]
        case .phaser, .kaplay, .babylon, .playcanvas:
            return [
                .init(engine: engine, platform: .web, configuration: "release", format: .zip,
                      toolCommand: "npm ci && npm run build, or preserve the whole static tree",
                      notes: ["Static web bundle playable through WebKit; no native installer for these script/web engines."],
                      installableFromTemplate: true),
            ]
        }
    }
}
