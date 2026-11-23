// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameDeveloperCore

public enum GameDeveloperProjectHookAvailability: String, Codable, Sendable {
    /// This package installs the reviewed project-side hook (Unity, Godot).
    case installerAvailable
    /// The existing host bundle already reads real engine globals.
    case runtimeHookPresent
    /// An existing Floe project bridge/runtime handles the engine.
    case projectBridgePresent
    /// Only an existing snapshot/restore path is exposed.
    case snapshotOnly
    /// The catalog requires a host build, but no automated project installer exists.
    case projectInstallerMissing
    /// The existing RGSS guest/file-RPC route owns the overlay.
    case guestRuntimeBridge
}

public struct GameDeveloperInstrumentationAudit: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let engine: GameEngineID
        public let displayName: String
        public let support: GameDeveloperEngineSupport
        public let route: GameDeveloperEngineRoute
        public let availability: GameDeveloperProjectHookAvailability
        public let gap: String
        public let gapZhHans: String

        public var id: String { engine.rawValue }
        public var hasAutomatedInstaller: Bool { availability == .installerAvailable }
    }

    public let schemaVersion: Int
    public let catalogVersion: String
    public let installerEngines: [GameEngineID]
    public let entries: [Entry]

    /// Read-only audit of all 20 catalog entries. It never inspects project bytes.
    public static func current() throws -> GameDeveloperInstrumentationAudit {
        let descriptors = try GameDeveloperEngineCatalog.validated()
        var entries: [Entry] = []
        for engine in GameEngineID.authoringEngines {
            guard let descriptor = descriptors.first(where: { $0.engine == engine }) else {
                throw GameDeveloperInstrumentationError.catalogMismatch(
                    engine, "catalog has no descriptor")
            }
            let text = gap(for: engine)
            entries.append(.init(
                engine: engine,
                displayName: descriptor.displayName,
                support: descriptor.support,
                route: descriptor.route,
                availability: availability(for: engine),
                gap: text.english,
                gapZhHans: text.chinese))
        }
        return .init(schemaVersion: GameDeveloperInstrumentationConstants.schemaVersion,
                     catalogVersion: GameDeveloperEngineCatalog.version,
                     installerEngines: GameDeveloperInstrumentationConstants.supportedEngines,
                     entries: entries)
    }

    public static func availability(for engine: GameEngineID) -> GameDeveloperProjectHookAvailability {
        switch engine {
        case .unity, .godot, .gdevelop, .cocosCreator:
            return .installerAvailable
        case .rpgMakerMZ, .tyranoScript, .kirikiri, .ons:
            return .projectInstallerMissing
        case .tic80:
            return .snapshotOnly
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            return .guestRuntimeBridge
        case .rpgMakerMV, .love, .renpy, .microStudio, .wasm4:
            return .projectBridgePresent
        case .phaser, .kaplay, .babylon, .playcanvas, .ink, .twine:
            return .runtimeHookPresent
        }
    }

    private static func gap(for engine: GameEngineID) -> (english: String, chinese: String) {
        switch engine {
        case .unity:
            return ("Automated installer available. The reviewed bridge exposes scene, frame counter, time scale and pause/resume only; a WebGL rebuild is still required, and arbitrary C# values need explicit project source changes.",
                    "已提供自动安装器。审核过的桥只提供场景、帧数、时间缩放和暂停/恢复；仍需重新构建 WebGL，任意 C# 数值需要显式修改工程源码。")
        case .godot:
            return ("Automated installer available. The reviewed autoload exposes scene, frame counter, time scale and pause/resume only; a Web export rebuild is still required, and named project values need explicit GDScript registration.",
                    "已提供自动安装器。审核过的自动加载只提供场景、帧数、时间缩放和暂停/恢复；仍需重新构建网页导出，具名工程数值需要显式 GDScript 登记。")
        case .rpgMakerMZ:
            return ("The licensed MZ Web runtime and the optional js/plugins registration remain host/user supplied; no automated project installer exists.",
                    "授权的 MZ 网页运行时和可选的 js/plugins 登记仍由宿主/用户提供；没有自动工程安装器。")
        case .tyranoScript:
            return ("Plays the imported browser export with game-managed saves.",
                    "播放导入的网页版作品，并通过游戏内菜单管理存档。")
        case .kirikiri:
            return ("KiriKiri manages its own saves in the native player.", "吉里吉里在原生播放器内管理存档。")
        case .ons:
            return ("ONScripter games can be identified and opened as project files.", "可识别并打开 ONScripter 工程文件。")
        case .gdevelop:
            return ("Automated installer available. It records the exact bridge in the project and never rewrites game.json; the exporter/run preparer stamps the same reviewed bytes into the private playable copy. An already-exported playable game needs no re-export. Live fields cover scene, time scale, elapsed time, declared primitive variables and first-scene object positions; unavailable shapes fail honestly.",
                    "已提供自动安装器。它只在工程中记录精确桥文件，绝不改写 game.json；导出器/运行准备器把同样的审核字节写入私有试玩副本。已导出的可玩游戏无需再导出。实时字段覆盖场景、时间缩放、运行时间、已声明原始变量和首场景对象位置；不支持的结构会明确失败。")
        case .cocosCreator:
            return ("Automated installer available for Creator 3.8. It creates the typed component and exact .meta UUID and attaches it to one explicit scene (startScene metadata, the only scene, or the UI/AI scene argument). A Web rebuild is required; unknown scene fields/components are preserved and a same-name user script is never overwritten.",
                    "已提供 Creator 3.8 自动安装器。它创建类型化组件和精确 .meta UUID，并挂接到一个显式场景（startScene 元数据、唯一场景或 UI/AI 场景参数）。需要重新构建网页版；保留未知场景字段/组件，绝不覆盖同名用户脚本。")
        case .rpgMakerMV:
            return ("The existing bridge reads real MV CoreScript globals. The optional js/plugins registration is not installed by this package.",
                    "现有桥读取真实 MV CoreScript 全局对象。本包不安装可选的 js/plugins 登记。")
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            return ("The existing RGSS guest file-RPC route owns the overlay; this package does not install it.",
                    "现有 RGSS 客体文件 RPC 路由拥有覆盖层；本包不安装它。")
        case .love, .renpy:
            return ("An existing Floe project bridge covers the engine; this package installs no project files.",
                    "现有 Floe 工程桥覆盖该引擎；本包不安装工程文件。")
        case .microStudio:
            return ("The existing bridge exposes unnamed read-only snapshot slots; named fields require the optional project overlay, which this package does not install.",
                    "现有桥提供未命名的只读快照槽；具名字段需要可选的工程覆盖层，本包不安装它。")
        case .wasm4:
            return ("Saved globals are exposed read-only unless the cart defines named globals; this package installs no cart source.",
                    "已保存全局值只读暴露，除非卡带定义具名全局；本包不安装卡带源码。")
        case .tic80:
            return ("Only the existing snapshot/restore path is exposed; live named fields and actions depend on the cart.",
                    "仅提供现有快照/恢复路径；实时具名字段和动作取决于卡带。")
        case .phaser, .kaplay, .babylon, .playcanvas, .ink, .twine:
            return ("An existing host hook reads the engine's public runtime objects; this package installs no project files, and arbitrary game state needs explicit typed registration.",
                    "现有宿主钩子读取引擎公共运行时对象；本包不安装工程文件，任意游戏状态需要显式类型化登记。")
        }
    }
}
