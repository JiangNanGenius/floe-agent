// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameCore
import FloeGameWebKit
import FloeGameBuildKit
import FloeGameAuthoring
import FloeGameEditingCore
import FloeGameTouch
import FloeRPGCore

@MainActor final class GameQualificationHost: ObservableObject {
    struct Editor: Identifiable { let id = UUID(); let session: GameEditingSession }
    struct Play: Identifiable { let id = UUID(); let runID: UUID; let player: GameWebPlayer; let controls: GameTouchInputService; let defaultControls: GameTouchProfile }
    @Published var project: GameStoredProject?
    @Published var context: GameProjectContext?
    @Published var engine: GameEngineID?
    @Published var editor: Editor?
    @Published var play: Play?
    @Published var status = "先新建游戏项目，再导入已有工程。"
    @Published var busy = false
    @Published var preview: Data?
    @Published var x = "—"
    @Published var score = "—"
    @Published var touchDispatch = "—"
    @Published var browserFeatures = "—"
    @Published var verificationSummary = ""
    @Published var history: [GameStoredProject] = []
    let store: QualificationStore
    let repository: FileGameProjectRepository
    let runController: GameProjectRunController
    let authoring: GameAIEditingService
    let directory: URL
    private var action: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var monitoring: UUID?
    private var controlStore: GameTouchProfileStore?
    private var controlRevision: UInt64 = 0
    private var inputProbe: QualificationInputProbe?

