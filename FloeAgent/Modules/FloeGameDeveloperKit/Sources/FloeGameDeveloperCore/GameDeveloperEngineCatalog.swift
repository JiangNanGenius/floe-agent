// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

extension GameDeveloperSupports {
    static func web(liveState: Bool = true,
                    snapshot: Bool = true,
                    restore: Bool = true,
                    pause: Bool = false,
                    resume: Bool = false,
                    speed: Bool = false,
                    reset: GameDeveloperResetMode = .reload,
                    fields: Bool = true,
                    actions: Bool = true,
                    projectRegistration: Bool = true) -> Self {
        .init(liveState: liveState, snapshot: snapshot, restore: restore,
              pause: pause, resume: resume, speed: speed, reset: reset,
              screenshot: true, fields: fields, actions: actions,
              projectRegistration: projectRegistration)
    }

    static let guest = GameDeveloperSupports(
        liveState: true, snapshot: true, restore: true,
        pause: false, resume: false, speed: false, reset: .hook,
        screenshot: false, fields: true, actions: true,
        projectRegistration: true)
}

public enum GameDeveloperEngineCatalog {
    public static let version = "1.0.0"

    /// The exact 20-engine set, in the same order as `GameEngineID.allCases`.
    /// Each descriptor names a real route, a host hook and an instrumentation
    /// plan; an entry is never a placeholder menu page.
    public static let all: [GameDeveloperEngineDescriptor] = [
        legacyRPG(.rpgMakerXP, name: "RPG Maker XP", marker: "Data/Scripts.rxdata",
                  template: "Project/rgss-floe-developer.rb",
                  docs: ["https://github.com/Dim145/mkxp-web-jspi",
                         "https://www.rpgmakerweb.com/"]),
        legacyRPG(.rpgMakerVX, name: "RPG Maker VX", marker: "Data/Scripts.rvdata",
                  template: "Project/rgss-floe-developer.rb",
                  docs: ["https://github.com/Dim145/mkxp-web-jspi",
                         "https://www.rpgmakerweb.com/"]),
        legacyRPG(.rpgMakerVXAce, name: "RPG Maker VX Ace", marker: "Data/Scripts.rvdata2",
                  template: "Project/rgss-floe-developer.rb",
                  docs: ["https://github.com/Dim145/mkxp-web-jspi",
                         "https://www.rpgmakerweb.com/"]),
        rpgMakerMV,
        rpgMakerMZ,
        phaser,
        kaplay,
        godot,
        babylon,
        playcanvas,
        love,
        renpy,
        tic80,
        ink,
        twine,
        gdevelop,
        cocosCreator,
        microStudio,
        wasm4,
        unity,
    ]

    public static func descriptor(for engine: GameEngineID) throws -> GameDeveloperEngineDescriptor {
        guard let descriptor = all.first(where: { $0.engine == engine }) else {
            throw GameDeveloperError.unsupported("No developer descriptor for \(engine.rawValue)")
        }
        return descriptor
    }

    public static func matrix() -> GameDeveloperCapabilityMatrix {
        .init(catalogVersion: version, engines: all)
    }

