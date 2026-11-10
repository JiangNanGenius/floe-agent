import Foundation
import Testing
import FloeLaTeXCore
import FloeLaTeXParsing
import FloeLaTeXEngine
import FloeExecution
import FloePersistence
@testable import FloeLaTeXHostAdapter

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [LaTeXPreparationProgress]()
    func add(_ value: LaTeXPreparationProgress) { lock.withLock { values.append(value) } }
    var snapshot: [LaTeXPreparationProgress] { lock.withLock { values } }
}
private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
private actor Admission {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
private actor ControlledTransport: LaTeXEnvironmentTransport {
    nonisolated let owner = LaTeXExecutionOwner(taskID: UUID(), runID: UUID(), environmentID: "controlled-linux-fixture")
    nonisolated let isLocal = true
    var files: Set<String> = ["article.cls"]
    var fonts = Set<String>()
    var programs: Set<String> = ["python3", "bwrap", "kpsewhich", "pdfinfo", "xelatex", "apt-file", "fc-list"]
    var actions = [String](), requestedPackages = [String](), requiredFiles = Set<String>()
    var noProgress = false, staleReceipt = false, unconfirmedInstall = false
    func configure(files: Set<String>? = nil, fonts: Set<String>? = nil, programs: Set<String>? = nil,
                   noProgress: Bool = false, staleReceipt: Bool = false, unconfirmedInstall: Bool = false) {
        if let files { self.files = files }; if let fonts { self.fonts = fonts }; if let programs { self.programs = programs }
        self.noProgress = noProgress; self.staleReceipt = staleReceipt; self.unconfirmedInstall = unconfirmedInstall
    }
    func authorize(relativePath: String) async throws { _ = try LaTeXPath.validate(relativePath) }
    private func input(_ script: String) throws -> [String: Any] {
        let regex = try NSRegularExpression(pattern: #"INPUT=json.loads\(base64.b64decode\('([A-Za-z0-9+/=]+)'\)\)"#)
        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        let match = try #require(regex.firstMatch(in: script, range: range))
        let data = try #require(Data(base64Encoded: (script as NSString).substring(with: match.range(at: 1))))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func execute(script: String, maximumOutputBytes: Int) async throws -> LaTeXEnvironmentCommandResult {
        try response(script, progress: { _ in })
    }
    func run(script: String, progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXEnvironmentCommandResult {
        try response(script, progress: progress)
    }
    private func response(_ script: String, progress: @Sendable (String) -> Void) throws -> LaTeXEnvironmentCommandResult {
        let input = try input(script), action = try #require(input["action"] as? String)
        actions.append(action)
        let result: [String: Any]
        switch action {
        case "probe":
            let requestedFiles = try #require(input["files"] as? [String]); requiredFiles.formUnion(requestedFiles)
            let missing = requestedFiles.filter { !programs.contains("kpsewhich") || !files.contains($0) }
            let requestedPrograms = try #require(input["programs"] as? [String])
            let requestedFonts = try #require(input["fonts"] as? [String])
            var missingPrograms = requestedPrograms.filter { !programs.contains($0) }
            if !requestedFonts.isEmpty, !programs.contains("fc-list") { missingPrograms.append("fc-list") }
            result = ["missingPrograms": missingPrograms, "missingFiles": missing,
                "missingFonts": requestedFonts.filter { !programs.contains("fc-list") || !fonts.contains($0) }, "resolved": Dictionary(uniqueKeysWithValues: requestedFiles.filter { files.contains($0) }.map { ("texFile:" + $0, "/usr/share/texlive/texmf-dist/tex/latex/fixture/" + $0) })]
        case "resolve": result = ["packages": ["texlive-latex-extra"], "unresolved": []]
        case "estimate": result = ["downloadBytes": 12345]
        case "install":
            let packages = try #require(input["packages"] as? [String]); requestedPackages += packages
            if unconfirmedInstall { return .init(stdout: "worker outcome unknown", exitStatus: -1, workerStopped: false) }
            if !noProgress {
                files.formUnion(requiredFiles); programs.formUnion(["biber", "bibtex", "makeindex", "fc-list", "kpsewhich"])
                fonts.formUnion(["Noto Serif CJK SC", "TeX Gyre Termes"])
            }
            progress("job details\nFLOE_LATEX_DOWNLOAD_BYTES 12345\n")
            result = ["packages": Dictionary(uniqueKeysWithValues: packages.map { ($0, "2026.fixture-1") }), "downloadBytes": 12345]
        case "versions":
            result = ["packages": Dictionary(uniqueKeysWithValues: (input["packages"] as? [String] ?? []).map { ($0, "2026.fixture-1") })]
        default: throw LaTeXError.invalidOperation(action)
        }
        let envelope: [String: Any] = ["protocolName": "floe.latex.dependencies", "version": 1, "projectID": input["projectID"]!,
            "revision": staleReceipt ? 999 : input["revision"]!, "inputDigest": input["inputDigest"]!, "result": result]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return .init(stdout: "exit=0 cwd=fixture\nFLOE_LATEX_DEPENDENCIES " + data.base64EncodedString() + "\n", exitStatus: 0, workerStopped: true)
    }
}
private actor ControlledEngine: LaTeXEngineRunning {
    var failures: [LaTeXEngineFailure]
    var requests = [LaTeXEngineRequest]()
    init(_ failures: [LaTeXEngineFailure] = []) { self.failures = failures }
    func capabilities() async -> [LaTeXEngineCapability] { [] }
    func run(_ request: LaTeXEngineRequest, progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXEngineOutput {
        requests.append(request)
        try FileManager.default.createDirectory(at: request.outputRoot, withIntermediateDirectories: true)
        try Data("original attempt log".utf8).write(to: request.outputRoot.appendingPathComponent("document.log"))
        if !failures.isEmpty { throw failures.removeFirst() }
        let output = request.outputRoot.appendingPathComponent("main.pdf")
        try Data("%PDF-1.7\nfixture".utf8).write(to: output)
        return .init(pdf: output, version: "controlled-engine", messages: ["actual fixture output"])
    }
}

@Suite("RQ29 resolved-environment preparation and compiler feedback", .serialized)
struct NextRoundLaTeXPreparationTests {
    private func fixture(_ source: String = #"\documentclass{article}\begin{document}Hello\end{document}"#) throws -> (LaTeXProjectManifest, LaTeXDependencyPlan) {
        var manifest = LaTeXProjectManifest(owner: .init(kind: .space, id: UUID()), title: "Preparation fixture")
        manifest.revision = 7; manifest.files = [.init(path: "main.tex", data: Data(source.utf8))]
        return (manifest, try LaTeXDependencyPlanner.plan(manifest: manifest, textFiles: ["main.tex": source]))
    }
    private func root() throws -> URL {
        let base = ProcessInfo.processInfo.environment["FLOE_RQ29_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeLaTeXPreparationTests", isDirectory: true)
        let root = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func request(_ manifest: LaTeXProjectManifest, root: URL, owner: LaTeXExecutionOwner, offline: Bool = false) -> LaTeXEngineRequest {
        .init(snapshot: .init(id: UUID(), manifest: manifest, sourceRoot: root.appendingPathComponent("Source"), fingerprint: "fixture"),
            outputRoot: root.appendingPathComponent("Output"), cacheRoot: root.appendingPathComponent("Cache"), configuration: .init(offline: offline), executionOwner: owner)
    }
    @Test("Installed resources are reused offline without installation authorization")
    func installedOffline() async throws {
        let (_, plan) = try fixture(), transport = ControlledTransport(), authorizations = Counter()
        let preparer = LaTeXDependencyPreparer(transport: transport) { await authorizations.increment() }
        let receipt = try await preparer.prepare(plan, offline: true, progress: { _ in })
        #expect(receipt.inputDigest == plan.inputDigest && receipt.revision == 7)
        #expect(receipt.environmentID == transport.owner.environmentID && !receipt.changedResources)
        #expect(await authorizations.value == 0)
        #expect(await transport.actions == ["probe"])
    }
    @Test("Offline missing resources name the actual missing content and do not start any installer")
    func missingOffline() async throws {
        let (_, plan) = try fixture(#"\documentclass{article}\usepackage{tikz}"#), transport = ControlledTransport(), counter = Counter()
        let preparer = LaTeXDependencyPreparer(transport: transport) { await counter.increment() }
        do { _ = try await preparer.prepare(plan, offline: true, progress: { _ in }); Issue.record("missing dependency unexpectedly succeeded") }
        catch { #expect(error.localizedDescription.contains("tikz.sty")) }
        #expect(await counter.value == 0)
        #expect(await transport.actions == ["probe"])
    }
    @Test("Only repository providers of actually missing project dependencies are installed, with byte/version receipts")
    func installMissingPackages() async throws {
        let (_, plan) = try fixture(#"\documentclass{article}\usepackage{tikz}"#), transport = ControlledTransport(), counter = Counter(), progress = ProgressRecorder()
        let preparer = LaTeXDependencyPreparer(transport: transport) { await counter.increment() }
        let receipt = try await preparer.prepare(plan, offline: false, progress: progress.add)
        #expect(await transport.requestedPackages == ["texlive-latex-extra"])
        #expect(receipt.resolved["texFile:tikz.sty"] != nil && receipt.installedPackages["texlive-latex-extra"] == "2026.fixture-1")
        #expect(receipt.changedResources && receipt.downloadBytes == 12345)
        #expect(progress.snapshot.contains(.init(stage: .downloading, downloadBytes: 12345)))
        #expect(await counter.value == 2)
    }
    @Test("Network/installation denial occurs before any repository or installation job")
    func deniedInstallation() async throws {
        let (_, plan) = try fixture(#"\documentclass{article}\usepackage{tikz}"#), transport = ControlledTransport()
        let preparer = LaTeXDependencyPreparer(transport: transport) { throw LaTeXError.unavailable("network denied fixture") }
        await #expect(throws: LaTeXError.self) { _ = try await preparer.prepare(plan, offline: false, progress: { _ in }) }
        #expect(await transport.actions == ["probe"])
    }
    @Test("A missing proprietary/unmapped font is actionable and is never silently substituted")
    func unknownFont() async throws {
        let (_, plan) = try fixture(#"\documentclass{article}\setmainfont{Unknown Licensed Family}"#), transport = ControlledTransport(), counter = Counter()
        let preparer = LaTeXDependencyPreparer(transport: transport) { await counter.increment() }
        do { _ = try await preparer.prepare(plan, offline: false, progress: { _ in }); Issue.record("missing font succeeded") }
        catch { #expect(error.localizedDescription.contains("Unknown Licensed Family")) }
        #expect(await counter.value == 0)
        #expect(await transport.actions == ["probe"])
    }
    @Test("Known Chinese fonts use their real provider then must pass the installed-name probe")
    func knownChineseFont() async throws {
        let (_, plan) = try fixture(#"\documentclass{article}\setCJKmainfont{Noto Serif CJK SC}"#), transport = ControlledTransport()
        let preparer = LaTeXDependencyPreparer(transport: transport) {}
        let receipt = try await preparer.prepare(plan, offline: false, progress: { _ in })
        #expect(await transport.requestedPackages == ["fonts-noto-cjk"])
        #expect(receipt.changedResources)
    }
    @Test("An unchanged missing set stops after one attempted repair and retains the true failure")
    func noProgressStops() async throws {
        let (_, plan) = try fixture(#"\documentclass{article}\usepackage{tikz}"#), transport = ControlledTransport()
        await transport.configure(noProgress: true)
        let preparer = LaTeXDependencyPreparer(transport: transport) {}
        await #expect(throws: LaTeXError.self) { _ = try await preparer.prepare(plan, offline: false, progress: { _ in }) }
        #expect(await transport.actions == ["probe", "resolve", "estimate", "install", "probe"])
    }
    @Test("A missing font lookup is prepared before judging whether a licensed font is absent")
    func prepareFontLookupBeforeFontDecision() async throws {
        let (_, plan) = try fixture(#"\documentclass{article}\setmainfont{Licensed Installed Family}"#), transport = ControlledTransport()
        await transport.configure(fonts: ["Licensed Installed Family"], programs: ["python3", "bwrap", "kpsewhich", "pdfinfo", "xelatex", "apt-file"])
        let preparer = LaTeXDependencyPreparer(transport: transport) {}
        _ = try await preparer.prepare(plan, offline: false, progress: { _ in })
        #expect(await transport.requestedPackages == ["fontconfig"])
        #expect(await transport.actions == ["probe", "install", "probe", "versions"])
    }
    @Test("A missing file lookup is prepared before assuming installed TeX files require another package")
    func prepareKpathseaBeforeRepositoryLookup() async throws {
        let (_, plan) = try fixture(), transport = ControlledTransport()
        await transport.configure(programs: ["python3", "bwrap", "pdfinfo", "xelatex", "apt-file", "fc-list"])
        let preparer = LaTeXDependencyPreparer(transport: transport) {}
        _ = try await preparer.prepare(plan, offline: false, progress: { _ in })
        #expect(await transport.requestedPackages == ["texlive-binaries"])
        #expect(await transport.actions == ["probe", "install", "probe", "versions"])
    }
    @Test("A stale revision receipt is rejected before it can advertise installed content")
    func staleReceiptRejected() async throws {
        let (_, plan) = try fixture(), transport = ControlledTransport()
        await transport.configure(staleReceipt: true)
        let preparer = LaTeXDependencyPreparer(transport: transport) {}
        await #expect(throws: LaTeXError.self) { _ = try await preparer.prepare(plan, offline: false, progress: { _ in }) }
    }
    @Test("Unconfirmed installer exit remains unknown rather than successful or retryable")
    func unknownInstallerOutcome() async throws {
        let (_, plan) = try fixture(#"\documentclass{article}\usepackage{tikz}"#), transport = ControlledTransport()
        await transport.configure(unconfirmedInstall: true)
        let preparer = LaTeXDependencyPreparer(transport: transport) {}
        do { _ = try await preparer.prepare(plan, offline: false, progress: { _ in }); Issue.record("unknown worker succeeded") }
        catch let failure as LaTeXEngineFailure { #expect(!failure.workerStopped) }
    }
    @Test("Cancel while awaiting installation authorization cannot begin a package side effect")
    func cancellationBeforeJob() async throws {
        let (_, plan) = try fixture(#"\documentclass{article}\usepackage{tikz}"#), transport = ControlledTransport(), gate = Admission()
        let preparer = LaTeXDependencyPreparer(transport: transport) { await gate.wait() }
        let task = Task { try await preparer.prepare(plan, offline: false, progress: { _ in }) }
        while !(await gate.started) { await Task.yield() }
        task.cancel(); await gate.open()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await transport.actions == ["probe"])
    }
    @Test("Compiler feedback prepares a new indirect dependency then continues the same input in a fresh output directory")
    func compilerFeedback() async throws {
        let (manifest, plan) = try fixture(), transport = ControlledTransport(), directory = try root()
        let preparer = LaTeXDependencyPreparer(transport: transport) {}
        let receipt = try await preparer.prepare(plan, offline: false, progress: { _ in })
        let first = ControlledEngine([.init("LaTeX Error: File `indirect.sty' not found.", messages: ["original compiler failure"])]), next = ControlledEngine()
        let engine = LaTeXPreparedEngine(plan: plan, initialReceipt: receipt, initialEngine: first, preparer: preparer, makeEngine: { next }, preparationProgress: { _ in })
        let operation = request(manifest, root: directory, owner: transport.owner)
        let output = try await engine.run(operation, progress: { _ in })
        #expect(output.pdf.path.contains("attempt-02"))
        #expect(output.messages.contains("original compiler failure"))
        #expect(await first.requests.count == 1)
        #expect(await next.requests.count == 1)
        #expect(FileManager.default.fileExists(atPath: operation.outputRoot.appendingPathComponent("attempt-01/document.log").path))
        #expect(FileManager.default.fileExists(atPath: operation.outputRoot.appendingPathComponent("DependencyFailure-01.json").path))
        #expect(await next.requests.first?.snapshot.manifest == manifest)
    }
    @Test("An unconfirmed compiler worker is never followed by installation or another compiler")
    func unconfirmedCompilerNeverRetries() async throws {
        let (manifest, plan) = try fixture(), transport = ControlledTransport(), directory = try root()
        let preparer = LaTeXDependencyPreparer(transport: transport) {}
        let receipt = try await preparer.prepare(plan, offline: false, progress: { _ in })
        let first = ControlledEngine([.init("File `indirect.sty' not found.", workerStopped: false)]), next = ControlledEngine()
        let engine = LaTeXPreparedEngine(plan: plan, initialReceipt: receipt, initialEngine: first, preparer: preparer, makeEngine: { next }, preparationProgress: { _ in })
        do { _ = try await engine.run(request(manifest, root: directory, owner: transport.owner), progress: { _ in }); Issue.record("unknown compiler succeeded") }
        catch let failure as LaTeXEngineFailure { #expect(!failure.workerStopped) }
        #expect(await transport.actions == ["probe"])
        #expect(await next.requests.isEmpty)
    }
    @Test("Revision change after preparation cannot compile or install using the old input")
    func revisionFence() async throws {
        var (manifest, plan) = try fixture(); let transport = ControlledTransport(), directory = try root()
        let preparer = LaTeXDependencyPreparer(transport: transport) {}
        let receipt = try await preparer.prepare(plan, offline: false, progress: { _ in }), underlying = ControlledEngine()
        let engine = LaTeXPreparedEngine(plan: plan, initialReceipt: receipt, initialEngine: underlying, preparer: preparer, makeEngine: { underlying }, preparationProgress: { _ in })
        manifest.revision += 1
        await #expect(throws: LaTeXError.self) { _ = try await engine.run(request(manifest, root: directory, owner: transport.owner), progress: { _ in }) }
        #expect(await underlying.requests.isEmpty)
    }
    @Test("A syntax error without a new dependency does not trigger any automatic install or retry")
    func genuineCompilerErrorPreserved() async throws {
        let (manifest, plan) = try fixture(), transport = ControlledTransport(), directory = try root()
        let preparer = LaTeXDependencyPreparer(transport: transport) {}
        let receipt = try await preparer.prepare(plan, offline: false, progress: { _ in })
        let first = ControlledEngine([.init("Undefined control sequence", messages: ["original failure text"])]), next = ControlledEngine()
        let engine = LaTeXPreparedEngine(plan: plan, initialReceipt: receipt, initialEngine: first, preparer: preparer, makeEngine: { next }, preparationProgress: { _ in })
        do { _ = try await engine.run(request(manifest, root: directory, owner: transport.owner), progress: { _ in }); Issue.record("syntax error succeeded") }
        catch let failure as LaTeXEngineFailure { #expect(failure.message == "Undefined control sequence" && failure.messages.contains("original failure text")) }
        #expect(await transport.actions == ["probe"])
        #expect(await next.requests.isEmpty)
    }
    private func spooled(_ text:String,directory:URL,captureTruncated:Bool=false)throws->BackgroundJob {
        let id=UUID()
        let saved=try #require(BackgroundJobOutputSpool.write(jobID:id,text:text,root:directory,captureTruncated:captureTruncated))
        return BackgroundJob(id:id,conversationID:UUID(),runID:UUID(),kind:.tool,targetTool:"exec.shell",payloadJSON:Data(),state:.completed,
            resultSummary:NativeJobTextLimits.bounded(text),resultDigest:LaTeXDigest.hash(Data(text.utf8)),outputPath:saved.path,outputBytes:saved.bytes)
    }
    @Test("A long real job spool retains the terminal resource receipt beyond the display summary")
    func completeJobSpool() throws {
        let directory=try root()
        let text="exit=0 cwd=fixture\n"+String(repeating:"原始进度🙂\n",count:6000)+"FLOE_LATEX_DEPENDENCIES final-resource-receipt\n"
        let job=try spooled(text,directory:directory)
        #expect(job.resultSummary?.contains("final-resource-receipt")==false)
        #expect(try LaTeXShellTransport.canonicalOutput(for:job,root:directory)==text)
    }
    @Test("A foreign or changed spool cannot supply another operation's preparation receipt")
    func foreignOrChangedSpool() throws {
        let directory=try root(),text="exit=0 cwd=fixture\nFLOE_LATEX_DEPENDENCIES original\n"
        var job=try spooled(text,directory:directory)
        let ownID=job.id;job.id=UUID()
        #expect(throws:LaTeXEngineFailure.self) {_ = try LaTeXShellTransport.canonicalOutput(for:job,root:directory)}
        job.id=ownID
        let path=try #require(job.outputPath),handle=try FileHandle(forWritingTo:URL(fileURLWithPath:path))
        try handle.seekToEnd();try handle.write(contentsOf:Data("changed".utf8));try handle.close()
        #expect(throws:LaTeXEngineFailure.self) {_ = try LaTeXShellTransport.canonicalOutput(for:job,root:directory)}
    }
    @Test("Producer truncation remains incomplete even when its saved prefix contains a plausible success marker")
    func truncatedSpoolNeverClaimsSuccess() throws {
        let directory=try root(),text="exit=0 cwd=fixture\nFLOE_LATEX_DEPENDENCIES plausible\n"
        let job=try spooled(text,directory:directory,captureTruncated:true)
        #expect(throws:LaTeXEngineFailure.self) {_ = try LaTeXShellTransport.canonicalOutput(for:job,root:directory)}
    }
}
