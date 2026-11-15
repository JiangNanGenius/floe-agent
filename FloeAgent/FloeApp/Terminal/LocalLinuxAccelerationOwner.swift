// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation
import FloeCore
import FloeExecution
import FloeTools

/// File/device presence, deliberately separate from successful backend probes.
struct LinuxAccelerationInventory: Decodable, Sendable, Equatable {
    struct Graphics: Decodable, Sendable, Equatable {
        var deviceNodePresent: Bool
        var inspectorInstalled: Bool
        // Optional so an older installed dispatcher's schemaVersion 1 JSON
        // still decodes. Absent means "older image did not report this".
        var renderNodePresent: Bool?
        var cardNodePresent: Bool?
        var renderNodeCount: Int?
        var cardNodeCount: Int?
        var glxInspectorInstalled: Bool?
        var eglInspectorInstalled: Bool?
        var eglLibraryInstalled: Bool?
        var glProbeInstalled: Bool?
    }
    struct Video: Decodable, Sendable, Equatable {
        var clientInstalled: Bool
        var decoderNodePresent: Bool
        var encoderNodePresent: Bool
        var videoNodeCount: Int?
    }
    struct Compute: Decodable, Sendable, Equatable {
        var runnerInstalled: Bool
        var probeInstalled: Bool
        var providerInstalled: Bool
        var openCLLoaderInstalled: Bool?
        var openCLICDCount: Int?
        var openCLProbeInstalled: Bool?
        var openCLCompilerInstalled: Bool?
    }
    struct Blender: Decodable, Sendable, Equatable {
        var launcherInstalled: Bool
        var applicationInstalled: Bool
    }
    var schemaVersion: Int
    var graphics: Graphics
    var video: Video
    var compute: Compute
    var blender: Blender
}

/// App-lifetime owner beside the terminal. Short queries are cancellable;
/// Blender has its own managed shell session and never receives terminal input.
@MainActor @Observable
final class LocalLinuxAccelerationOwner {
    enum Diagnostic: Equatable {
        case graphics, openGL, headlessOpenGL, video, compute, openCL, openCLProbe, blender
        var arguments: [String] {
            switch self {
            case .graphics: ["graphics", "status"]
            case .openGL: ["graphics", "info"]
            case .headlessOpenGL: ["graphics", "egl"]
            case .video: ["video", "list", "--json"]
            case .compute: ["compute", "probe", "--size", "512"]
            case .openCL: ["compute", "opencl", "status"]
            case .openCLProbe: ["compute", "opencl", "probe", "--device", "any", "--size", "1024"]
            case .blender: ["blender", "status", "--json"]
            }
        }
        var timeout: TimeInterval {
            switch self {
            case .compute, .openCLProbe: 90
            default: 30
            }
        }
    }

    private let root: URL
    private let conversationID: UUID?
    private let sessions: ShellSessionCenter
    private let runID = UUID()
    private var queryGeneration = UUID()
    private var queryToken = CancellationToken()
    private var installGeneration = UUID()
    private var launchGeneration = UUID()
    private var launchToken = CancellationToken()
    private var blenderSessionID: String?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    private(set) var inventory: LinuxAccelerationInventory?
    private(set) var inventoryEnvironmentID: String?
    private(set) var isBusy = false
    private(set) var installing = false
    private(set) var launching = false
    private(set) var blenderRunning = false
    private(set) var activeEnvironmentID: String?
    private(set) var message: String?
    private(set) var details = ""
    private(set) var blenderOutput = ""

    init(root: URL, sessions: ShellSessionCenter, conversationID: UUID?) {
        self.root = root
        self.sessions = sessions
        self.conversationID = conversationID
    }