    init() throws {
        directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("GameQualification")
        store = try .init(directory: directory); repository = store.repository
        let preparer = try GameStaticWebRunPreparer(artifactDirectory: directory.appendingPathComponent("Artifacts"), entry: GameRelativePath("index.html"))
        runController = .init(contexts: store, preparation: preparer)
        authoring = .init(repository: repository, contexts: store, provider: QualificationEditProvider(), validators: [GameJSONValidator()])
    }
    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        action = Task { @MainActor in
            defer { busy = false; action = nil }
            do { try await operation() } catch { status = String(describing: error) }
        }
    }
    func create() {
        perform {
            await self.stop()
            let id = UUID(); await self.store.activate(id)
            let created = try await self.repository.createProject(projectID: id, owner: .space(recordID: id), title: "我的游戏")
            self.project = created; self.context = try await self.store.context(id: id, owner: created.owner)
            self.engine = nil; self.preview = nil; self.status = "项目已新建，可以导入文件。"
            self.verificationSummary = ""
        }
    }
    func importFixture(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "zip") else { status = "找不到验证资源"; return }
        importURL(url)
    }
    func importURL(_ url: URL) {
        perform {
            guard let project = self.project, let context = self.context else { throw GameProjectError.invalidContext }
            try context.validate(current: await self.store.currentContext(for: context))
            let repo = self.repository, directory = self.directory
            let importer = GameArchiveProjectImporter(originalStore: try GameArchiveOriginalStore(directory: directory.appendingPathComponent("OriginalArchives")))
            let task = Task.detached {
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    return try await repo.importContents(from: url, into: project.projectID, owner: project.owner, expectedRevision: project.revision)
                }
                return try await importer.importIntoProject(archive: url, repository: repo, projectID: project.projectID, owner: project.owner,
                    expectedRevision: project.revision, workspace: directory.appendingPathComponent("ImportJobs")).project
            }
            let imported = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            self.project = imported; self.context = try await self.store.context(id: imported.projectID, owner: imported.owner)
            var recognitionNote = ""
            if let context = self.context {
                do {
                    let detected = try GameProjectInspector().inspect(context: context)
                    self.engine = detected.candidates.count == 1 ? detected.candidates.first?.engine : nil
                } catch {
                    self.engine = nil; recognitionNote = " 可继续整理文件后识别引擎。"
                }
            }
            self.status = "已完整导入 \(imported.files.count) 个文件；原始版本已保留。" + recognitionNote
        }
    }
    func openEditor() {
        perform {
            guard let project = self.project else { throw GameProjectError.invalidContext }
            let adapter: any GameEditingAdapter
            if let engine = self.engine, let rpg = RPGEngine(rawValue: engine.rawValue) { adapter = RPGEditingAdapter(engine: rpg) }
            else { adapter = GameUnknownEditingAdapter(engine: self.engine ?? .phaser) }
            let session = try await GameEditingSession.open(repository: self.repository, projectID: project.projectID, owner: project.owner, adapter: adapter)
            self.editor = .init(session: session)
        }
    }
    func edited() {
        perform {
            guard let project = self.project else { return }
            let saved = try await self.repository.open(project.projectID, owner: project.owner)
            self.project = saved
            self.context = try await self.store.context(id: project.projectID, owner: project.owner)
            self.status = "编辑结果已重新读取。"
            if self.engine == .rpgMakerMZ {
                let actorBytes = try await self.repository.read(saved.projectID, owner: saved.owner, revision: saved.revision, path: GameRelativePath("data/Actors.json"))
                let mapBytes = try await self.repository.read(saved.projectID, owner: saved.owner, revision: saved.revision, path: GameRelativePath("data/Map001.json"))
                guard let actors = try JSONSerialization.jsonObject(with: actorBytes) as? [Any], actors.count > 2,
                      let actor = actors[1] as? [String: Any], let other = actors[2] as? [String: Any],
                      let map = try JSONSerialization.jsonObject(with: mapBytes) as? [String: Any],
                      let tiles = map["data"] as? [Int] else { throw GameProjectError.invalidEdit }
                let eventJSON = String(decoding: mapBytes, as: UTF8.self)
                self.verificationSummary = "原始 JSON：名称=\(actor["name"] ?? "")；第二条目=\(other["name"] ?? "")；图块1=\(tiles.filter { $0 == 1 }.count)；保留=\((actor["unknown"] as? [String: Bool])?["keep"] == true)；事件=\(eventJSON.contains("Hello from QA"))"
            }
        }
    }
    func modifyContractFixture() {
        perform {
            guard let context = self.context else { throw GameProjectError.invalidContext }
            let result = try await self.authoring.edit(goal: "qualification: speed 240", context: context,
                sourcePaths: [GameRelativePath("game-config.json")], playtest: false)
            self.project = result.project; self.context = result.context
            self.status = "编辑闭环验证通过：速度已保存为 240。此步骤使用确定性模型替身。"
        }
    }
    func start() {
        perform {
            guard let context = self.context, let engine = self.engine else { throw GameProjectError.invalidContext }
            guard self.project?.files.contains(where: { $0.path.value == "index.html" }) == true else { self.status = "此数据示例未包含运行引擎。"; return }
            try await self.runController.run(context: context, engine: engine)
            guard let player = self.runController.player else { throw GameProjectError.invalidArtifact }
            let store = try GameTouchProfileStore(directory: self.directory.appendingPathComponent("TouchSettings"), projectID: context.projectID, owner: context.owner)
            guard let project = self.project, project.projectID == context.projectID,
                  project.revision == context.savedRevision else { throw GameProjectError.invalidContext }
            let inputPath = try GameRelativePath("floe-inputs.json")
            let inputBytes: Data?
            if let declaration = project.files.first(where: { $0.path == inputPath }) {
                guard declaration.bytes <= GameTouchProjectBindings.maximumDeclarationBytes else { throw GameProjectError.limitExceeded("floeInputs") }
                inputBytes = try await self.repository.read(context.projectID, owner: context.owner, revision: context.savedRevision, path: inputPath)
            } else { inputBytes = nil }
            let bindings = try inputBytes.map { try GameTouchProjectBindings(json: $0, engine: engine) }
            let defaults = GameTouchProfile.standard(engine, projectBindings: bindings)
            let saved = try await store.load(engine: engine, defaults: defaults); self.controlStore = store; self.controlRevision = saved.revision
            var profile = saved.profile
            // This test-only key validates physical DOM keyboard input. It is
            // not an invented action button in a product/default template.
            if saved.revision == 0 {
                profile.stick = .joystick
                let right = GameTouchButton(id: .a, binding: .key(.right), label: "→")
                if profile.button(id: .a) == nil { try profile.add(right) } else { try profile.update(right) }
                if profile.button(id: .b) == nil { try profile.add(.init(id: .b, binding: .key(.space))) }
            }
            let controls = GameTouchInputService(profile: profile)
            self.touchDispatch = "—"
            self.browserFeatures = "—"
            self.inputProbe = QualificationInputProbe(player: player) { [weak self] event in self?.touchDispatch = event }
            guard let runID = self.runController.activeRunID else { throw GameProjectError.invalidContext }
            self.x = "—"; self.score = "—"; self.play = .init(runID: runID, player: player, controls: controls, defaultControls: defaults)
            self.beginMonitor(player, controls: controls)
        }
    }
    func beginMonitor(_ player: GameWebPlayer, controls: GameTouchInputService) {
        monitor?.cancel(); let token = UUID(); monitoring = token
        monitor = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            while !Task.isCancelled, monitoring == token {
                if player.canSimulateInput, !controls.isAttached, let probe = inputProbe { await controls.attach(probe) }
                if browserFeatures == "—", player.loaded,
                   let features = try? await player.browserCapabilities(), monitoring == token {
                    browserFeatures = "WASM:\(features.webAssembly) JSPI:\(features.supportsJSPI)"
                }
                if player.gameReady, player.supportsState, let bytes = try? await player.snapshotState(), let state = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], monitoring == token {
                    x = String(format: "%.1f", (state["x"] as? Double) ?? 0); score = String((state["score"] as? Int) ?? 0)
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }
    func stop(runID: UUID? = nil) async {
        if let runID, runController.activeRunID != runID { return }
        monitoring = nil; monitor?.cancel(); monitor = nil
        if let play { await play.controls.detach(); if play.player.loaded { preview = try? await play.player.capturePNG() } }
        inputProbe = nil
        _ = await runController.stop(runID: runID); play = nil
    }
    func saveControls(_ profile: GameTouchProfile, controls: GameTouchInputService, runID: UUID) {
        guard let active = play, active.runID == runID, active.controls === controls,
              runController.activeRunID == runID, let store = controlStore else { return }
        let presentationID = active.id, expectedRevision = controlRevision
        perform {
            guard self.play?.id == presentationID, self.runController.activeRunID == runID else { return }
            // The captured store belongs to this run's project. A late save must
            // never resolve the mutable store of a subsequently opened project.
            let revision = try await store.save(profile, expectedRevision: expectedRevision)
            guard self.play?.id == presentationID, self.runController.activeRunID == runID else { return }
            await controls.updateProfile(profile)
            guard self.play?.id == presentationID, self.runController.activeRunID == runID else { return }
            self.controlRevision = revision; self.status = "键位设置已保存。"
        }
    }
    func loadHistory() {
        perform { guard let project = self.project else { return }; self.history = try await self.repository.history(project.projectID, owner: project.owner) }
    }
}

@MainActor private final class QualificationInputProbe: GameTouchInputSink {
    let player: GameWebPlayer
    let report: (String) -> Void
    init(player: GameWebPlayer, report: @escaping (String) -> Void) { self.player = player; self.report = report }
    func set(_ binding: GameTouchBinding, pressed: Bool) async throws {
        report("\(binding) \(pressed ? "down" : "up") pending")
        do {
            try await player.set(binding, pressed: pressed)
            report("\(binding) \(pressed ? "down" : "up")")
        } catch { report("\(binding): \(error)"); throw error }
    }
}
