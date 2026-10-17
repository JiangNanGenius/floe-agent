// Real service qualification, not a model or UI test. Opt-in only: the
// production pinned Linux image may be downloaded on first activation.
// Run this suite serially with other real-guest tests; it owns only the
// canonical project environment for its unique workspace root.
#if canImport(UIKit) && DEBUG
import Foundation
import Testing
import UserNotifications
import FloeCore
import FloeExecution
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeApp

@Suite("FloeApp.LocalLinuxStaticServiceRealVM", .serialized)
@MainActor struct LocalLinuxStaticServiceRealVMTests {
    // Operational cleanup for one explicitly identified, obsolete fixture.
    // Disabled in normal qualification; never scan or remove user environments.
    @Test("remove one explicitly owned stopped qualification layer through production lifecycle",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_OWNED_QA_CLEANUP"] == "1"))
    func cleanupExplicitStoppedQualificationLayer() async throws {
        let values = ProcessInfo.processInfo.environment
        let id = try #require(values["FLOE_OWNED_QA_ENVIRONMENT_ID"])
        let owner = try #require(values["FLOE_OWNED_QA_OWNER_SHA256"])
        try #require(UUID(uuidString: id) != nil && owner.count == 64
                     && owner.allSatisfy { "0123456789abcdef".contains($0) })
        let app = AppEnvironment.live()
        await app.bootstrap()
        try #require(app.persistenceReady)
        let registry = app.environmentRegistry
        // App bootstrap opens persistence; the environment registry is loaded
        // lazily by execution. This explicit maintenance path must load it too.
        try await registry.prepare()
        let record = try #require(await registry.record(id: id))
        let name = try #require(record.name)
        try #require(record.kind == .project && record.state == .stopped && record.ownerID == owner)
        try #require(name.hasPrefix("subagent-guest-")
                     && UUID(uuidString: String(name.dropFirst("subagent-guest-".count))) != nil)
        let workspace = try #require(try await registry.workspaceRoot(for: id))
        try #require(workspace.lastPathComponent == name
                     && !FileManager.default.fileExists(atPath: workspace.path))
        let layer = try #require(await registry.layerURL(for: id))
        try #require(layer.lastPathComponent == id && layer.deletingLastPathComponent().lastPathComponent == "Containers")
        let mappingURL = layer.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("workspace-containers.json")
        let mappingBefore = try JSONDecoder().decode([String: [String: String]].self,
                                                     from: Data(contentsOf: mappingURL))
        try #require(mappingBefore[owner]?["containerID"] == id)
        let otherIDs = await registry.all().filter { $0.id != id }.map(\.id)
        let services = FloePlatformServices.shared
        try await services.stopEnvironment(id: id)
        let stopped = try #require(await services.linuxGuestStatus(id: id))
        try #require(!stopped.running)
        try await services.deleteEnvironment(id: id)
        try #require(await registry.record(id: id) == nil)
        try #require(!FileManager.default.fileExists(atPath: layer.path))
        let mappingAfter = try JSONDecoder().decode([String: [String: String]].self,
                                                    from: Data(contentsOf: mappingURL))
        try #require(!mappingAfter.values.contains { $0["containerID"] == id })
        for (key, value) in mappingBefore where value["containerID"] != id {
            #expect(mappingAfter[key] == value)
        }
        for otherID in otherIDs { #expect(await registry.record(id: otherID) != nil) }
        #expect(await services.linuxGuestStatus(id: id)?.running != true)
        print("FLOE_OWNED_QA_CLEANUP_VERIFIED id=\(id) otherRecordsPreserved=\(otherIDs.count)")
    }

    private struct Progress: Decodable {
        var state: String
        var previewURL: String?
    }

    private func ownedEnvironment(root: URL, app: AppEnvironment) async throws -> String? {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let owner = FloeDigest.sha256Hex(Data(canonical.path.utf8))
        let matches = await app.environmentRegistry.containersOwned(by: owner)
            .filter { $0.kind == .project && $0.state != .deleting }
        guard matches.count <= 1 else {
            throw FloeError.validationFailed("Qualification workspace has multiple project environments; none was selected")
        }
        return matches.first?.id
    }

    private func waitForTerminal(_ jobs: BackgroundJobService, id: UUID, seconds: TimeInterval = 90) async throws -> BackgroundJob {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let job = try await jobs.job(id: id), job.state.isTerminal { return job }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FloeError.validationFailed("Own service did not acknowledge exit; preserve its environment and workspace")
    }

    private func waitForPreview(_ jobs: BackgroundJobService, id: UUID) async throws -> URL {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            guard let job = try await jobs.job(id: id) else { throw FloeError.notFound("Qualification job disappeared") }
            if job.state.isTerminal {
                throw FloeError.validationFailed("Static service ended before readiness: \(job.lastError ?? job.state.rawValue)")
            }
            if let data = job.progressJSON,
               let progress = try? JSONDecoder().decode(Progress.self, from: data),
               progress.state == "running", let value = progress.previewURL, let url = URL(string: value) {
                return url
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw FloeError.validationFailed("Static HTML readiness deadline exceeded; inspect the one existing job, do not resubmit")
    }

    private func fetch(_ url: URL, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FloeError.validationFailed("Preview did not return HTTP") }
        return (data, http)
    }

    // Separate opt-in from offline/service qualification: public network is
    // not a prerequisite for those already-proven lifecycle tests. This uses
    // controlled public PyPI, never copies an account's configured index.
    @Test("real guest diagnoses public package network stages and imports an installed Office package set",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_NETWORK_PIP_QUALIFICATION"] == "1"))
    func networkOfficePipStagedDiagnosis() async throws {
        let app = try await appQualificationEnvironment()
        let jobs = try #require(app.backgroundJobService)
        let services = FloePlatformServices.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("network-pip-real-vm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversationID = UUID(), runID = UUID()
        var environmentID: String?
        var jobIDs: [UUID] = []
        var recordsCreated = false
        var evidence = ["kind": "real-network-pip-stages-not-model-not-ui",
                        "root": root.path, "index": "https://pypi.org/simple",
                        "versions": "python-pptx==1.0.2 openpyxl==3.1.5 python-docx==1.2.0",
                        "limit": "binary wheels only; no source build or implicit retry; not the unknown original index",
                        "budgetPolicy": "python startup 30s; pip cold import 120s; network command 120s including imports, operation DNS12/TLS15/index15s"]
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let evidenceDirectory = support.appendingPathComponent("FloeAgent/QualificationEvidence/NetworkPip", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let evidenceURL = evidenceDirectory.appendingPathComponent(conversationID.uuidString + ".json")
        func retain(_ stage: String) throws {
            evidence["stage"] = stage
            evidence["observedAt"] = ISO8601DateFormatter().string(from: Date())
            try JSONEncoder().encode(evidence).write(to: evidenceURL, options: .atomic)
        }
        func stage(_ name: String, command: String, timeout: Int) async throws {
            let id = try #require(environmentID)
            evidence[name + ".effectiveTimeoutRequested"] = String(timeout)
            try retain(name + ".submitting-once")
            let started = Date()
            let job = try await jobs.submit(runID: runID,
                toolCallID: "network-pip-" + name + "-" + UUID().uuidString,
                targetTool: "exec.shell",
                payloadJSON: JSONSerialization.data(withJSONObject: ["command": command, "cwd": ".",
                    "timeout": timeout, "maxOutputBytes": 24_576]),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
                environmentID: id, waitForCompletion: false)
            jobIDs.append(job.id)
            evidence[name + ".jobID"] = job.id.uuidString
            try retain(name + ".running")
            let terminal = try await waitForTerminal(jobs, id: job.id, seconds: Double(timeout) + 45)
            evidence[name + ".durationSeconds"] = String(Date().timeIntervalSince(started))
            evidence[name + ".state"] = terminal.state.rawValue
            // Production shell output has already passed its bounded redactor
            // before BackgroundJobService stores this result. No raw env/config.
            evidence[name + ".output"] = terminal.resultSummary ?? terminal.lastError ?? "No output"
            try retain(name + ".terminal")
            try #require(terminal.state == .completed,
                "Network pip stage failed: \(name); retained evidence: \(evidenceURL.path)")
            try #require(terminal.resultSummary?.contains("effectiveTimeoutSeconds=\(timeout)") == true,
                "Stage did not report its real effective command limit")
        }
        func cleanup() async throws {
            for id in jobIDs {
                guard let job = try await jobs.job(id: id) else {
                    throw FloeError.validationFailed("Network qualification job missing; preserve owned guest until reconciled")
                }
                if !job.state.isTerminal { _ = try await jobs.cancel(id: id) }
                _ = try await waitForTerminal(jobs, id: id)
            }
            let ownID: String?
            if let id = environmentID { ownID = id }
            else { ownID = try await ownedEnvironment(root: root, app: app) }
            if let id = ownID {
                try await services.stopEnvironment(id: id)
                guard let status = await services.linuxGuestStatus(id: id), !status.running else {
                    throw FloeError.validationFailed("Network qualification guest stop unconfirmed; preserve owned layer")
                }
                try await services.deleteEnvironment(id: id)
            }
            if recordsCreated { try await app.conversationStore.deleteConversation(id: conversationID) }
            let center = UNUserNotificationCenter.current()
            let notificationIDs = jobIDs.map { "jobs." + $0.uuidString }
            center.removePendingNotificationRequests(withIdentifiers: notificationIDs)
            center.removeDeliveredNotifications(withIdentifiers: notificationIDs)
            try FileManager.default.removeItem(at: root)
        }
        do {
            let date = Date()
            try await app.conversationStore.saveConversation(ConversationRecord(id: conversationID,
                title: "Network package qualification", createdAt: date, updatedAt: date, titleOrigin: .manual))
            recordsCreated = true
            try await app.database.writer { database in
                try database.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', 'Synthetic network package diagnosis', ?)",
                    arguments: [runID.uuidString, conversationID.uuidString, ISO8601DateFormatter().string(from: date)])
            }
            try retain("preparing-own-guest")
            try await services.prepareWorkspaceEnvironment(root: root)
            environmentID = try await ownedEnvironment(root: root, app: app)
            let id = try #require(environmentID)
            evidence["environmentID"] = id
            try await services.activateLinuxGuestWithPreparation(id: id, cancellation: CancellationToken())
            try await stage("python-startup", command: #"""
            set -e
            mkdir -p /workspace/qualification/home /workspace/qualification/wheels /workspace/qualification/site
            python3 -u -c 'import sys,platform,ssl;print("PYTHON",sys.version);print("ARCH",platform.machine());print("TLS",ssl.OPENSSL_VERSION)'
            """#, timeout: 30)
            // The first actual run printed Python/architecture/OpenSSL, then
            // hit the old shared 30s deadline while pip imported platformdirs.
            // Isolate that CPU/import work: no network, retry or install here.
            try await stage("pip-startup", command: #"""
            env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/workspace/qualification/home PIP_CONFIG_FILE=/dev/null python3 -u - <<'PY'
            import sys,time
            start=time.monotonic()
            print('PIP_STARTUP_BEGIN',flush=True)
            import runpy
            sys.argv=['pip','--isolated','--disable-pip-version-check','--version']
            try:
                runpy.run_module('pip',run_name='__main__')
            finally:
                print('PIP_STARTUP_ELAPSED_SECONDS',round(time.monotonic()-start,3),flush=True)
            PY
            """#, timeout: 120)
            // Each Python network probe has the existing normal 120s command
            // budget for cold imports plus bounded operations. IMPORT_READY
            // precedes all DNS/transport work, whose own deadlines are separate.
            try await stage("dns", command: #"""
            python3 -u - <<'PY'
            import time
            startup=time.monotonic()
            print('DNS_PYTHON_START',flush=True)
            import socket,signal
            print('DNS_IMPORT_READY','startupSeconds',round(time.monotonic()-startup,3),flush=True)
            def deadline(signum,frame):
                raise TimeoutError('DNS_LOOKUP_DEADLINE_12_SECONDS')
            signal.signal(signal.SIGALRM,deadline)
            for host in ('pypi.org','files.pythonhosted.org'):
                start=time.monotonic()
                print('DNS_LOOKUP_BEGIN',host,'operationBudgetSeconds',12,flush=True)
                signal.alarm(12)
                try:
                    addresses=socket.getaddrinfo(host,443,type=socket.SOCK_STREAM)
                    assert addresses,'DNS returned no addresses'
                    print('DNS_OK',host,'addressCount',len(addresses),'seconds',round(time.monotonic()-start,3),flush=True)
                finally:
                    signal.alarm(0)
            PY
            """#, timeout: 120)
            try await stage("tls", command: #"""
            python3 -u - <<'PY'
            import time
            startup=time.monotonic()
            print('TLS_PYTHON_START',flush=True)
            import socket,ssl,signal
            context=ssl.create_default_context()
            print('TLS_IMPORT_AND_CA_READY','startupSeconds',round(time.monotonic()-startup,3),flush=True)
            def deadline(signum,frame):
                raise TimeoutError('TLS_OPERATION_DEADLINE_15_SECONDS')
            signal.signal(signal.SIGALRM,deadline)
            for host in ('pypi.org','files.pythonhosted.org'):
                start=time.monotonic()
                print('TLS_OPERATION_BEGIN',host,'operationBudgetSeconds',15,'socketTimeoutSeconds',10,flush=True)
                signal.alarm(15)
                try:
                    with socket.create_connection((host,443),timeout=10) as raw:
                        with context.wrap_socket(raw,server_hostname=host) as connection:
                            print('TLS_VERIFIED',host,connection.version(),'seconds',round(time.monotonic()-start,3),flush=True)
                finally:
                    signal.alarm(0)
            PY
            """#, timeout: 120)
            try await stage("index", command: #"""
            python3 -u - <<'PY'
            import time
            startup=time.monotonic()
            print('INDEX_PYTHON_START',flush=True)
            import urllib.request,signal
            opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
            print('INDEX_IMPORT_READY','startupSeconds',round(time.monotonic()-startup,3),flush=True)
            def deadline(signum,frame):
                raise TimeoutError('INDEX_OPERATION_DEADLINE_15_SECONDS')
            signal.signal(signal.SIGALRM,deadline)
            for package in ('python-pptx','openpyxl','python-docx'):
                start=time.monotonic()
                print('INDEX_REQUEST_BEGIN',package,'operationBudgetSeconds',15,'socketTimeoutSeconds',12,flush=True)
                request=urllib.request.Request('https://pypi.org/simple/'+package+'/',headers={'Accept':'application/vnd.pypi.simple.v1+html'})
                signal.alarm(15)
                try:
                    with opener.open(request,timeout=12) as response:
                        prefix=response.read(8192)
                        assert response.status==200 and b'href=' in prefix,'Unexpected index response'
                        print('INDEX_OK',package,'status',response.status,'sampleBytes',len(prefix),'seconds',round(time.monotonic()-start,3),flush=True)
                finally:
                    signal.alarm(0)
            PY
            """#, timeout: 120)
            // Clear inherited index/proxy settings without reading or printing
            // them. --only-binary prohibits a lengthy riscv64 lxml source build.
            let pip = "env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/workspace/qualification/home PIP_CONFIG_FILE=/dev/null python3 -u -m pip --isolated --disable-pip-version-check --no-input --no-cache-dir"
            let pins = "python-pptx==1.0.2 openpyxl==3.1.5 python-docx==1.2.0"
            try await stage("direct-wheel-download", command: pip + " download --index-url https://pypi.org/simple --retries 0 --timeout 15 --progress-bar off --only-binary=:all: --no-deps --dest /workspace/qualification/wheels " + pins, timeout: 180)
            // This stage may honestly fail with a missing compatible dependency
            // wheel. Do not retry, compile a replacement, or call that a network
            // timeout. Its real pip error is preserved in the stage receipt.
            try await stage("dependency-wheel-download", command: pip + " download --index-url https://pypi.org/simple --retries 0 --timeout 15 --progress-bar off --only-binary=:all: --find-links /workspace/qualification/wheels --dest /workspace/qualification/wheels " + pins, timeout: 300)
            try await stage("install", command: pip + " install --no-index --only-binary=:all: --find-links /workspace/qualification/wheels --target /workspace/qualification/site " + pins, timeout: 180)
            // Separate process: installation success alone does not prove usable
            // modules or that the requested versions resolve from our target.
            try await stage("independent-import", command: #"""
            python3 -u - <<'PY'
            import sys,pathlib,importlib,importlib.metadata,hashlib
            target=pathlib.Path('/workspace/qualification/site').resolve()
            sys.path.insert(0,str(target))
            for module,distribution,version in (('pptx','python-pptx','1.0.2'),('openpyxl','openpyxl','3.1.5'),('docx','python-docx','1.2.0')):
                imported=importlib.import_module(module)
                path=pathlib.Path(imported.__file__).resolve()
                assert target in path.parents,'Import resolved outside own install target'
                actual=importlib.metadata.version(distribution)
                assert actual==version,(distribution,actual,version)
                print('IMPORT_VERIFIED',distribution,actual,'sha256',hashlib.sha256(path.read_bytes()).hexdigest(),flush=True)
            for path in sorted(pathlib.Path('/workspace/qualification/wheels').glob('*.whl')):
                print('WHEEL_SHA256',path.name,hashlib.sha256(path.read_bytes()).hexdigest(),flush=True)
            PY
            """#, timeout: 60)
            try retain("all-stages-verified")
            try await cleanup()
            evidence["cleanup"] = "own jobs terminal; own guest stopped/deleted; synthetic conversation/root removed"
            try retain("completed-and-cleaned")
            print("FLOE_NETWORK_PIP_EVIDENCE=" + evidenceURL.path)
        } catch {
            evidence["failure"] = String(describing: error)
            try? retain("failed-preserved")
            do { try await cleanup(); evidence["cleanup"] = "completed" }
            catch { evidence["cleanupFailure"] = String(describing: error); Issue.record("Own network pip cleanup incomplete; preserve workspace: \(root.path)") }
            try? retain("failed-cleanup-recorded")
            print("FLOE_NETWORK_PIP_FAILURE_EVIDENCE=" + evidenceURL.path)
            throw error
        }
    }

    @Test("offline tiny wheel installs through the real job and timed-out shell preserves output after child cleanup",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1"))
    func offlinePipAndTimeoutOutputLifecycle() async throws {
        let app = AppEnvironment.live()
        await app.bootstrap()
        try #require(app.persistenceReady)
        let jobs = try #require(app.backgroundJobService)
        let services = FloePlatformServices.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pip-real-vm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversationID = UUID(), runID = UUID()
        var environmentID: String?, jobID: UUID?
        var recordsCreated = false
        var evidence = ["kind": "real-offline-pip-and-timeout-not-model-not-ui", "root": root.path]

        func runShell(_ command: String, timeout: Double) async throws -> ToolExecutionOutput {
            let id = try #require(environmentID)
            let context = ToolContext(runID: runID, toolCallID: "pip-qualification-" + UUID().uuidString,
                allowedToolNames: ["exec.shell"], workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: id, conversationID: conversationID)
            let lease = try await ToolEnvironmentRouting.shared.acquire(context)
            do {
                let tool = LocalShellTool(shell: app.localShellService)
                let args = LocalShellTool.Arguments(command: command, cwd: ".", timeout: timeout, maxOutputBytes: 16_384)
                try tool.validate(args)
                let output = try await tool.execute(args, context: lease.context)
                await lease.finish()
                return output
            } catch { await lease.finish(); throw error }
        }
        func cleanup() async throws {
            if let id = jobID, let job = try await jobs.job(id: id), !job.state.isTerminal {
                _ = try await jobs.cancel(id: id)
                _ = try await waitForTerminal(jobs, id: id)
            }
            if let id = environmentID {
                try await services.stopEnvironment(id: id)
                guard let status = await services.linuxGuestStatus(id: id), !status.running else {
                    throw FloeError.validationFailed("Pip qualification guest stop not confirmed; preserve owned layer")
                }
                try await services.deleteEnvironment(id: id)
            }
            if recordsCreated { try await app.conversationStore.deleteConversation(id: conversationID) }
            if let id = jobID {
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: ["jobs." + id.uuidString])
                center.removeDeliveredNotifications(withIdentifiers: ["jobs." + id.uuidString])
            }
            try FileManager.default.removeItem(at: root)
        }
        do {
            let date = Date()
            try await app.conversationStore.saveConversation(ConversationRecord(id: conversationID,
                title: "Offline pip qualification", createdAt: date, updatedAt: date, titleOrigin: .manual))
            recordsCreated = true
            try await app.database.writer { database in
                try database.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', 'Synthetic offline pip qualification', ?)",
                    arguments: [runID.uuidString, conversationID.uuidString, ISO8601DateFormatter().string(from: date)])
            }
            try await services.prepareWorkspaceEnvironment(root: root)
            environmentID = try await ownedEnvironment(root: root, app: app)
            let id = try #require(environmentID)
            evidence["environmentID"] = id
            try await services.activateLinuxGuestWithPreparation(id: id, cancellation: CancellationToken())
            // No network, package source lookup, venv bootstrap or download.
            let fixtureCommand = #"""
            set -e
            python3 -m pip --version
            python3 - <<'PY'
            import base64,hashlib,zipfile
            files={
              'floe_install_probe/__init__.py':b'VALUE = "FLOE_PIP_QUALIFICATION_OK"\n',
              'floe_install_probe-0.0.1.dist-info/METADATA':b'Metadata-Version: 2.1\nName: floe-install-probe\nVersion: 0.0.1\n',
              'floe_install_probe-0.0.1.dist-info/WHEEL':b'Wheel-Version: 1.0\nGenerator: FloeSyntheticQualification\nRoot-Is-Purelib: true\nTag: py3-none-any\n'
            }
            records=[]
            for path,data in files.items():
                digest=base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
                records.append(f'{path},sha256={digest},{len(data)}\n')
            record='floe_install_probe-0.0.1.dist-info/RECORD'
            files[record]=(''.join(records)+record+',,\n').encode()
            with zipfile.ZipFile('floe_install_probe-0.0.1-py3-none-any.whl','w') as z:
                for path,data in files.items():z.writestr(path,data)
            print('OFFLINE_WHEEL_READY')
            PY
            """#
            let prepared = try await runShell(fixtureCommand, timeout: 120)
            evidence["preflight"] = prepared.summary
            try #require(prepared.exitStatus == 0 && prepared.summary.contains("OFFLINE_WHEEL_READY"), "Real pip prerequisite/fixture failed")
            let wheel = root.appendingPathComponent("floe_install_probe-0.0.1-py3-none-any.whl")
            let wheelBytes = try Data(contentsOf: wheel)
            try #require(wheelBytes.count < 10_240)
            evidence["wheelSHA256"] = FloeDigest.sha256Hex(wheelBytes)
            let install = #"""
            set -e
            python3 -m pip install --no-index --no-deps --disable-pip-version-check --target /workspace/qualification/site /workspace/floe_install_probe-0.0.1-py3-none-any.whl
            python3 -c 'import sys,importlib.metadata;sys.path.insert(0,"/workspace/qualification/site");import floe_install_probe;assert floe_install_probe.VALUE=="FLOE_PIP_QUALIFICATION_OK";assert importlib.metadata.version("floe-install-probe")=="0.0.1";print("OFFLINE_PIP_IMPORT_OK",floe_install_probe.__file__)'
            """#
            let job = try await jobs.submit(runID: runID, toolCallID: "pip-install-once-" + UUID().uuidString,
                targetTool: "exec.shell", payloadJSON: JSONSerialization.data(withJSONObject: ["command": install, "timeout": 180, "maxOutputBytes": 16_384]),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [], environmentID: id, waitForCompletion: false)
            jobID = job.id; evidence["jobID"] = job.id.uuidString
            let finished = try await waitForTerminal(jobs, id: job.id, seconds: 210)
            evidence["installResult"] = finished.resultSummary ?? finished.lastError ?? finished.state.rawValue
            try #require(finished.state == .completed, "Offline pip job failed: \(evidence["installResult"] ?? "unknown")")
            try #require(finished.resultSummary?.contains("OFFLINE_PIP_IMPORT_OK") == true)
            try #require(finished.resultSummary?.contains("effectiveTimeoutSeconds=180") == true)
            let installed = root.appendingPathComponent("qualification/site/floe_install_probe/__init__.py")
            evidence["installedSHA256"] = FloeDigest.sha256Hex(try Data(contentsOf: installed))
            let reopened = try await runShell("PYTHONPATH=/workspace/qualification/site python3 -c 'import floe_install_probe;assert floe_install_probe.VALUE==\"FLOE_PIP_QUALIFICATION_OK\";print(\"REOPEN_IMPORT_OK\")'", timeout: 30)
            try #require(reopened.exitStatus == 0 && reopened.summary.contains("REOPEN_IMPORT_OK"))
            let timeoutCommand = #"""
            python3 -u - <<'PY'
            import pathlib,subprocess,sys,time
            child=subprocess.Popen([sys.executable,'-c','import pathlib,time;time.sleep(8);pathlib.Path("/workspace/child-late").write_text("UNEXPECTED_LATE_CHILD")'])
            pathlib.Path('/workspace/child.pid').write_text(str(child.pid))
            print('TIMEOUT_PROGRESS_MARKER',flush=True)
            print('TIMEOUT_STDERR_MARKER',file=sys.stderr,flush=True)
            time.sleep(20)
            PY
            """#
            let timed = try await runShell(timeoutCommand, timeout: 5)
            evidence["timeoutResult"] = timed.summary
            try #require(timed.exitStatus == 124 && timed.summary.contains("status=timedOut"))
            try #require(timed.summary.contains("effectiveTimeoutSeconds=5"))
            try #require(timed.summary.contains("TIMEOUT_PROGRESS_MARKER") && timed.summary.contains("TIMEOUT_STDERR_MARKER"))
            // Outwait the child's intentional late write, then inspect only
            // its recorded PID. No killing/inspection of unrelated processes.
            try await Task.sleep(for: .seconds(9))
            let checked = try await runShell(#"python3 -c 'import pathlib;pid=int(pathlib.Path("/workspace/child.pid").read_text());assert not pathlib.Path("/proc/"+str(pid)).exists(),"owned child still exists";assert not pathlib.Path("/workspace/child-late").exists(),"owned child escaped timeout";print("CHILD_CLEANUP_CONFIRMED")'"#, timeout: 30)
            evidence["childCheck"] = checked.summary
            try #require(checked.exitStatus == 0 && checked.summary.contains("CHILD_CLEANUP_CONFIRMED"))
            if let data = try? JSONEncoder().encode(evidence) { print("FLOE_PIP_REALVM " + String(decoding: data, as: UTF8.self)) }
            try await cleanup()
            print("FLOE_PIP_REALVM_CLEANUP_OK")
        } catch {
            evidence["failure"] = String(describing: error)
            if let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                let folder = base.appendingPathComponent("FloeAgent/QualificationEvidence/OfflinePip")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try JSONEncoder().encode(evidence).write(to: folder.appendingPathComponent(conversationID.uuidString + ".json"), options: .atomic)
                } catch { Issue.record("Offline pip failure evidence could not be retained: \(error)") }
            }
            do { try await cleanup() } catch { Issue.record("Offline pip cleanup incomplete; preserve own workspace: \(error)") }
            throw error
        }
    }

    @Test("real guest static service serves nested Unicode HTML and relative CSS, survives observer close, and exits on cancel",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1"))
    func staticHTMLNestedResourcesLifecycle() async throws {
        let app = AppEnvironment.live()
        await app.bootstrap()
        try #require(app.persistenceReady, "Production persistence bootstrap failed")
        let jobs = try #require(app.backgroundJobService, "Production job service is unavailable")
        let services = FloePlatformServices.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("static-real-vm-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversationID = UUID(), runID = UUID()
        var environmentID: String?
        var jobID: UUID?
        var observer: Task<Void, Never>?
        var recordsCreated = false
        var evidence: [String: String] = ["kind": "real-service-not-model-not-ui", "root": root.path]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        func retainEvidence(_ phase: String) {
            evidence["phase"] = phase
            if let data = try? JSONEncoder().encode(evidence) {
                try? data.write(to: root.appendingPathComponent("qualification-evidence.json"), options: .atomic)
                print("FLOE_STATIC_REALVM " + String(decoding: data, as: UTF8.self))
            }
        }

        func retainFailureEvidence() {
            guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true) else { return }
            let directory = base.appendingPathComponent("FloeAgent/QualificationEvidence/StaticServices", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(conversationID.uuidString + ".json")
                try JSONEncoder().encode(evidence).write(to: file, options: .atomic)
                print("FLOE_STATIC_REALVM_FAILURE_EVIDENCE=" + file.path)
            } catch { Issue.record("Could not retain synthetic service failure evidence: \(error)") }
        }

        // Async cleanup is explicitly awaited on both paths. No unstructured
        // defer Task can outlive the test and delete a still-mounted share.
        func cleanup() async throws {
            if let poller = observer {
                poller.cancel(); await poller.value; observer = nil
            }
            if let id = jobID {
                guard let job = try await jobs.job(id: id) else {
                    throw FloeError.validationFailed("Own submitted job is missing; preserve its environment until its worker is reconciled")
                }
                if !job.state.isTerminal { _ = try await jobs.cancel(id: id) }
                _ = try await waitForTerminal(jobs, id: id)
            }
            let ownID: String?
            if let id = environmentID { ownID = id }
            else { ownID = try await ownedEnvironment(root: root, app: app) }
            if let id = ownID {
                try await services.stopEnvironment(id: id)
                guard let status = await services.linuxGuestStatus(id: id), !status.running else {
                    throw FloeError.validationFailed("Own guest stop was not confirmed; preserve its layer")
                }
                try await services.deleteEnvironment(id: id)
            }
            if recordsCreated {
                try await app.conversationStore.deleteConversation(id: conversationID)
            }
            if let id = jobID {
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: ["jobs." + id.uuidString])
                center.removeDeliveredNotifications(withIdentifiers: ["jobs." + id.uuidString])
            }
            try FileManager.default.removeItem(at: root)
        }

        do {
            let date = Date()
            try await app.conversationStore.saveConversation(ConversationRecord(id: conversationID,
                title: "Static service qualification", createdAt: date, updatedAt: date, titleOrigin: .manual))
            recordsCreated = true
            let started = ISO8601DateFormatter().string(from: date)
            try await app.database.writer { database in
                try database.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', 'Synthetic static service qualification', ?)",
                    arguments: [runID.uuidString, conversationID.uuidString, started])
            }
            let relativeEntry = "嵌套 demo/页面 目录/预览 页面.html"
            let relativeCSS = "资源 子目录/配色 样式.css"
            let html = "<!doctype html><meta charset='utf-8'><link rel='stylesheet' href='\(relativeCSS)'><h1>FLOE_STATIC_REALVM_中文</h1>"
            let css = "h1 { color: rgb(17, 53, 97); } /* FLOE_STATIC_CSS_中文 */"
            let entry = root.appendingPathComponent(relativeEntry)
            let cssFile = entry.deletingLastPathComponent().appendingPathComponent(relativeCSS)
            try FileManager.default.createDirectory(at: cssFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(html.utf8).write(to: entry, options: .atomic)
            try Data(css.utf8).write(to: cssFile, options: .atomic)
            retainEvidence("workspace-ready")

            try await services.prepareWorkspaceEnvironment(root: root)
            environmentID = try await ownedEnvironment(root: root, app: app)
            let id = try #require(environmentID, "No own project environment was prepared")
            evidence["environmentID"] = id
            retainEvidence("activating-own-guest")
            try await services.activateLinuxGuestWithPreparation(id: id, cancellation: CancellationToken())
            try #require(await services.linuxEnvironmentAvailable(id: id), "Own guest did not become usable")

            // One submission only. A port conflict is a recorded test failure,
            // never a reason to secretly resubmit or restart another service.
            let port = Int.random(in: 20_000...45_000)
            let invocation = LocalServiceTool.Arguments(runtime: "static", entry: relativeEntry,
                arguments: [], cwd: "嵌套 demo/页面 目录", port: port)
            let submitted = try await jobs.submit(runID: runID, toolCallID: "static-qualification-" + UUID().uuidString,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(invocation), scope: .local,
                workspaceRootURL: root, allowedWorkspacePaths: [], environmentID: id,
                waitForCompletion: false)
            jobID = submitted.id; evidence["jobID"] = submitted.id.uuidString
            retainEvidence("submitted-once")
            let preview = try await waitForPreview(jobs, id: submitted.id)
            evidence["previewURL"] = preview.absoluteString
            try #require(preview.host == "127.0.0.1" && preview.port == port)
            #expect(preview.lastPathComponent == "预览 页面.html")
            let (htmlData, htmlResponse) = try await fetch(preview, session: session)
            try #require(htmlResponse.statusCode == 200)
            #expect(htmlData == Data(html.utf8))
            let cssReference = try #require(relativeCSS.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
            let cssURL = try #require(URL(string: cssReference, relativeTo: preview)?.absoluteURL)
            let (cssData, cssResponse) = try await fetch(cssURL, session: session)
            try #require(cssResponse.statusCode == 200)
            #expect(cssData == Data(css.utf8))
            evidence["htmlSHA256"] = FloeDigest.sha256Hex(htmlData)
            evidence["cssSHA256"] = FloeDigest.sha256Hex(cssData)
            retainEvidence("html-css-verified")

            // A consumer/observer owns polling only, not the service task.
            // This is intentionally not a SwiftUI/view-lifetime UI test.
            observer = Task { @MainActor in
                while !Task.isCancelled {
                    _ = try? await jobs.job(id: submitted.id)
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
            }
            try await Task.sleep(for: .milliseconds(250))
            if let poller = observer { poller.cancel(); await poller.value; observer = nil }
            let (stillData, stillResponse) = try await fetch(preview, session: session)
            #expect(stillResponse.statusCode == 200 && stillData == htmlData)
            #expect(try await jobs.job(id: submitted.id)?.state.isTerminal == false)
            retainEvidence("observer-closed-service-alive")

            _ = try await jobs.cancel(id: submitted.id)
            let terminal = try await waitForTerminal(jobs, id: submitted.id)
            try #require(terminal.state == .cancelled, "Cancellation did not finish honestly: \(terminal.state.rawValue)")
            evidence["terminalState"] = terminal.state.rawValue
            let deadline = Date().addingTimeInterval(15)
            var accessible = true
            repeat {
                do { _ = try await fetch(preview, session: session); accessible = true }
                catch { accessible = false }
                if !accessible { break }
                try await Task.sleep(for: .milliseconds(250))
            } while Date() < deadline
            try #require(!accessible, "Cancelled service still has an accessible endpoint")
            retainEvidence("cancel-exit-endpoint-closed")
            try await cleanup()
            print("FLOE_STATIC_REALVM_CLEANUP_OK conversation=\(conversationID) job=\(submitted.id)")
        } catch {
            evidence["failure"] = String(describing: error)
            // Capture the OWN synthetic worker's guest-side log before cleanup.
            // A blank host 9p tail alone is not proof of no process error.
            if let id = environmentID, let ownJob = jobID, let runner = services.linuxCommandRunner() {
                do {
                    let diagnostic = try await runner.run(environmentID: id,
                        argv: ["/bin/sh", "-c", #"printf 'OWN_SERVICE_LOG\n'; cat "$1"; printf '\nPYTHON_CHECK\n'; python3 -c 'import sys,http.server; print(sys.version)'"#,
                               "static-qualification-diagnostic", "/floe/env/services/" + ownJob.uuidString + ".log"],
                        workingDirectory: "/workspace", standardInput: nil, timeout: 30,
                        maxOutputBytes: 16_384, cancellation: CancellationToken())
                    evidence["guestDiagnostic"] = String(describing: diagnostic)
                } catch { evidence["guestDiagnosticError"] = String(describing: error) }
            }
            retainEvidence("failed")
            retainFailureEvidence()
            do { try await cleanup() }
            catch {
                evidence["cleanupFailure"] = String(describing: error)
                retainEvidence("cleanup-preserved")
                retainFailureEvidence()
                Issue.record("Own service cleanup incomplete; retained qualification workspace: \(root.path)")
            }
            throw error
        }
    }
}
#endif