    func refresh(environmentID: String) async {
        // A newly selected environment must not lose its refresh while the
        // previous view's cancelled request is still unwinding its lease.
        cancelActiveQuery()
        inventory = nil
        inventoryEnvironmentID = nil
        let result = await query(environmentID: environmentID, arguments: ["status", "--json"], timeout: 20)
        guard let result else { return }
        do {
            let status = try JSONDecoder().decode(LinuxAccelerationInventory.self, from: Data(result.stdout.utf8))
            guard status.schemaVersion == 1 else { throw FloeError.validationFailed("Unsupported acceleration status version") }
            inventory = status
            inventoryEnvironmentID = environmentID
        } catch {
            inventory = nil
            inventoryEnvironmentID = nil
            message = IDELanguageRunText.t("无法读取加速状态。", "Could not read acceleration status.")
            details = Self.bounded(result.stdout + "\n" + result.stderr)
        }
    }

    func diagnose(_ diagnostic: Diagnostic, environmentID: String) async {
        _ = await query(environmentID: environmentID, arguments: diagnostic.arguments, timeout: diagnostic.timeout)
    }

    func setComputeMode(_ mode: String, environmentID: String) async {
        guard ["off", "auto", "on"].contains(mode) else { return }
        if await query(environmentID: environmentID, arguments: ["compute", "mode", mode], timeout: 20) != nil {
            message = IDELanguageRunText.t("设置已更新。", "Settings updated.")
        }
    }

    /// Installs the release-owned acceleration toolkit into the current
    /// environment. It never requests GPU success and never changes the
    /// environment identity; the ordinary probes keep working without it.
    @discardableResult
    func installTools(environmentID: String) async -> Bool {
        guard !isBusy else { return false }
        let generation = UUID()
        installGeneration = generation
        installing = true
        defer { if installGeneration == generation { installing = false } }
        guard let result = await query(environmentID: environmentID, arguments: ["install-tools"], timeout: 180) else {
            if !Task.isCancelled, message == nil {
                message = IDELanguageRunText.t("安装未完成，请查看详情。", "Installation did not complete. See details.")
            }
            return false
        }
        guard result.exitCode == 0 else { return false }
        guard installGeneration == generation, !Task.isCancelled else { return false }
        await refresh(environmentID: environmentID)
        guard installGeneration == generation, inventoryEnvironmentID == environmentID, inventory != nil else {
            return false
        }
        message = IDELanguageRunText.t("加速工具已安装。", "Acceleration tools installed.")
        return true
    }