    public static var matrixJSON: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(matrix())) ?? Data("{}".utf8)
    }

    // MARK: - Legacy RGSS

    private static func legacyRPG(_ engine: GameEngineID, name: String, marker: String,
                                  template: String, docs: [String]) -> GameDeveloperEngineDescriptor {
        .init(
            engine: engine, displayName: name,
            route: .guestRuntime, support: .guestRuntimeBridge,
            hookID: engine.rawValue,
            expectedSupports: .init(
                liveState: true, snapshot: true, restore: true,
                pause: false, resume: false, speed: false, reset: .hook,
                screenshot: false, fields: true, actions: true,
                projectRegistration: false),
            instrumentation: .init(
                summary: "A bounded binary file-RPC overlay runs inside the real RGSS project. It exposes live party gold, actor level/HP/MP, variables, switches, map transfer and a primitive-only snapshot through the host's existing guest file service.",
                summaryZhHans: "有界二进制文件 RPC 覆盖层运行在真实 RGSS 工程内，通过宿主现有客体文件服务提供实时队伍金钱、角色等级/HP/MP、变量、开关、地图传送和仅原始类型的快照。",
                files: [
                    .init(path: marker, action: "patch",
                          purpose: "Insert the Floe developer overlay entry into the project's script archive through an explicit owned project plan.", purposeZhHans: "通过显式受控工程计划把 Floe 开发者覆盖层入口写入工程脚本归档。",
                          templateResource: template),
                    .init(path: "floe-developer/floe_developer.rb", action: "create",
                          purpose: "The actual overlay loaded by the project; it polls requests and never provides eval or a host mount.", purposeZhHans: "工程加载的实际覆盖层；轮询请求且不提供 eval 或宿主挂载。",
                          templateResource: template),
                    .init(path: "floe-developer/requests", action: "runtime",
                          purpose: "Host-to-game requests; bounded TLV files owned by the current run.", purposeZhHans: "宿主到游戏的请求；当前运行拥有的有界 TLV 文件。"),
                    .init(path: "floe-developer/responses", action: "runtime",
                          purpose: "Game-to-host responses; removed after read-back.", purposeZhHans: "游戏到宿主的响应；读取后删除。"),
                ],
                steps: [
                    "Keep the imported source immutable and create a project revision for the overlay entry.",
                    "Patch the script archive through the existing owned project plan/CAS; do not rewrite the original archive.",
                    "Set $floe_engine_id (rpgMakerXP/VX/VXAce), then load File.expand_path('floe-developer/floe_developer.rb') from the project root.",
                    "Run the project in the host's existing Linux guest or RGSS Web harness and provide its scoped guest file service.",
                    "Use live party/variable/map fields and primitive snapshots; a missing overlay is an actionable attach error.",
                ],
                stepsZhHans: [
                    "保留导入源码不可变，为覆盖层入口创建单独的工程修订。",
                    "通过现有受控工程计划/CAS 修改脚本归档，不重写原始归档。",
                    "从工程根目录运行；设置 $floe_engine_id（rpgMakerXP/VX/VXAce），通过 load File.expand_path('floe-developer/floe_developer.rb') 加载覆盖层。",
                    "在宿主现有 Linux 客体或 RGSS 网页宿主中运行工程，并提供受控客体文件服务。",
                    "使用实时队伍/变量/地图字段和原始类型快照；缺少覆盖层时给出可操作的连接错误。",
                ],
                hookContract: "Binary file RPC v1 (FLDR request / FLDS response TLV) under <run>/floe-developer. Operations: probe, read, write, invoke, snapshot, restore, reset, diagnostics, detach. No arbitrary Ruby or host shell.",
                requiresRebuild: true,
                limitations: "Debug snapshots cover party values, item counts, primitive variables/switches through ID 2048 and map position. Events, self-switches, custom objects and engine save files require separate integration.",
                limitationsZhHans: "调试快照包含队伍数值、物品数量、1–2048 号原始类型变量/开关和地图位置。事件、自开关、自定义对象与正式存档需单独适配。",
                officialDocumentation: docs),
            notes: "Route: guest/native RGSS. A real file-RPC overlay + typed Swift transport are supplied; no shell/second runtime is created.",
            notesZhHans: "路由：RGSS 客体/原生。提供真实文件 RPC 覆盖层和类型化 Swift 传输；不创建 shell 或第二运行时。")
    }

    // MARK: - RPG Maker MV / MZ

    private static let rpgMakerMV = GameDeveloperEngineDescriptor(
        engine: .rpgMakerMV, displayName: "RPG Maker MV",
        route: .portableAssembly, support: .bridgeContract,
        hookID: GameEngineID.rpgMakerMV.rawValue,
        expectedSupports: .web(pause: true, resume: true, reset: .reload),
        instrumentation: .init(
            summary: "Uses the official MIT MV CoreScript globals through the existing Floe bridge. Party, money, actors, items, switches, variables, map transfer, save-state snapshot and SceneManager pause are real runtime reads/writes.",
            summaryZhHans: "通过现有 Floe 桥使用官方 MIT MV CoreScript 全局对象。队伍、金钱、角色、物品、开关、变量、地图传送、存档状态快照和 SceneManager 暂停均为真实运行时读写。",
            files: [
                .init(path: "js/plugins/FloeDeveloperProject.js", action: "create",
                      purpose: "Optional project-specific registration for named variables/actions; the base adapter needs no project file.", purposeZhHans: "可选的工程自定义字段/动作登记；基础适配器不需要工程文件。",
                      templateResource: "Project/floe-developer-project.js"),
            ],
            steps: [
                "Open or build the MV Web runtime as the existing portable route does.",
                "Attach the host bridge before the player starts; the adapter registers only when $gameParty/$gameVariables exist.",
                "Use typed fields and actions; every write is read back from the real game objects.",
            ],
            stepsZhHans: [
                "按现有便携路由打开或构建 MV 网页运行时。",
                "在播放器启动前附加宿主桥；仅在 $gameParty/$gameVariables 存在时登记适配器。",
                "使用类型化字段和动作；每次写入都从真实游戏对象回读。",
            ],
            hookContract: "FloeGame snapshot/restore + FloeDeveloper.register. The MV hook reads $gameParty, $gameActors, $gameVariables, $gameSwitches, $gamePlayer, $gameMap, $gameSystem and $dataSystem.",
            requiresRebuild: false,
            limitations: "Pause uses SceneManager.stop/resume, which freezes scene updates but does not stop audio. No global simulation-speed setter is claimed.",
            limitationsZhHans: "暂停使用 SceneManager.stop/resume，冻结场景更新但不停止音频。不声称支持全局模拟速度修改。",
            officialDocumentation: ["https://github.com/rpgtkoolmv/corescript",
                                    "https://www.rpgmakerweb.com/"]),
        notes: "Actual MV CoreScript API names are verified against the prepared 1.3b source in Fixtures/PortableResources.",
        notesZhHans: "MV CoreScript API 名称已对照 Fixtures/PortableResources 中准备的 1.3b 源码验证。")

    private static let rpgMakerMZ = GameDeveloperEngineDescriptor(
        engine: .rpgMakerMZ, displayName: "RPG Maker MZ",
        route: .externalBuild, support: .hostBuildHook,
        hookID: GameEngineID.rpgMakerMZ.rawValue,
        expectedSupports: .web(pause: true, resume: true, reset: .reload),
        instrumentation: .init(
            summary: "A licensed MZ Web runtime is produced by the host's existing build/export service. The same typed globals adapter then exposes party, money, actors, items, switches, variables, map transfer and snapshot/pause.",
            summaryZhHans: "由宿主现有构建/导出服务产生授权的 MZ 网页运行时，然后由同一套类型化全局适配器提供队伍、金钱、角色、物品、开关、变量、地图传送及快照/暂停。",
            files: [
                .init(path: "js/plugins/FloeDeveloperProject.js", action: "create",
                      purpose: "Optional project registration; the base adapter reads standard MZ globals only.", purposeZhHans: "可选工程登记；基础适配器只读取标准 MZ 全局对象。",
                      templateResource: "Project/floe-developer-project.js"),
            ],
            steps: [
                "Export/build the licensed MZ Web runtime through the existing jobs/build provider.",
                "Load it in the existing offline player and attach the host bridge.",
                "Use the same typed controls as MV; a missing MZ runtime is shown as an actionable prerequisite, not a fake engine.",
            ],
            stepsZhHans: [
                "通过现有作业/构建提供方导出/构建授权的 MZ 网页运行时。",
                "在现有离线播放器中加载并附加宿主桥。",
                "使用与 MV 相同的类型化控件；缺少 MZ 运行时显示为可操作前置条件，而不是伪造引擎。",
            ],
            hookContract: "Same bridge contract as MV, guarded by MZ globals. No MZ engine files are bundled or gated on a developer subscription.",
            requiresRebuild: true,
            limitations: "The MZ Web runtime/export and its license are supplied by the user's engine workflow; this component adds no MZ binaries.",
            limitationsZhHans: "MZ 网页运行时/导出及其许可由用户的引擎流程提供；本组件不添加 MZ 二进制。",
            officialDocumentation: ["https://github.com/rpgtkoolmv/corescript",
                                    "https://www.rpgmakerweb.com/"]),
        notes: "Route: host external build. Project source, data and originals are never rewritten by this package.",
        notesZhHans: "路由：宿主外部构建。本包不会改写工程源码、数据和原件。")

    // MARK: - JavaScript runtime-pack engines

    private static let phaser = GameDeveloperEngineDescriptor(
        engine: .phaser, displayName: "Phaser",
        route: .runtimePack, support: .bundledHook,
        hookID: GameEngineID.phaser.rawValue,
        expectedSupports: .web(pause: true, resume: true, speed: true, reset: .reload),
        instrumentation: .init(
            summary: "Reads the real Phaser game/scene graph when a game instance is exposed (starter: window.FloeTemplate; imported: window.game). Exposes Registry values, scene list, camera, loop FPS, pause/resume and scene clock/speed where present.",
            summaryZhHans: "当暴露真实 Phaser 游戏/场景对象时读取它们（起始模板：window.FloeTemplate；导入工程：window.game）。提供 Registry、场景列表、相机、循环 FPS、暂停/恢复及存在的场景时钟/速度。",
            files: [
                .init(path: "src/floe-developer.js", action: "create",
                      purpose: "Optional project registration for game-specific fields/actions when the game instance is not globally exposed.", purposeZhHans: "当游戏实例未全局暴露时，可选登记游戏专属字段/动作。",
                      templateResource: "Project/floe-developer-project.js"),
            ],
            steps: [
                "Keep the existing static/runtime-pack route; no rebuild is needed for the starter template.",
                "The host injects the Phaser hook; it polls briefly for a game instance and registers only observed capabilities.",
                "For imported code that hides its Phaser.Game, expose it as window.game or register fields through FloeDeveloper.register.",
            ],
            stepsZhHans: [
                "保留现有静态/运行时包路由；起始模板无需重建。",
                "宿主注入 Phaser 钩子；短暂轮询游戏实例后只登记实际观察到的能力。",
                "对隐藏 Phaser.Game 的导入代码，将其暴露为 window.game，或通过 FloeDeveloper.register 登记字段。",
            ],
            hookContract: "FloeDeveloper.register; getters/setters use game.registry, game.scene, scene.cameras.main, scene.time.timeScale and Arcade Physics when present. Snapshot/restore delegates to FloeGame when the project provides it.",
            requiresRebuild: false,
            limitations: "Speed applies to scene clocks and Arcade Physics; a game using raw delta time may not change speed. Imported projects without a findable game instance get the universal inspector and a registration plan only.",
            limitationsZhHans: "速度作用于场景时钟和 Arcade Physics；使用原始 delta 的游戏可能不改变速度。找不到游戏实例的导入工程只获得通用检查器和登记计划。",
            officialDocumentation: ["https://docs.phaser.io/", "https://github.com/phaserjs/phaser"]),
        notes: "Actual Phaser 3.90.0 is the prepared runtime pack. The host hook is guarded by window.Phaser and never creates a second game.",
        notesZhHans: "实际 Phaser 3.90.0 是准备的运行包。宿主钩子受 window.Phaser 保护，不创建第二个游戏。")

    private static let kaplay = GameDeveloperEngineDescriptor(
        engine: .kaplay, displayName: "KAPLAY",
        route: .runtimePack, support: .bundledHook,
        hookID: GameEngineID.kaplay.rawValue,
        expectedSupports: .web(pause: false, resume: false, speed: false, reset: .reload),
        instrumentation: .init(
            summary: "Reads the starter template state and real KAPLAY debug/frame counters. Editable position/score fields use the template state; imported KAPLAY projects can register their own fields and actions.",
            summaryZhHans: "读取起始模板状态和真实 KAPLAY 调试/帧计数。位置/分数字段使用模板状态；导入的 KAPLAY 工程可登记自己的字段和动作。",
            files: [
                .init(path: "src/floe-developer.js", action: "create",
                      purpose: "Optional project-specific fields/actions for imported KAPLAY games.", purposeZhHans: "导入 KAPLAY 游戏的可选工程字段/动作。",
                      templateResource: "Project/floe-developer-project.js"),
            ],
            steps: [
                "Run the existing runtime-pack route; the starter template already exposes FloeTemplate.state.",
                "The host hook registers state fields, FPS and frame count when KAPLAY is present.",
                "For imported games, register named fields through FloeDeveloper.register; no internal debug flags are presented as a real pause.",
            ],
            stepsZhHans: [
                "运行现有运行时包路由；起始模板已暴露 FloeTemplate.state。",
                "宿主钩子在 KAPLAY 存在时登记状态字段、FPS 和帧数。",
                "对导入游戏，通过 FloeDeveloper.register 登记命名字段；不把内部调试标志当作真实暂停。",
            ],
            hookContract: "FloeDeveloper.register; reads window.FloeTemplate.state and the engine's public debug counters. No internal app-state mutation.",
            requiresRebuild: false,
            limitations: "KAPLAY's public API reviewed here does not expose a supported global pause or time-scale control; the menu reports that limitation instead of toggling a visual-only debug flag.",
            limitationsZhHans: "此处审查的 KAPLAY 公共 API 不提供受支持的全局暂停或时间缩放；菜单报告该限制，而不是切换仅视觉调试标志。",
            officialDocumentation: ["https://kaplayjs.com/", "https://github.com/kaplayjs/kaplay"]),
        notes: "Prepared runtime pack 3001.0.0. No pause/speed claim.",
        notesZhHans: "准备的运行时包 3001.0.0。不声称暂停/速度。")

    private static let babylon = GameDeveloperEngineDescriptor(
        engine: .babylon, displayName: "Babylon.js",
        route: .runtimePack, support: .bundledHook,
        hookID: GameEngineID.babylon.rawValue,
        expectedSupports: .web(pause: true, resume: true, speed: false, reset: .reload),
        instrumentation: .init(
            summary: "Reads the real Babylon engine/scene/camera. Pause/resume stops and restarts the existing render loop; camera and animation-time-scale fields are typed; starter state fields come from FloeTemplate.",
            summaryZhHans: "读取真实 Babylon 引擎/场景/相机。暂停/恢复停止并重启现有渲染循环；相机和动画时间缩放为类型化字段；起始状态来自 FloeTemplate。",
            files: [
                .init(path: "src/floe-developer.js", action: "create",
                      purpose: "Optional project fields/actions for imported Babylon scenes.", purposeZhHans: "导入 Babylon 场景的可选工程字段/动作。",
                      templateResource: "Project/floe-developer-project.js"),
            ],
            steps: [
                "Run the existing runtime-pack route; the starter exposes engine, scene, camera and renderLoop.",
                "The host hook registers camera and animation fields plus a real stop/run render-loop pause.",
                "For imported scenes, register the game-specific mesh/scene values you want to expose.",
            ],
            stepsZhHans: [
                "运行现有运行时包路由；起始模板暴露引擎、场景、相机和渲染循环。",
                "宿主钩子登记相机与动画字段，并提供真实的停止/重启渲染循环暂停。",
                "对导入场景，登记你想暴露的游戏专属网格/场景值。",
            ],
            hookContract: "FloeDeveloper.register; engine.stopRenderLoop/runRenderLoop, scene.animationTimeScale, Arcamera alpha/beta/radius/target and FloeTemplate state.",
            requiresRebuild: false,
            limitations: "Animation time scale is not global simulation speed; the menu labels it accordingly. Render-loop pause does not pause audio.",
            limitationsZhHans: "动画时间缩放不是全局模拟速度；菜单会明确标注。渲染循环暂停不会暂停音频。",
            officialDocumentation: ["https://doc.babylonjs.com/", "https://github.com/BabylonJS/Babylon.js"]),
        notes: "Actual Babylon.js 9.35.0 is the prepared runtime pack; the hook is exercised with the real NullEngine in Node.",
        notesZhHans: "实际 Babylon.js 9.35.0 是准备的运行包；钩子在 Node 中用真实 NullEngine 验证。")

    private static let playcanvas = GameDeveloperEngineDescriptor(
        engine: .playcanvas, displayName: "PlayCanvas",
        route: .runtimePack, support: .bundledHook,
        hookID: GameEngineID.playcanvas.rawValue,
        expectedSupports: .web(pause: true, resume: true, speed: true, reset: .reload),
        instrumentation: .init(
            summary: "Uses the real pc.AppBase application timeScale for pause/resume and speed, plus starter state and camera/entity diagnostics. No second application is created.",
            summaryZhHans: "使用真实 pc.AppBase 应用 timeScale 实现暂停/恢复和速度，并提供起始状态与相机/实体诊断。不创建第二个应用。",
            files: [
                .init(path: "src/floe-developer.js", action: "create",
                      purpose: "Optional project-specific fields/actions for imported PlayCanvas apps.", purposeZhHans: "导入 PlayCanvas 应用的可选工程字段/动作。",
                      templateResource: "Project/floe-developer-project.js"),
            ],
            steps: [
                "Run the existing runtime-pack route; the starter exposes the real app and camera.",
                "The host hook registers app.timeScale, state and camera/entity diagnostics.",
                "Imported applications may expose their AppBase as window.FloeEngine.app or register fields directly.",
            ],
            stepsZhHans: [
                "运行现有运行时包路由；起始模板暴露真实应用和相机。",
                "宿主钩子登记 app.timeScale、状态和相机/实体诊断。",
                "导入应用可将 AppBase 暴露为 window.FloeEngine.app，或直接登记字段。",
            ],
            hookContract: "FloeDeveloper.register; app.timeScale, app.root, camera entity and FloeTemplate state.",
            requiresRebuild: false,
            limitations: "Only the application time scale and observed entities are exposed; project-specific game logic still requires registration.",
            limitationsZhHans: "只暴露应用时间缩放和实际观察到的实体；工程专属游戏逻辑仍需登记。",
            officialDocumentation: ["https://developer.playcanvas.com/", "https://github.com/playcanvas/engine"]),
        notes: "Actual PlayCanvas 2.24.0 is the prepared runtime pack.",
        notesZhHans: "实际 PlayCanvas 2.24.0 是准备的运行包。")

    // MARK: - Portable engines

    private static let love = GameDeveloperEngineDescriptor(
        engine: .love, displayName: "LÖVE",
        route: .portableAssembly, support: .bridgeContract,
        hookID: GameEngineID.love.rawValue,
        expectedSupports: .web(liveState: false, snapshot: false, restore: false,
                               pause: true, resume: true, speed: false,
                               reset: .hook, fields: false, actions: true),
        instrumentation: .init(
            summary: "The existing love.js bridge exposes typed input, restart, a real filesystem settle before stop, and real Emscripten main-loop pause/resume/step. A project-side Lua overlay can register live fields if the game is rebuilt.",
            summaryZhHans: "现有 love.js 桥提供类型化输入、重启和停止前真实文件系统收敛。若重建游戏，工程侧 Lua 覆盖层可登记实时字段。",
            files: [
                .init(path: "floe-developer.lua", action: "create",
                      purpose: "Optional Lua overlay: call love.update hooks and publish named values through the page bridge.", purposeZhHans: "可选 Lua 覆盖层：挂接 love.update 并通过页面桥发布命名字段。",
                      templateResource: "Project/love-floe-developer.lua"),
            ],
            steps: [
                "Use the existing portable LÖVE route; no engine binary is added here.",
                "For live fields, add the Lua overlay to a project revision and rebuild the Web artifact through the existing portable build port.",
                "Until then the menu shows runtime diagnostics, restart and a registration plan only.",
            ],
            stepsZhHans: [
                "使用现有便携 LÖVE 路由；此处不添加引擎二进制。",
                "如需实时字段，在工程修订中加入 Lua 覆盖层，并通过现有便携构建端口重建网页产物。",
                "基础菜单提供主循环暂停、继续、短暂运行、重启和运行诊断。",
            ],
            hookContract: "FloeDeveloper.register from a Lua/JS overlay; the base bridge keeps its no-evaluator boundary.",
            requiresRebuild: true,
            limitations: "love.js 11.4.1 does not expose a supported JS state API for arbitrary Lua variables. No fake Lua evaluator is added to the App.",
            limitationsZhHans: "love.js 11.4.1 不为任意 Lua 变量提供受支持的 JS 状态 API。App 不添加伪造的 Lua 求值器。",
            officialDocumentation: ["https://love2d.org/wiki/", "https://github.com/Davidobot/love.js"]),
        notes: "Route: portable assembly. Restart, confirmed close and main-loop pause/resume/step are real; live field editing requires the project overlay/transport.",
        notesZhHans: "路由：便携组装。重启、确认关闭和主循环暂停/继续/单步为真实能力；实时字段编辑需要工程覆盖层/传输。")

    private static let renpy = GameDeveloperEngineDescriptor(
        engine: .renpy, displayName: "Ren'Py",
        route: .portableAssembly, support: .bridgeContract,
        hookID: GameEngineID.renpy.rawValue,
        expectedSupports: .web(liveState: false, snapshot: false, restore: false,
                               pause: false, resume: false, speed: false,
                               reset: .hook, fields: false, actions: true),
        instrumentation: .init(
            summary: "The official Ren'Py 8.5.3 Web runtime exposes typed input, restart and a real IDBFS flush. This component does not claim live store fields: it supplies a bounded project-side registration API but no verified Python-store command transport.",
            summaryZhHans: "官方 Ren'Py 8.5.3 网页运行时提供类型化输入、重启和真实 IDBFS 刷写。本组件不声称实时 store 字段：提供有界工程侧登记 API，但没有已验证的 Python store 命令传输。",
            files: [
                .init(path: "game/floe_developer.rpy", action: "create",
                      purpose: "Optional Ren'Py registration API; a project must supply and verify its own transport before live fields are claimed.", purposeZhHans: "可选 Ren'Py 登记 API；工程必须自行提供并验证传输后才可声称实时字段。",
                      templateResource: "Project/renpy-floe-developer.rpy"),
            ],
            steps: [
                "Use the existing portable Ren'Py route and official Web SDK.",
                "Live fields are not claimed on this route; add an explicit project transport and register it through the provided store before using it.",
                "Use the base menu for dialogue advance, rollback/roll-forward, skip toggling and the game menu through the default keyboard map.",
            ],
            stepsZhHans: [
                "使用现有便携 Ren'Py 路由和官方网页 SDK。",
                "此路由不声称实时字段；如确需，请添加显式工程传输并通过提供的 store 登记。",
                "基础菜单通过默认键位提供推进对白、剧情回退/向前恢复、切换快进和游戏菜单。",
            ],
            hookContract: "FloeDeveloper.register from a Ren'Py/Python overlay; no Python evaluator or host filesystem access is added.",
            requiresRebuild: true,
            limitations: "Ren'Py's JavaScript surface does not expose arbitrary store variables. No fake store setter is shown.",
            limitationsZhHans: "Ren'Py 的 JavaScript 接口不暴露任意 store 变量。不显示伪造的 store 修改器。",
            officialDocumentation: ["https://www.renpy.org/doc/html/", "https://www.renpy.org/doc/html/web.html"]),
        notes: "Route: portable assembly with official Web SDK. No account/subscription gate.",
        notesZhHans: "路由：便携组装，使用官方网页 SDK。无账户/订阅门槛。")

    // MARK: - Narrative engines

    private static let tic80 = GameDeveloperEngineDescriptor(
        engine: .tic80, displayName: "TIC-80",
        route: .narrativeAssembly, support: .snapshotOnly,
        hookID: GameEngineID.tic80.rawValue,
        expectedSupports: .web(liveState: false, snapshot: false, restore: false,
                               pause: true, resume: true, speed: false,
                               reset: .reload, fields: false, actions: true),
        instrumentation: .init(
            summary: "The reviewed TIC-80 player exposes input/pointer and real Emscripten main-loop pause/resume/step, but no cart state hook. The menu provides those real controls plus diagnostics/safe reload; a cart-side Lua protocol is the rebuild plan.",
            summaryZhHans: "已审查的 TIC-80 播放器提供输入/指针和真实 Emscripten 主循环暂停/继续/单步，但没有卡带状态钩子。菜单提供这些真实控件以及诊断/安全重载；卡带侧 Lua 协议是重建计划。",
            files: [
                .init(path: "floe-developer.lua", action: "create",
                      purpose: "Optional cart-side debug protocol that publishes bounded memory/state values.", purposeZhHans: "可选卡带侧调试协议，发布有界内存/状态值。",
                      templateResource: "Project/tic80-floe-developer.lua"),
            ],
            steps: [
                "Keep the existing narrative artifact and input bridge.",
                "For live inspection, add the Lua debug protocol and rebuild the cartridge/artifact.",
                "A missing hook is reported as unsupported; the menu never claims live fields.",
            ],
            stepsZhHans: [
                "保留现有叙事产物和输入桥。",
                "如需实时检查，加入 Lua 调试协议并重建卡带/产物。",
                "缺少钩子时报告为不支持；菜单不声称实时字段。",
            ],
            hookContract: "A cart-side protocol would publish bounded memory slots through FloeDeveloper.register; no host evaluator is added.",
            requiresRebuild: true,
            limitations: "No save-state snapshot is available in the reviewed TIC-80 adapter.",
            limitationsZhHans: "已审查的 TIC-80 适配器不支持存档状态快照。",
            officialDocumentation: ["https://tic80.com/", "https://github.com/nesbox/TIC-80"]),
        notes: "Route: narrative assembly. Real main-loop pause/resume/step + diagnostics/reload; live cart state requires a rebuilt cart transport.",
        notesZhHans: "路由：叙事组装。真实主循环暂停/继续/单步 + 诊断/重载；实时卡带状态需要重建的卡带传输。")

    private static let ink = GameDeveloperEngineDescriptor(
        engine: .ink, displayName: "Ink / inkjs",
        route: .narrativeAssembly, support: .bundledHook,
        hookID: GameEngineID.ink.rawValue,
        expectedSupports: .web(liveState: true, snapshot: true, restore: true,
                               reset: .reload, fields: true, actions: true),
        instrumentation: .init(
            summary: "Reads real inkjs story variables, current path and choices. Jumping to a knot and choosing a choice use public inkjs APIs; snapshot/restore use the existing story state JSON.",
            summaryZhHans: "读取真实 inkjs 故事变量、当前路径和选项。跳转节点和选择选项使用公共 inkjs API；快照/恢复使用现有故事状态 JSON。",
            files: [
                .init(path: "src/floe-developer.js", action: "create",
                      purpose: "Optional registration for game-specific derived values.", purposeZhHans: "游戏专属派生值的可选登记。",
                      templateResource: "Project/floe-developer-project.js"),
            ],
            steps: [
                "Build/open the existing Ink narrative artifact.",
                "The bridge exposes FloeInkRuntime; the host hook registers variables/path/choices and real jump/choose actions.",
                "Use snapshot/restore for a complete story state. No arbitrary Ink evaluation is exposed.",
            ],
            stepsZhHans: [
                "构建/打开现有 Ink 叙事产物。",
                "桥暴露 FloeInkRuntime；宿主钩子登记变量/路径/选项及真实跳转/选择动作。",
                "完整故事状态使用快照/恢复。不暴露任意 Ink 求值。",
            ],
            hookContract: "FloeDeveloper.register; story.variablesState, story.state.currentPathString, story.ChoosePathString and currentChoices.",
            requiresRebuild: false,
            limitations: "Only string/number/boolean variables and paths are exposed; ink lists/diverts remain read-only text.",
            limitationsZhHans: "只暴露字符串/数字/布尔变量和路径；ink 列表/转移保持只读文本。",
            officialDocumentation: ["https://github.com/inkle/ink", "https://github.com/y-lohse/inkjs"]),
        notes: "Actual inkjs 2.4.0 + the prepared ink sources are exercised in Node.",
        notesZhHans: "在 Node 中实际运行 inkjs 2.4.0 与准备的 Ink 源。")

    private static let twine = GameDeveloperEngineDescriptor(
        engine: .twine, displayName: "Twine / SugarCube",
        route: .narrativeAssembly, support: .bundledHook,
        hookID: GameEngineID.twine.rawValue,
        expectedSupports: .web(liveState: true, snapshot: true, restore: true,
                               reset: .reload, fields: true, actions: true),
        instrumentation: .init(
            summary: "Reads SugarCube State.passage, turns and variables; jump action uses Engine.play. Snapshot/restore use the existing SugarCube save object.",
            summaryZhHans: "读取 SugarCube State.passage、回合和变量；跳转动作使用 Engine.play。快照/恢复使用现有 SugarCube 存档对象。",
            files: [
                .init(path: "support/floe-developer.js", action: "create",
                      purpose: "Optional game-specific registration; base adapter uses State/Engine.", purposeZhHans: "可选游戏专属登记；基础适配器使用 State/Engine。",
                      templateResource: "Project/floe-developer-project.js"),
            ],
            steps: [
                "Build/open the existing Twine narrative artifact.",
                "The bridge exposes FloeTwineRuntime; the host hook registers variables and a real passage jump.",
                "Variable writes go through SugarCube's macro/state semantics where possible; invalid names are rejected.",
            ],
            stepsZhHans: [
                "构建/打开现有 Twine 叙事产物。",
                "桥暴露 FloeTwineRuntime；宿主钩子登记变量和真实段落跳转。",
                "变量写入尽可能走 SugarCube 宏/状态语义；非法名称被拒绝。",
            ],
            hookContract: "FloeDeveloper.register; SugarCube.State.variables, State.passage, State.turns and Engine.play.",
            requiresRebuild: false,
            limitations: "Only primitive variables are exposed; story JavaScript and arbitrary macros are not evaluated by the host.",
            limitationsZhHans: "只暴露原始类型变量；宿主不求值故事 JavaScript 或任意宏。",
            officialDocumentation: ["https://twinery.org/", "https://www.motoslave.net/sugarcube/2/docs/"]),
        notes: "Bridge exposes only State/Engine handles; no new story interpreter.",
        notesZhHans: "桥只暴露 State/Engine 句柄；不新增故事解释器。")

    private static let microStudio = GameDeveloperEngineDescriptor(
        engine: .microStudio, displayName: "microStudio",
        route: .narrativeAssembly, support: .bridgeContract,
        hookID: GameEngineID.microStudio.rawValue,
        expectedSupports: .web(liveState: true, snapshot: true, restore: true,
                               reset: .reload, fields: true, actions: true),
        instrumentation: .init(
            summary: "Reads the real microStudio floe_snapshot array and exposes bounded read-only slots. Named fields/actions can register from the microScript overlay; restore uses floe_restore.",
            summaryZhHans: "读取真实 microStudio floe_snapshot 数组并提供有界只读槽位。具名字段/动作可从 microScript 覆盖层登记；恢复使用 floe_restore。",
            files: [
                .init(path: "src/main.ms", action: "patch",
                      purpose: "Optional project overlay: define floe_snapshot/floe_restore and named developer values.", purposeZhHans: "可选工程覆盖层：定义 floe_snapshot/floe_restore 和命名开发者值。",
                      templateResource: "Project/microstudio-floe-developer.ms"),
            ],
            steps: [
                "Open the existing microStudio narrative artifact.",
                "The bridge already exposes snapshot/restore; the hook registers read-only slots from the real array.",
                "For named fields, add the overlay functions in a project revision and rebuild the artifact.",
            ],
            stepsZhHans: [
                "打开现有 microStudio 叙事产物。",
                "桥已提供快照/恢复；钩子从真实数组登记只读槽位。",
                "如需具名字段，在工程修订中添加覆盖层函数并重建产物。",
            ],
            hookContract: "FloeDeveloper.register; FloeGame.snapshot/restore backed by player.call('floe_snapshot'/'floe_restore').",
            requiresRebuild: false,
            limitations: "The upstream player does not expose variable names; unnamed array slots are read-only unless the project overlay registers names.",
            limitationsZhHans: "上游播放器不暴露变量名；未命名数组槽位为只读，除非工程覆盖层登记名称。",
            officialDocumentation: ["https://microstudio.dev/", "https://github.com/pmalpas/microstudio"]),
        notes: "Snapshot/restore is real; named field editing needs the project overlay.",
        notesZhHans: "快照/恢复为真实能力；具名字段编辑需要工程覆盖层。")

    private static let wasm4 = GameDeveloperEngineDescriptor(
        engine: .wasm4, displayName: "WASM-4",
        route: .narrativeAssembly, support: .bridgeContract,
        hookID: GameEngineID.wasm4.rawValue,
        expectedSupports: .web(liveState: true, snapshot: true, restore: true,
                               reset: .reload, fields: true, actions: true),
        instrumentation: .init(
            summary: "Uses the upstream SavedGameState memory/globals save path. Globals are exposed as bounded read-only fields; full state snapshot/restore is real.",
            summaryZhHans: "使用上游 SavedGameState 内存/全局保存路径。全局值作为有界只读字段暴露；完整状态快照/恢复为真实能力。",
            files: [
                .init(path: "src/main.zig", action: "patch",
                      purpose: "Optional cart-defined debug globals for meaningful names; memory snapshot works without it.", purposeZhHans: "可选卡带定义调试全局以提供有意义名称；无此也可做内存快照。",
                      templateResource: nil),
            ],
            steps: [
                "Open the existing WASM-4 artifact.",
                "The hook registers saved global keys as read-only fields and exposes snapshot/restore.",
                "Cart authors can add named globals; the host never interprets cartridge code.",
            ],
            stepsZhHans: [
                "打开现有 WASM-4 产物。",
                "钩子把已保存的全局键登记为只读字段，并提供快照/恢复。",
                "卡带作者可添加命名全局；宿主不解释卡带代码。",
            ],
            hookContract: "FloeDeveloper.register; FloeGame.snapshot/restore (memory/globals/disk).",
            requiresRebuild: false,
            limitations: "No live CPU register/step debugger is exposed; snapshots are game-state only.",
            limitationsZhHans: "不暴露实时 CPU 寄存器/单步调试器；快照仅为游戏状态。",
            officialDocumentation: ["https://wasm4.org/docs/", "https://github.com/aduros/wasm4"]),
        notes: "Snapshot/restore is real; no fake variable setters.",
        notesZhHans: "快照/恢复为真实能力；不伪造变量修改器。")

    // MARK: - External-build engines

    private static let godot = GameDeveloperEngineDescriptor(
        engine: .godot, displayName: "Godot",
        route: .externalBuild, support: .hostBuildHook,
        hookID: GameEngineID.godot.rawValue,
        expectedSupports: .web(liveState: true, snapshot: false, restore: false,
                               pause: true, resume: true, reset: .reload,
                               fields: true, actions: true,
                               projectRegistration: true),
        instrumentation: .init(
            summary: "A Web export built by the host's existing Godot job; a small GDScript autoload publishes selected values through JavaScriptBridge. No Godot runtime is bundled.",
            summaryZhHans: "由宿主现有 Godot 作业构建网页导出；小型 GDScript 自动加载通过 JavaScriptBridge 发布选定值。不捆绑 Godot 运行时。",
            files: [
                .init(path: "project.godot", action: "patch",
                      purpose: "Register the Floe developer autoload in the exported project.", purposeZhHans: "在导出工程中注册 Floe 开发者自动加载。",
                      templateResource: "Project/godot-floe-developer.gd"),
                .init(path: "floe_developer.gd", action: "create",
                      purpose: "Autoload that registers scene/time-scale/pause fields and an explicit publish function.", purposeZhHans: "登记场景/时间缩放/暂停字段和显式发布函数的自动加载。",
                      templateResource: "Project/godot-floe-developer.gd"),
            ],
            steps: [
                "Add the autoload to a project revision and export a Web build through the existing Godot build provider.",
                "The autoload registers only values the project explicitly publishes; no GDScript evaluator is added.",
                "Without the export/bridge the menu shows diagnostics and the exact missing-hook reason.",
            ],
            stepsZhHans: [
                "在工程修订中加入自动加载，并通过现有 Godot 构建提供方导出网页构建。",
                "自动加载只登记工程显式发布的值；不添加 GDScript 求值器。",
                "无导出/桥时菜单显示诊断和具体缺失钩子原因。",
            ],
            hookContract: "GDScript calls JavaScriptBridge FloeDeveloper.register with typed descriptors; actions call back into explicit GDScript functions.",
            requiresRebuild: true,
            limitations: "The Godot export toolchain and licensed project assets remain user/host supplied. No debugger or arbitrary scene tree mutation is exposed.",
            limitationsZhHans: "Godot 导出工具链和授权工程资源仍由用户/宿主提供。不暴露调试器或任意场景树修改。",
            officialDocumentation: ["https://docs.godotengine.org/en/stable/classes/class_javascriptbridge.html"]),
        notes: "Route: external build. Actual engine execution is not available in this lane.",
        notesZhHans: "路由：外部构建。本车道不进行实际引擎执行。")

    private static let gdevelop = GameDeveloperEngineDescriptor(
        engine: .gdevelop, displayName: "GDevelop",
        route: .externalBuild, support: .hostBuildHook,
        hookID: GameEngineID.gdevelop.rawValue,
        expectedSupports: .web(liveState: true, snapshot: false, restore: false,
                               pause: true, resume: true, speed: true,
                               reset: .reload, fields: true, actions: true),
        instrumentation: .init(
            summary: "The official GDevelop/PIXI export is built by the existing host job. The hook reads gdjs global/scene variables and time scale when those public objects are exposed.",
            summaryZhHans: "官方 GDevelop/PIXI 导出由现有宿主作业构建。当公共对象可用时，钩子读取 gdjs 全局/场景变量和时间缩放。",
            files: [
                .init(path: "floe-developer.js", action: "create",
                      purpose: "Optional export-side registration for project-specific variables/objects.", purposeZhHans: "导出侧可选登记工程专属变量/对象。",
                      templateResource: "Project/gdevelop-floe-developer.js"),
            ],
            steps: [
                "Export the project through the existing GDevelop build route.",
                "The host hook registers guarded gdjs variables/time scale; unavailable APIs are reported, not simulated.",
                "For object/scene actions, register explicit functions from the export-side overlay.",
            ],
            stepsZhHans: [
                "通过现有 GDevelop 构建路由导出工程。",
                "宿主钩子登记受保护的 gdjs 变量/时间缩放；不可用 API 报告为不支持，不模拟。",
                "对象/场景动作由导出侧覆盖层登记显式函数。",
            ],
            hookContract: "FloeDeveloper.register; gdjs runtime scene/global variables and time manager when present.",
            requiresRebuild: true,
            limitations: "GDevelop exposes several export shapes; the hook only registers APIs it observes. Actual export execution is not part of this lane.",
            limitationsZhHans: "GDevelop 有多种导出形态；钩子只登记实际观察到的 API。本车道不执行实际导出。",
            officialDocumentation: ["https://wiki.gdevelop.io/", "https://github.com/4ian/GDevelop"]),
        notes: "Route: external build. No account gate.",
        notesZhHans: "路由：外部构建。无账户门槛。")

    private static let cocosCreator = GameDeveloperEngineDescriptor(
        engine: .cocosCreator, displayName: "Cocos Creator",
        route: .externalBuild, support: .hostBuildHook,
        hookID: GameEngineID.cocosCreator.rawValue,
        expectedSupports: .web(liveState: true, snapshot: false, restore: false,
                               pause: true, resume: true, speed: false,
                               reset: .reload, fields: true, actions: true),
        instrumentation: .init(
            summary: "A Cocos Web build is produced by the existing host job. The hook uses the public cc/director globals for scene name, frame count and director pause/resume when present.",
            summaryZhHans: "Cocos 网页构建由现有宿主作业产生。钩子使用公共 cc/director 全局对象读取场景名、帧数，并在可用时暂停/恢复 director。",
            files: [
                .init(path: "assets/scripts/FloeDeveloper.ts", action: "create",
                      purpose: "Optional project registration for named components/state.", purposeZhHans: "可选工程登记命名组件/状态。",
                      templateResource: "Project/cocos-floe-developer.ts"),
            ],
            steps: [
                "Build the Web export through the existing Cocos build provider.",
                "The hook registers only observed director/game capabilities.",
                "Project-specific values use the TypeScript registration overlay.",
            ],
            stepsZhHans: [
                "通过现有 Cocos 构建提供方构建网页导出。",
                "钩子只登记实际观察到的 director/游戏能力。",
                "工程专属值使用 TypeScript 登记覆盖层。",
            ],
            hookContract: "FloeDeveloper.register; cc.director.pause/resume, scene name and frame counters when present.",
            requiresRebuild: true,
            limitations: "Director pause is not a guarantee for every game system; unavailable globals produce an actionable notice.",
            limitationsZhHans: "Director 暂停不保证覆盖所有游戏系统；不可用全局对象会产生可操作提示。",
            officialDocumentation: ["https://docs.cocos.com/creator/", "https://github.com/cocos/cocos-engine"]),
        notes: "Route: external build. No editor/binary is bundled.",
        notesZhHans: "路由：外部构建。不捆绑编辑器/二进制。")

    private static let unity = GameDeveloperEngineDescriptor(
        engine: .unity, displayName: "Unity",
        route: .externalBuild, support: .hostBuildHook,
        hookID: GameEngineID.unity.rawValue,
        expectedSupports: .web(liveState: true, snapshot: false, restore: false,
                               pause: true, resume: true, reset: .reload,
                               fields: true, actions: true,
                               projectRegistration: true),
        instrumentation: .init(
            summary: "A WebGL build is produced by the existing host job. A C#/jslib pair registers explicit values and SendMessage actions; arbitrary C# reflection or a Unity debugger is not exposed.",
            summaryZhHans: "WebGL 构建由现有宿主作业产生。C#/jslib 对显式登记值和 SendMessage 动作；不暴露任意 C# 反射或 Unity 调试器。",
            files: [
                .init(path: "Assets/Plugins/WebGL/FloeDeveloper.jslib", action: "create",
                      purpose: "Narrow JS registration entry point exposed to the C# bridge.", purposeZhHans: "暴露给 C# 桥的窄 JS 登记入口。",
                      templateResource: "Project/unity-floe-developer.jslib"),
                .init(path: "Assets/Scripts/FloeDeveloperBridge.cs", action: "create",
                      purpose: "Typed C# registration/publish/command methods over the jslib.", purposeZhHans: "基于 jslib 的类型化 C# 登记/发布/命令方法。",
                      templateResource: "Project/unity-floe-developer.cs"),
                .init(path: "Assets/Scripts/FloeDeveloperBridgeBehaviour.cs", action: "create",
                      purpose: "Automatic persistent MonoBehaviour that registers and pumps publish/commands.", purposeZhHans: "自动持久 MonoBehaviour，负责登记并泵送发布/命令。",
                      templateResource: "Project/unity-floe-developer-behaviour.cs"),
            ],
            steps: [
                "Add the two files to a project revision and build WebGL through the existing Unity job.",
                "Call FloeDeveloperBridge.Register/Publish from game code for the values you want; no reflection is used.",
                "Without the build the menu shows diagnostics and the exact missing bridge reason.",
            ],
            stepsZhHans: [
                "在工程修订中加入两个文件，并通过现有 Unity 作业构建 WebGL。",
                "在游戏代码中调用 FloeDeveloperBridge.Register/Publish 登记想暴露的值；不使用反射。",
                "无构建时菜单显示诊断和具体缺失桥原因。",
            ],
            hookContract: "C# DllImport into the jslib, which calls FloeDeveloper.register with typed JSON; actions use explicit SendMessage handlers.",
            requiresRebuild: true,
            limitations: "Unity WebGL builds and licenses remain user/host supplied. Actual Unity execution is not part of this lane.",
            limitationsZhHans: "Unity WebGL 构建和许可仍由用户/宿主提供。本车道不执行实际 Unity。",
            officialDocumentation: ["https://docs.unity3d.com/Manual/webgl-interactingwithbrowserscripting.html"]),
        notes: "Route: external build. No subscription/account gate.",
        notesZhHans: "路由：外部构建。无订阅/账户门槛。")

    // MARK: - Catalog validation

    /// Fail closed if an engine id is missing/duplicated or a descriptor has no
    /// intentional route/plan. Called by tests, the CLI and the Session.
    public static func validated() throws -> [GameDeveloperEngineDescriptor] {
        guard all.count == GameEngineID.allCases.count,
              Set(all.map(\.engine)) == Set(GameEngineID.allCases),
              Set(all.map(\.engine)).count == all.count else {
            throw GameDeveloperError.invalidConfiguration("engine catalog must contain every id exactly once")
        }
        for descriptor in all {
            guard descriptor.hookID?.isEmpty == false,
                  !descriptor.instrumentation.summary.isEmpty,
                  !descriptor.instrumentation.steps.isEmpty,
                  !descriptor.instrumentation.limitations.isEmpty,
                  !descriptor.instrumentation.officialDocumentation.isEmpty else {
                throw GameDeveloperError.invalidConfiguration("incomplete descriptor \(descriptor.engine.rawValue)")
            }
        }
        return all
    }
}