    private func query(environmentID: String, arguments: [String], timeout: TimeInterval) async -> LinuxCommandResult? {
        guard !isBusy else { return nil }
        let generation = UUID(), token = CancellationToken()
        queryGeneration = generation; queryToken = token
        isBusy = true; message = nil
        defer { if queryGeneration == generation { isBusy = false } }
        do {
            guard let runner = FloePlatformServices.shared.linuxCommandRunner(),
                  await runner.ownsLinuxEnvironment(environmentID: environmentID),
                  await runner.supports(environmentID: environmentID) else {
                throw FloeError.validationFailed(IDELanguageRunText.t("请先启动这个 Linux 环境。", "Start this Linux environment first."))
            }
            // The installer is provided by the release owner. It receives the
            // fixed internal request and supplies both argv and stdin; the
            // ordinary diagnostics keep using the bundled dispatcher.
            let install = arguments == ["install-tools"] ? try LocalLinuxAccelerationInstaller.command() : nil
            let lease = try await acquireEnvironment(environmentID, token: token)
            let result: LinuxCommandResult
            do {
                let command = try install?.argv ?? Self.guestArguments(arguments)
                result = try await withTaskCancellationHandler {
                    try await runner.run(environmentID: environmentID,
                        argv: command,
                        workingDirectory: nil, standardInput: install?.standardInput, timeout: timeout,
                        maxOutputBytes: 32 * 1024, cancellation: token)
                } onCancel: { token.cancel() }
                await lease.finish()
            } catch {
                await lease.finish()
                throw error
            }
            guard queryGeneration == generation, !token.isCancelled, !Task.isCancelled else { return nil }
            details = Self.bounded(result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr))
            guard result.exitCode == 0 else {
                message = IDELanguageRunText.t("这项功能目前不可用，请查看详情。", "This feature is currently unavailable. See details.")
                if result.exitCode == 127 {
                    message = IDELanguageRunText.t("请更新 Linux 组件后重试。", "Update the Linux component and try again.")
                }
                return nil
            }
            return result
        } catch {
            guard queryGeneration == generation, !token.isCancelled, !Task.isCancelled else { return nil }
            message = IDELanguageRunText.t("操作未完成，请查看详情。", "The operation did not complete. See details.")
            details = Self.bounded(error.localizedDescription)
            return nil
        }
    }

    private func cancelActiveQuery() {
        queryToken.cancel()
        queryGeneration = UUID()
        isBusy = false
    }

    func cancelQuery() {
        cancelActiveQuery()
        installGeneration = UUID()
        installing = false
    }

    func launchBlender(display: LocalLinuxDisplayOwner, software: Bool) async {
        guard !launching else { return }
        guard display.isLinuxGuest, let environmentID = display.environmentID else { return }
        if blenderRunning {
            if activeEnvironmentID != environmentID {
                message = IDELanguageRunText.t("Blender 正在另一个环境中运行。", "Blender is running in another environment.")
            }
            return
        }
        let generation = UUID(), token = CancellationToken()
        launchGeneration = generation; launchToken = token
        launching = true; activeEnvironmentID = environmentID; message = nil
        defer { if launchGeneration == generation { launching = false } }
        do {
            guard let runner = FloePlatformServices.shared.linuxCommandRunner(),
                  await runner.ownsLinuxEnvironment(environmentID: environmentID) else {
                throw FloeError.validationFailed("A local Linux environment is required")
            }
            display.onLocalDemand?()
            await display.startDisplay()
            guard launchGeneration == generation, !token.isCancelled else { return }
            guard case .ready = display.state else {
                throw FloeError.validationFailed(IDELanguageRunText.t("屏幕未能打开。", "The screen could not be opened."))
            }
            guard display.environmentID == environmentID else {
                throw FloeError.validationFailed("The resolved Linux environment changed")
            }
            let lease = try await acquireEnvironment(environmentID, token: token)
            let opened: ShellOpenResult
            do {
                guard await runner.ownsLinuxEnvironment(environmentID: environmentID),
                      await runner.supports(environmentID: environmentID) else {
                    throw FloeError.validationFailed("The Linux environment is no longer available")
                }
                // Fixed command only. Guest DISPLAY comes from the SAME
                // project's existing runner; never override it with :0.
                let backend = software ? "software" : "gpu"
                opened = try await sessions.open(
                    command: "if [ -x /usr/local/bin/floe-accel ]; then exec /usr/local/bin/floe-accel blender open --backend "
                        + backend + "; fi\nexec floe-blender open --backend " + backend,
                    cwd: ".", environment: [:], columns: 100, rows: 30, runID: runID,
                    rootURL: root, cancellation: token, toolEnvironment: lease.context.environment,
                    conversationID: conversationID)
                await lease.finish()
            } catch {
                await lease.finish()
                throw error
            }
            guard launchGeneration == generation, !token.isCancelled else {
                await sessions.close(sessionID: opened.sessionID, runID: runID)
                return
            }
            blenderSessionID = opened.sessionID
            blenderRunning = opened.alive
            blenderOutput = Self.bounded(opened.initialOutput)
            if opened.alive { startMonitoring(sessionID: opened.sessionID, generation: generation, token: token) }
            else {
                await sessions.close(sessionID: opened.sessionID, runID: runID)
                blenderSessionID = nil
                message = IDELanguageRunText.t("Blender 未能启动，请查看详情。", "Blender did not start. See details.")
                details = blenderOutput
            }
        } catch {
            guard launchGeneration == generation, !token.isCancelled else { return }
            message = IDELanguageRunText.t("Blender 未能启动，请查看详情。", "Blender did not start. See details.")
            details = Self.bounded(error.localizedDescription)
        }
    }

    private func startMonitoring(sessionID: String, generation: UUID, token: CancellationToken) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled, !token.isCancelled {
                guard let self, self.launchGeneration == generation else { return }
                do {
                    let result = try await self.sessions.exchange(sessionID: sessionID, input: nil,
                        waitMs: 1000, maxBytes: 16 * 1024, runID: self.runID, cancellation: token)
                    guard self.launchGeneration == generation else { return }
                    self.blenderOutput = Self.bounded(self.blenderOutput + result.output)
                    if !result.alive {
                        self.blenderRunning = false; self.blenderSessionID = nil
                        self.details = self.blenderOutput
                        if let code = result.exitCode, code != 0 {
                            self.message = IDELanguageRunText.t("Blender 已结束，请查看详情。", "Blender stopped. See details.")
                        }
                        await self.sessions.close(sessionID: sessionID, runID: self.runID)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    guard self.launchGeneration == generation else { return }
                    self.blenderRunning = false; self.blenderSessionID = nil
                    if !token.isCancelled {
                        self.message = IDELanguageRunText.t("Blender 连接已结束。", "The Blender connection ended.")
                        self.details = Self.bounded(error.localizedDescription)
                    }
                    await self.sessions.close(sessionID: sessionID, runID: self.runID)
                    return
                }
            }
        }
    }

    func stopBlender(environmentID: String? = nil) async {
        if let environmentID, activeEnvironmentID != environmentID { return }
        launchToken.cancel(); launchGeneration = UUID()
        monitorTask?.cancel(); monitorTask = nil
        let sessionID = blenderSessionID
        blenderSessionID = nil; blenderRunning = false; launching = false
        if let sessionID { await sessions.close(sessionID: sessionID, runID: runID) }
        activeEnvironmentID = nil
    }

    private func acquireEnvironment(_ environmentID: String, token: CancellationToken) async throws -> ToolEnvironmentLease {
        try token.throwIfCancelled()
        let context = ToolContext(runID: runID, workspaceRootURL: root, cancellation: token,
            environmentID: environmentID, conversationID: conversationID)
        let lease = try await ToolEnvironmentRouting.shared.acquire(context)
        guard lease.context.environment?.id == environmentID else {
            await lease.finish()
            throw FloeError.validationFailed("The resolved Linux environment changed")
        }
        return lease
    }

    private static func bounded(_ value: String) -> String {
        String(decoding: SecretRedactor.redact(value).utf8.suffix(32 * 1024), as: UTF8.self)
    }

    /// Older guest images can report their actual devices and installed tools
    /// with the same dispatcher. Run it in the selected guest without installing
    /// anything onto its disk. Arguments remain distinct from the shell source.
    private static func guestArguments(_ arguments: [String]) throws -> [String] {
        guard let url = Bundle.main.url(forResource: "floe-accel", withExtension: nil) else {
            throw FloeError.validationFailed(IDELanguageRunText.t("无法读取加速工具。", "Could not load the acceleration tool."))
        }
        let dispatcher = try String(contentsOf: url, encoding: .utf8)
        // Older images may still carry an older installed dispatcher. Use it
        // only when its own help advertises the requested entry; otherwise the
        // App-bundled dispatcher provides the newer OpenGL/OpenCL commands
        // without changing the guest's installed files.
        let preferInstalled = #"""
        token="$1"
        case "$token" in
            graphics|compute) [ "$#" -ge 2 ] && token="$1 $2" ;;
        esac
        if [ -x /usr/local/bin/floe-accel ] \
           && /usr/local/bin/floe-accel --capabilities 2>/dev/null | grep -F -- "floe-accel-api: 2" >/dev/null 2>&1 \
           && /usr/local/bin/floe-accel --help 2>/dev/null | grep -F -- "$token" >/dev/null 2>&1; then
            exec /usr/local/bin/floe-accel "$@"
        fi
        """#
        return ["/bin/sh", "-c", preferInstalled + "\n" + dispatcher, "floe-accel"] + arguments
    }
}
