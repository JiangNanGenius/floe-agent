// SPDX-License-Identifier: MPL-2.0
//
// FloeAppTests — the user-required REAL-ASSISTANT Office + Notes-cover
// qualification for the current release round (lane R, task-lifecycle
// 2026-10-15; baseline 923b1e48).
//
// What this file is for
// ---------------------
// The release gate requires the ACTUAL configured assistant (a real provider
// through the real `FloeAgentRuntime`, the real registered tool catalog and
// the ordinary task authorization) to edit real editable OOXML in the
// Simulator and to change a Notes document cover through the real
// `notes.cover` tool — not synthetic model responses, canned JSON, mocks or
// tool-success strings.
//
// This file contains two suites:
//
//   * `FloeApp.OfficeAssistantQualification` — deterministic App-host checks
//     that need no provider. They pin the exact tool ceiling the live runs
//     use, the file-level stale-expectedSHA refusal contract and the honest
//     "formulas stay formulas; the package-level writer never fabricates a
//     cached result" behavior of created workbooks. They run in every
//     ordinary `FloeAppTests` pass.
//
//   * `FloeApp.LiveOfficeAssistantQualification` — four provider scenarios,
//     DISABLED unless `FLOE_LIVE_OFFICE_QUALIFICATION=1` and a private
//     credential reference is supplied (see below). Each scenario uses its
//     own synthetic, task-owned fixtures, drives the real runtime, and
//     verifies the produced bytes with an INDEPENDENT reader (ZIPFoundation +
//     XMLParser + CryptoKit, never the product's own Office/Notes readers).
//
// Routes exercised (labelled per scenario)
// ----------------------------------------
//   * file-level editable OOXML: `document.createWord`,
//     `document.office.inspect`, `document.office.updateText` through the
//     registered FloeDocuments tools;
//   * engine route: `document.office.edit` propose/apply on a document that
//     the test opened in a real, visible `OfficeFileSession` (the same
//     session the visible editor mounts), which publishes a verified edited
//     copy through the service-owned engine session (`engineReopen`,
//     `formulaSummary`, `sourceUnchanged` in the receipt);
//   * internal Notes assistant: `notes.read` + `notes.cover`
//     read -> set -> read -> restore against a real isolated `NotesStore`
//     with a real `assistant_scopes` grant minted through the store's own
//     binding API (never a fabricated `confirmed` argument).
//
// Credential reference (no secret is ever stored in this file)
// ------------------------------------------------------------
// The provider is resolved at run time from ONE of these references:
//   * `FLOE_LIVE_QUALIFICATION_CONFIG` — path to a private JSON file (kept
//     outside the repository) shaped:
//       { "providerKind": "custom"|"openAI", "wireProtocol":
//         "openAIChatCompletions", "baseURL": "https://…", "model": "…",
//         "apiKeyPath": "/private/path/key.txt" }  // or "apiKey": "…"
//   * `FLOE_LIVE_WORKBUDDY_MODELS` (+ `FLOE_LIVE_WORKBUDDY_MODEL_ID`) —
//     path to the already-authorized WorkBuddy `models.json` array; the
//     entry's `id`/`apiKey`/`url` are read in memory.
// The key is never printed, never written into fixtures and never logged;
// evidence records only the model id and the endpoint host.
//
// Honest limits
// -------------
//   * Live scenarios are PENDING until G2 executes them with the reference;
//     a skipped live suite is zero live evidence.
//   * `word.bulletList`/`word.numberedList`/`word.style`/`word.alignment`
//     are selection-relative engine commands and are refused for automatic
//     copy execution by design; this matrix covers Chinese paragraphs plus
//     the supported structure operation `word.insertTable`.
//   * Cached formula results require the engine recalculation route; the
//     package-level writer intentionally writes `<f>` without a fake `<v>`.
//   * Auto reasoning (auxiliary-model classifier, S lane) is deliberately
//     OUT of this gate: the scenarios pin a plain text+tools `ModelProfile`
//     (no auto-reasoning capability, no optional override) and assert only
//     the real main-run tool calls and their artifacts. They make no
//     assumption about provider HTTP requests or rounds per turn, and they
//     must not be used as auto-reasoning acceptance; an auxiliary call, if
//     ever enabled by a different default, is invisible to this evidence.
//   * Physical-device acceptance remains the user's.

#if canImport(UIKit) && canImport(FloeOfficeNative)
import Foundation
import Testing
import UIKit
import SwiftUI
import Crypto
import ZIPFoundation
import FloeCore
import FloeModels
import FloeTools
import FloeDocuments
import FloeNotes
import FloeProviders
import FloeAgentRuntime
import FloeSecurity
@testable import FloeApp

// MARK: - Live scope, credential reference and shared helpers

/// Live opt-in scope plus the non-secret helpers every live scenario shares.
private enum LiveOfficeQualification {
    static let enabledEnvironmentKey = "FLOE_LIVE_OFFICE_QUALIFICATION"
    static let configPathEnvironmentKey = "FLOE_LIVE_QUALIFICATION_CONFIG"
    static let workBuddyModelsEnvironmentKey = "FLOE_LIVE_WORKBUDDY_MODELS"
    static let workBuddyModelEnvironmentKey = "FLOE_LIVE_WORKBUDDY_MODEL_ID"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[enabledEnvironmentKey] == "1"
    }

    /// The exact executable tool ceiling the live scenarios rely on. The
    /// deterministic suite fails fast when any of these is not registered in
    /// the App host, so a live run can never "pass" because a tool was
    /// silently missing.
    static let wordFileLevelTools: Set<String> = [
        "document.createWord", "document.office.inspect", "document.office.updateText"
    ]
    static let wordEngineTools: Set<String> = ["document.office.edit"]
    static let excelFileLevelTools: Set<String> = [
        "document.office.inspect", "document.office.updateText"
    ]
    static let excelEngineTools: Set<String> = ["document.office.edit"]
    static let presentationFileLevelTools: Set<String> = [
        "document.office.inspect", "document.office.updateText"
    ]
    static let presentationEngineTools: Set<String> = ["document.office.edit"]
    static let coverTools: Set<String> = ["notes.read", "notes.cover"]

    static let allExpectedToolNames: [String] = Array(
        wordFileLevelTools
            .union(wordEngineTools)
            .union(excelFileLevelTools)
            .union(presentationFileLevelTools)
            .union(coverTools)
    ).sorted()

    struct ProviderReference: Sendable {
        var kind: ProviderKind
        var wireProtocol: ModelProtocol
        var baseURL: URL
        var remoteModelID: String
        var apiKey: String
    }

    enum ReferenceError: Error, CustomStringConvertible {
        case missing(String)
        case malformed(String)

        var description: String {
            switch self {
            case .missing(let detail): return detail
            case .malformed(let detail): return detail
            }
        }
    }

    /// Resolves the authorized provider reference from the environment. The
    /// key is returned in memory only; callers must never log it.
    static func providerReference() throws -> ProviderReference {
        let environment = ProcessInfo.processInfo.environment
        if let configPath = environment[configPathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configPath.isEmpty {
            return try providerReference(fromConfigPath: configPath)
        }
        if let modelsPath = environment[workBuddyModelsEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelsPath.isEmpty {
            return try providerReference(fromWorkBuddyModelsPath: modelsPath, environment: environment)
        }
        throw ReferenceError.missing(
            "No live qualification credential reference is configured. Set "
                + "\(configPathEnvironmentKey)=/private/path/config.json or "
                + "\(workBuddyModelsEnvironmentKey)=/private/path/models.json with "
                + "\(workBuddyModelEnvironmentKey)=<model id>, then re-run with "
                + "\(enabledEnvironmentKey)=1. The key itself is never passed in this file."
        )
    }

    private static func providerReference(fromConfigPath path: String) throws -> ProviderReference {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw ReferenceError.malformed("The private qualification config could not be read: \(error.localizedDescription)") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReferenceError.malformed("The private qualification config is not a JSON object")
        }
        guard let baseURLString = object["baseURL"] as? String,
              let baseURL = URL(string: baseURLString),
              let model = object["model"] as? String, !model.isEmpty else {
            throw ReferenceError.malformed("The private qualification config needs baseURL and model")
        }
        let apiKey: String
        if let inline = object["apiKey"] as? String, !inline.isEmpty {
            apiKey = inline
        } else if let keyPath = object["apiKeyPath"] as? String, !keyPath.isEmpty {
            do {
                apiKey = try String(contentsOfFile: keyPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw ReferenceError.malformed("The private qualification key file could not be read")
            }
        } else {
            throw ReferenceError.malformed("The private qualification config needs apiKey or apiKeyPath")
        }
        guard apiKey.count >= 16 else {
            throw ReferenceError.malformed("The resolved API key is too short")
        }
        let kind = (object["providerKind"] as? String).flatMap(ProviderKind.init(rawValue:)) ?? .custom
        let protocolName = (object["wireProtocol"] as? String) ?? ModelProtocol.openAIChatCompletions.rawValue
        guard let wireProtocol = ModelProtocol(rawValue: protocolName) else {
            throw ReferenceError.malformed("Unsupported wireProtocol \(protocolName)")
        }
        return ProviderReference(kind: kind, wireProtocol: wireProtocol, baseURL: baseURL,
                                 remoteModelID: model, apiKey: apiKey)
    }

    private static func providerReference(fromWorkBuddyModelsPath path: String,
                                          environment: [String: String]) throws -> ProviderReference {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw ReferenceError.malformed("The WorkBuddy models reference could not be read: \(error.localizedDescription)") }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ReferenceError.malformed("The WorkBuddy models reference is not a JSON array")
        }
        let requested = environment[workBuddyModelEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry: [String: Any]?
        if let requested, !requested.isEmpty {
            entry = array.first { ($0["id"] as? String) == requested }
        } else {
            entry = nil
        }
        guard let entry,
              let model = entry["id"] as? String, !model.isEmpty,
              let key = entry["apiKey"] as? String, key.count >= 16,
              let urlString = entry["url"] as? String, let url = URL(string: urlString),
              let baseURL = normalizedBaseURL(from: url) else {
            throw ReferenceError.malformed(
                "The WorkBuddy models reference needs an entry with id/apiKey/url; set "
                    + "\(workBuddyModelEnvironmentKey) to the exact entry id"
            )
        }
        return ProviderReference(kind: .custom, wireProtocol: .openAIChatCompletions,
                                 baseURL: baseURL, remoteModelID: model, apiKey: key)
    }

    /// QA-only mapping: the WorkBuddy reference stores a COMPLETE request
    /// endpoint (e.g. `/chat/completions`), while the production OpenAI
    /// adapter builds `{baseURL}/chat/completions`. Feeding the full endpoint
    /// in as the base duplicates the path and yields HTTP 404 with zero tool
    /// turns (observed once, retained as the config-mapping evidence). This
    /// strips exactly the endpoint suffix the production adapter appends and
    /// keeps every other path component untouched (e.g. `/v1`,
    /// `/v1beta/openai`, `/coding/v1`).
    private static func normalizedBaseURL(from url: URL) -> URL? {
        // Longest suffix first: the endpoint path is a whole trailing segment
        // (`/chat/completions`), never a single component, so stripping the
        // last component alone would leave `/chat`.
        let path = url.path
        for suffix in ["/chat/completions", "/completions", "/messages", "/responses"] {
            guard path.hasSuffix(suffix) else { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.path = String(path.dropLast(suffix.count))
            return components?.url
        }
        return url
    }

    /// A task-owned workspace under the test-owned temporary directory. The
    /// caller removes it once evidence (hashes, transcripts) is exported.
    static func makeWorkspace(label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-live-office-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Bounded, cancellation-aware wait. Never an unbounded semaphore.
    static func waitUntil(timeout: TimeInterval,
                          interval: TimeInterval = 0.25,
                          _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .seconds(interval))
        }
        return await condition()
    }

    static func makeRuntime(reference: ProviderReference,
                            workspace: URL,
                            conversationID: UUID,
                            allowedTools: Set<String>,
                            executor: any ToolExecutor) -> FloeAgentRuntime {
        let provider = ProviderProfile(
            kind: reference.kind,
            wireProtocol: reference.wireProtocol,
            baseURL: reference.baseURL,
            displayName: "Live Office qualification provider",
            presetID: nil,
            toolNameCompatibility: true
        )
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: reference.remoteModelID,
            displayName: reference.remoteModelID,
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.text, .tools]
        )
        return FloeAgentRuntime(
            configuration: .init(
                conversationID: conversationID,
                provider: provider,
                model: model,
                conversationMode: .chat,
                allowedToolNames: allowedTools,
                workspaceRootURL: workspace,
                toolsEnabled: true,
                maxToolSteps: 24,
                maxProviderRetries: 1,
                providerFirstEventTimeout: 120,
                providerStreamIdleTimeout: 120,
                providerReasoningIdleTimeout: 300,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 2
            ),
            adapter: ProviderAdapterFactory().adapter(for: provider),
            policy: TaskFullAccessPolicy(),
            executor: executor,
            credentials: ProviderCredentials(apiKey: reference.apiKey),
            runID: UUID()
        )
    }

    /// Runs one registered production tool through its registry entry (the
    /// same decoding/validation path the runtime uses), without the runtime.
    static func runTool(_ registry: ToolRunnerRegistry,
                        name: String,
                        arguments: [String: Any],
                        context: ToolContext) async throws -> ToolExecutionOutput {
        guard let runner = registry.runner(named: name) else {
            throw ReferenceError.missing("tool \(name) is not registered")
        }
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try await runner.run(data, context)
    }

    /// Prints one bounded evidence block and also writes it to the test
    /// process temporary directory so G2 can collect it from the container.
    static func exportEvidence(label: String, text: String) {
        var block = "FLOE-LIVE-OFFICE-EVIDENCE label=\(label)\n\(text)\nFLOE-LIVE-OFFICE-EVIDENCE-END label=\(label)"
        print(block)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-live-office-\(label)-\(Int(Date().timeIntervalSince1970)).log")
        try? block.write(to: url, atomically: true, encoding: .utf8)
        print("FLOE-LIVE-OFFICE-EVIDENCE-FILE label=\(label) path=\(url.path)")
        block = ""
    }

    // MARK: controlled artifact export (before any cleanup)

    /// The App-container directory the integration owner retrieves from the
    /// simulator after a live run. It holds the ACTUAL produced sources,
    /// engine copies and cover resources plus a SHA-256 manifest. No
    /// credentials are ever written here.
    static func evidenceRoot() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("floe-live-office-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Copies the named files out of the task workspace into the evidence root
    /// and writes `MANIFEST.txt` (name, sha256, bytes). The `.exported` marker
    /// it drops into the workspace is what lets the deferred cleanup delete
    /// it; without the marker a failed test keeps every artifact.
    @discardableResult
    static func exportArtifacts(label: String, workspace: URL,
                                files: [(name: String, url: URL)]) throws -> URL {
        let dir = try evidenceRoot().appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = ["label=\(label)"]
        for file in files {
            guard FileManager.default.fileExists(atPath: file.url.path) else {
                lines.append("\(file.name) MISSING")
                continue
            }
            let destination = dir.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file.url, to: destination)
            let hash = try sha256Hex(of: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
            lines.append("\(file.name) sha256=\(hash) bytes=\(size ?? 0)")
        }
        try lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent("MANIFEST.txt"), atomically: true, encoding: .utf8)
        try? Data().write(to: workspace.appendingPathComponent(".exported"))
        print("FLOE-LIVE-OFFICE-EVIDENCE-DIR label=\(label) path=\(dir.path)")
        return dir
    }

    /// Deletes a task workspace/store root ONLY after its artifacts were
    /// exported; a failed run keeps everything for inspection.
    static func cleanupIfExported(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".exported").path) else {
            print("FLOE-LIVE-OFFICE-EVIDENCE-RETAINED path=\(root.path)")
            return
        }
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Recording executor (captures the real tool calls of one run)

private actor LiveToolCallRecorder {
    struct Call: Sendable {
        var name: String
        var arguments: String
        var status: String
        var output: String
    }

    private var storage: [Call] = []

    func record(name: String, arguments: String, status: String, output: String) {
        storage.append(Call(name: name, arguments: arguments, status: status, output: output))
    }

    var calls: [Call] { storage }

    func calls(named name: String) -> [Call] {
        storage.filter { $0.name == name }
    }

    func dump() async -> String {
        dumpNow()
    }

    private func dumpNow() -> String {
        storage.map { call in
            "TOOL \(call.name) [\(call.status)] args=\(call.arguments.prefix(700)) output=\(call.output.prefix(1_600))"
        }.joined(separator: "\n")
    }
}

private struct RecordingCatalogExecutor: ToolExecutor {
    let inner: CatalogToolExecutor
    let recorder: LiveToolCallRecorder

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        inner.descriptor(named: name)
    }

    var allDescriptors: [ToolCatalog.Descriptor] {
        inner.allDescriptors
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try await execute(call, expectedAuthorizationIdentity: nil, context: context)
    }

    func execute(_ call: ToolCall,
                 expectedAuthorizationIdentity: String?,
                 context: ToolContext) async throws -> ToolResult {
        let result = try await inner.execute(call,
                                             expectedAuthorizationIdentity: expectedAuthorizationIdentity,
                                             context: context)
        await recorder.record(name: call.toolName,
                              arguments: String(decoding: call.argumentsJSON, as: UTF8.self),
                              status: result.status.rawValue,
                              output: result.outputSummary)
        return result
    }
}

// MARK: - Real visible editor session harness (engine route)

/// Opens one real `OfficeFileSession` in a visible window — exactly the
/// surface the visible editor mounts — and drives it to the editable,
/// command-ready state the `document.office.edit` propose/apply contract
/// requires. Every wait is bounded; a failure returns a precise description
/// instead of parking.
@MainActor
private final class LiveOfficeEditorSession {
    let fileSession = OfficeFileSession()
    private var window: UIWindow?

    func mountVisibleSurface() {
        let frame = UIScreen.main.bounds != .zero
            ? UIScreen.main.bounds
            : CGRect(x: 0, y: 0, width: 1180, height: 820)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        let host = UIHostingController(rootView: OfficeDocumentSurface(session: fileSession)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        self.window = window
    }

    /// Registers the live document for the shared command center, opens it in
    /// the real engine, enters editing when the preview is read-only and
    /// waits for the command-ready state. Returns nil on success.
    func openCommandReady(relativePath: String, root: URL, conversationID: UUID) async -> String? {
        fileSession.registerLiveDocument(relativePath: relativePath, root: root,
                                         conversationID: conversationID)
        await fileSession.open(root.appendingPathComponent(relativePath))
        guard await waitUntil(timeout: 150, { self.fileSession.phase == .ready }) else {
            return "the Office editor never reached ready (phase=\(self.fileSession.phase) "
                + "error=\(self.fileSession.error ?? "nil"))"
        }
        if fileSession.readOnly {
            let accepted = await fileSession.requestEditing()
            guard accepted else {
                return "the Office editor refused the edit entry "
                    + "(error=\(fileSession.error ?? fileSession.editUnavailableReason ?? "unknown"))"
            }
        }
        guard await waitUntil(timeout: 150, { self.fileSession.commandReady }) else {
            return "the Office editor never became command-ready "
                + "(readOnly=\(fileSession.readOnly) phase=\(fileSession.phase) "
                + "mounted=\(fileSession.controller != nil) "
                + "actionsReady=\(fileSession.documentActionsReady) "
                + "error=\(fileSession.error ?? "nil"))"
        }
        return nil
    }

    func release() async {
        await fileSession.release()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return condition()
    }
}

// MARK: - Independent OOXML readers (ZIPFoundation + XMLParser + CryptoKit)

/// Reads members of an OOXML package without touching any product reader.
private struct QualificationPackage {
    private let archive: Archive

    init(url: URL) throws {
        self.archive = try Archive(url: url, accessMode: .read)
    }

    var entryNames: [String] { archive.map(\.path) }

    func data(_ path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw FloeError.notFound("package entry \(path)")
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    func string(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }
}

/// Bounded independent XML parse through the SDK parser.
private func qualificationXML(_ xml: String, delegate: XMLParserDelegate) throws {
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    parser.shouldProcessNamespaces = false
    guard parser.parse() else {
        throw FloeError.validationFailed("independent XML parse failed for the qualification package")
    }
}

/// Independent Word reader: text is the concatenation of the `w:t` tokens
/// of ONE paragraph, preserving paragraph boundaries. The engine writer (and
/// any real Word writer) splits a paragraph around Latin tokens into
/// multiple runs, so comparing a whole paragraph against a single run would
/// be a reader-representation error, not a content check. Table shapes are
/// derived from real `w:tr`/`w:tc` element nesting (2 rows x 3 cells here),
/// never from a whole-document string scan.
private final class WordTextCollector: NSObject, XMLParserDelegate {
    private(set) var texts: [String] = []
    private(set) var tableShapes: [(rows: Int, columns: Int)] = []
    private(set) var tableCount = 0
    private var insideText = false
    private var textBuffer = ""
    private var insideParagraph = false
    private var paragraphBuffer = ""
    private var tableDepth = 0
    private var currentRows = 0
    private var currentRowCells = 0
    private var currentMaxCells = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch elementName {
        case "w:tbl":
            tableCount += 1
            tableDepth += 1
            if tableDepth == 1 { currentRows = 0; currentMaxCells = 0 }
        case "w:tr" where tableDepth == 1:
            currentRows += 1
            currentRowCells = 0
        case "w:tc" where tableDepth == 1:
            currentRowCells += 1
        case "w:p":
            insideParagraph = true
            paragraphBuffer = ""
        case "w:t":
            insideText = true
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText { textBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "w:t":
            if insideParagraph { paragraphBuffer += textBuffer }
            insideText = false
        case "w:p":
            if insideParagraph {
                texts.append(paragraphBuffer)
                insideParagraph = false
                paragraphBuffer = ""
            }
        case "w:tr" where tableDepth == 1:
            currentMaxCells = max(currentMaxCells, currentRowCells)
        case "w:tbl":
            if tableDepth == 1 {
                tableShapes.append((rows: currentRows, columns: currentMaxCells))
            }
            tableDepth = max(tableDepth - 1, 0)
        default:
            break
        }
    }
}

private struct QualificationWordDocument {
    var texts: [String]
    var tableCount: Int
    var tableShapes: [(rows: Int, columns: Int)]

    init(url: URL) throws {
        let package = try QualificationPackage(url: url)
        let collector = WordTextCollector()
        try qualificationXML(try package.string("word/document.xml"), delegate: collector)
        texts = collector.texts
        tableCount = collector.tableCount
        tableShapes = collector.tableShapes
    }
}

/// Independent presentation reader: text is the concatenation of the `a:t`
/// tokens of ONE `a:p` paragraph, preserving paragraph boundaries, so a
/// paragraph split around Latin tokens into several runs still reads as its
/// real text (the same run-representation rule as the Word reader).
private final class PresentationTextCollector: NSObject, XMLParserDelegate {
    private(set) var texts: [String] = []
    private var insideText = false
    private var textBuffer = ""
    private var insideParagraph = false
    private var paragraphBuffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch elementName {
        case "a:p":
            insideParagraph = true
            paragraphBuffer = ""
        case "a:t":
            insideText = true
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText { textBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "a:t":
            if insideParagraph { paragraphBuffer += textBuffer }
            insideText = false
        case "a:p":
            if insideParagraph {
                texts.append(paragraphBuffer)
                insideParagraph = false
                paragraphBuffer = ""
            }
        default:
            break
        }
    }
}

private struct QualificationPresentation {
    var slideTexts: [[String]]
    var notesTexts: [[String]]

    init(url: URL) throws {
        let package = try QualificationPackage(url: url)
        slideTexts = try Self.collect(package: package, directory: "ppt/slides", prefix: "/slides/slide")
        notesTexts = try Self.collect(package: package, directory: "ppt/notesSlides",
                                      prefix: "/notesSlides/notesSlide")
    }

    private static func collect(package: QualificationPackage,
                                directory: String,
                                prefix: String) throws -> [[String]] {
        let names = package.entryNames
            .filter { $0.hasPrefix(directory) && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }
            .filter { $0.contains(prefix) }
            .sorted { trailingNumber($0) < trailingNumber($1) }
        var result: [[String]] = []
        for name in names {
            let collector = PresentationTextCollector()
            try qualificationXML(try package.string(name), delegate: collector)
            result.append(collector.texts)
        }
        return result
    }

    private static func trailingNumber(_ path: String) -> Int {
        let base = (path as NSString).deletingPathExtension
        let digits = base.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits)) ?? 0
    }
}

private final class WorksheetCellCollector: NSObject, XMLParserDelegate {
    struct Cell {
        var reference: String
        var type: String?
        var formula: String?
        var value: String?
        var inlineText: String?
    }

    private(set) var cells: [Cell] = []
    private var current: Cell?
    private var collecting: String?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch elementName {
        case "c":
            current = Cell(reference: attributes["r"] ?? "", type: attributes["t"],
                           formula: nil, value: nil, inlineText: nil)
        case "f":
            collecting = "f"; buffer = ""
        case "v":
            collecting = "v"; buffer = ""
        case "t":
            if current != nil { collecting = "t"; buffer = "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "f":
            current?.formula = buffer; collecting = nil
        case "v":
            current?.value = buffer; collecting = nil
        case "t":
            if collecting == "t", var cell = current {
                // Read the stored value into a separate local before writing:
                // any `cell.inlineText = old + buffer` form keeps the read and
                // the write of the same storage overlapping.
                let accumulated = (cell.inlineText ?? "") + buffer
                cell.inlineText = accumulated
                current = cell
            }
            collecting = nil
        case "c":
            if let current, !current.reference.isEmpty { cells.append(current) }
            current = nil
        default:
            break
        }
    }
}

/// Independent workbook reader over the raw worksheet XML.
private struct QualificationWorkbook {
    struct Cell {
        var reference: String
        var type: String?
        var formula: String?
        var value: String?
        var inlineText: String?
    }

    private var sheets: [String: [String: Cell]] = [:]
    private var declaredSheetNames: [String: String] = [:]

    init(url: URL) throws {
        let package = try QualificationPackage(url: url)
        let sheetMembers = package.entryNames
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }
            .sorted()
        for member in sheetMembers {
            let collector = WorksheetCellCollector()
            try qualificationXML(try package.string(member), delegate: collector)
            var byReference: [String: Cell] = [:]
            for cell in collector.cells {
                byReference[cell.reference.uppercased()] = Cell(
                    reference: cell.reference, type: cell.type,
                    formula: cell.formula, value: cell.value, inlineText: cell.inlineText
                )
            }
            sheets[member] = byReference
        }
        // Sheet names are resolved independently from workbook.xml + rels.
        guard let workbookXML = try? package.string("xl/workbook.xml"),
              let relsXML = try? package.string("xl/_rels/workbook.xml.rels") else { return }
        var targets: [String: String] = [:]
        for element in Self.attributes(in: relsXML, element: "Relationship") {
            if let id = element["Id"], let target = element["Target"] { targets[id] = target }
        }
        for sheet in Self.attributes(in: workbookXML, element: "sheet") {
            guard let name = sheet["name"], let relationID = sheet["r:id"],
                  let target = targets[relationID] else { continue }
            let trimmed = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            declaredSheetNames[name] = trimmed
        }
    }

    func sheetMember(named name: String) -> String? {
        declaredSheetNames[name]
    }

    func cell(sheet: String, _ reference: String) -> Cell? {
        guard let member = sheetMember(named: sheet) else { return nil }
        return sheets[member]?[reference.uppercased()]
    }

    /// Bounded scanner returning the attribute dictionaries of one element
    /// name; used only for sheet naming (never for cell values).
    static func attributes(in xml: String, element: String) -> [[String: String]] {
        var result: [[String: String]] = []
        var cursor = xml.startIndex
        let opener = "<\(element)"
        while let range = xml.range(of: opener, range: cursor..<xml.endIndex) {
            let boundary = range.upperBound
            guard boundary < xml.endIndex,
                  let scalar = xml[boundary].unicodeScalars.first,
                  scalar == ">" || scalar == "/" || CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                cursor = boundary
                continue
            }
            guard let close = xml.range(of: ">", range: range.lowerBound..<xml.endIndex) else { break }
            let block = String(xml[range.lowerBound..<close.upperBound])
            var attributes: [String: String] = [:]
            var searchStart = block.startIndex
            while let equals = block.range(of: "=\"", range: searchStart..<block.endIndex) {
                let nameStart = block[..<equals.lowerBound]
                    .lastIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" })
                    .map { block.index(after: $0) } ?? block.startIndex
                let name = String(block[nameStart..<equals.lowerBound])
                let valueStart = equals.upperBound
                guard let end = block.range(of: "\"", range: valueStart..<block.endIndex) else { break }
                if !name.isEmpty { attributes[name] = String(block[valueStart..<end.lowerBound]) }
                searchStart = end.upperBound
            }
            result.append(attributes)
            cursor = close.upperBound
        }
        return result
    }
}

// MARK: - Deterministic App-host checks (no provider, always run)

@Suite("FloeApp.OfficeAssistantQualification")
@MainActor
struct OfficeAssistantQualificationTests {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-qualification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRegistry(root: URL) -> ToolRunnerRegistry {
        let registry = ToolRunnerRegistry()
        _ = registerDocumentTools(registry: registry, rootProvider: { root })
        registerOfficeEditTools(center: OfficeCommandCenter(), registry: registry)
        NotesToolRegistration.register()
        registry.register(NotesReadTool())
        registry.register(NotesCoverTool())
        return registry
    }

    private func context(_ root: URL, toolCallID: String) -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: toolCallID, scope: .local,
                    workspaceRootURL: root, cancellation: CancellationToken())
    }

    @Test("the live qualification tool ceiling is registered and executable in the App host")
    func liveCeilingIsRegistered() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry(root: root)
        for name in LiveOfficeQualification.allExpectedToolNames {
            #expect(registry.runner(named: name) != nil,
                    "tool \(name) has no executable runner in the App host; a live run would silently lose it")
            #expect(ToolCatalog.descriptor(named: name) != nil,
                    "tool \(name) is missing from the compiled tool catalog")
        }
    }

    @Test("a stale expectedSHA256 file-level edit is refused and leaves the document bytes untouched")
    func staleExpectedSHARefusal() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry(root: root)
        let url = root.appendingPathComponent("stale.docx")
        try OfficeDocumentBuilder.createWord(at: url, title: "验收文档",
                                             paragraphs: ["第一段", "第二段", "第三段"])
        let first = try OfficeDocumentService.inspect(url: url)
        let firstSHA = try #require(first.sha256)
        let paragraph = try #require(first.fields.first { $0.text == "第二段" })

        let updated = try await LiveOfficeQualification.runTool(
            registry, name: "document.office.updateText",
            arguments: ["path": "stale.docx", "expectedSHA256": firstSHA,
                        "updates": [paragraph.id: "第二段（第一次编辑）"]],
            context: context(root, toolCallID: "qualification-edit-1"))
        #expect(updated.exitStatus == 0, "a current-SHA edit must succeed: \(updated.summary)")
        let afterEdit = try LiveOfficeQualification.sha256Hex(of: url)
        #expect(afterEdit != firstSHA)

        let stale = try await LiveOfficeQualification.runTool(
            registry, name: "document.office.updateText",
            arguments: ["path": "stale.docx", "expectedSHA256": firstSHA,
                        "updates": [paragraph.id: "不应写入"]],
            context: context(root, toolCallID: "qualification-edit-stale"))
        #expect(stale.exitStatus == 2, "a stale expectedSHA256 must be refused: \(stale.summary)")
        #expect(stale.summary.contains("status=error"))
        #expect(try LiveOfficeQualification.sha256Hex(of: url) == afterEdit,
                "a refused stale edit must not touch the document bytes")

        let reopened = try OfficeDocumentService.inspect(url: url)
        #expect(reopened.fields.contains { $0.text == "第二段（第一次编辑）" })
        #expect(!reopened.fields.contains { $0.text == "不应写入" })
    }

    @Test("created workbooks keep formulas as formulas and never fabricate a cached result")
    func workbookFormulasRemainFormulas() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry(root: root)
        let created = try await LiveOfficeQualification.runTool(
            registry, name: "document.createWorkbook",
            arguments: [
                "path": "formula-seed.xlsx",
                "sheets": [
                    ["name": "Input", "rows": [["Item", "Qty"], ["A", "0"], ["B", "2"], ["C", "3"]]],
                    ["name": "Calc", "rows": [
                        ["Metric", "Value"],
                        ["TotalQty", "=SUM(Input!B2:B4)"],
                        ["ZeroRef", "=Input!B2"],
                        ["ErrorCase", "=1/0"],
                        ["Arith", "=2+3*4"]
                    ]]
                ]
            ],
            context: context(root, toolCallID: "qualification-workbook-create"))
        #expect(created.exitStatus == 0, "workbook creation must succeed: \(created.summary)")

        let workbook = try QualificationWorkbook(url: root.appendingPathComponent("formula-seed.xlsx"))
        #expect(workbook.cell(sheet: "Input", "B2")?.value == "0",
                "numeric input values must stay typed numeric")
        let totalQty = try #require(workbook.cell(sheet: "Calc", "B2"))
        #expect(totalQty.formula == "SUM(Input!B2:B4)")
        #expect(totalQty.value == nil,
                "the package-level writer must not fabricate a cached formula result; cached values are verified only through the engine recalculation route")
        #expect(workbook.cell(sheet: "Calc", "B3")?.formula == "Input!B2")
        #expect(workbook.cell(sheet: "Calc", "B4")?.formula == "1/0")
        #expect(workbook.cell(sheet: "Calc", "B5")?.formula == "2+3*4")
    }
}

// MARK: - Live provider scenarios (disabled unless opted in)

@Suite("FloeApp.LiveOfficeAssistantQualification", .serialized)
@MainActor
struct LiveOfficeAssistantQualificationTests {
    // MARK: Word — file-level creation + two successive edits, then engine table

    @Test(.timeLimit(.minutes(15)), .enabled(if: LiveOfficeQualification.isEnabled))
    func wordAssistantCreatesEditsTwiceThenInsertsTable() async throws {
        let reference = try LiveOfficeQualification.providerReference()
        let workspace = try LiveOfficeQualification.makeWorkspace(label: "word")
        defer { LiveOfficeQualification.cleanupIfExported(workspace) }
        let conversationID = UUID()
        let registry = ToolRunnerRegistry()
        _ = registerDocumentTools(registry: registry, rootProvider: { workspace })
        registerOfficeEditTools(center: OfficeCommandCenter(), registry: registry)
        let recorder = LiveToolCallRecorder()
        let executor = RecordingCatalogExecutor(inner: CatalogToolExecutor(runners: registry),
                                                recorder: recorder)

        // ---- Phase A: the assistant creates the document and performs two
        // successive Chinese text edits through the file-level OOXML path.
        let runtimeA = LiveOfficeQualification.makeRuntime(
            reference: reference, workspace: workspace, conversationID: conversationID,
            allowedTools: LiveOfficeQualification.wordFileLevelTools, executor: executor)
        await runtimeA.injectSystemContext("""
        This is an authorized synthetic Office qualification run on a review device. \
        Work only inside the task workspace and do not use the web.
        Do exactly these steps, in order, then stop:
        1. Call document.createWord with path="acceptance.docx", title="验收文档", \
        paragraphs=["第一段：原始内容保持不动（FLOE-WORD-P1）。", \
        "第二段：这一段将在第一次编辑中被替换。", \
        "第三段：这一段将在第二次编辑中被替换。"].
        2. Call document.office.inspect with path="acceptance.docx". Copy the exact sha256 \
        and the exact id= value of the paragraph whose text begins with 第二段.
        3. Call document.office.updateText with path="acceptance.docx", \
        expectedSHA256=<the sha256 from step 2>, \
        updates={<the field id from step 2>: "第二段：第一次编辑完成（FLOE-WORD-E1）。"}.
        4. Call document.office.inspect again. Copy the NEW sha256 and the exact id= value \
        of the paragraph whose text begins with 第三段.
        5. Call document.office.updateText with path="acceptance.docx", \
        expectedSHA256=<the sha256 from step 4>, \
        updates={<the field id from step 4>: "第三段：第二次编辑完成（FLOE-WORD-E2）。"}.
        Do not call any other tool. Then reply in one short sentence.
        """)
        let startedA = Date()
        try await runtimeA.start(goal: "按照步骤创建并两次编辑 acceptance.docx。")
        let stateA = await runtimeA.state
        let transcriptA = await recorder.dump()
        LiveOfficeQualification.exportEvidence(
            label: "word-phase-a",
            text: "model=\(reference.remoteModelID) host=\(reference.baseURL.host ?? "?") "
                + "basePath=\(reference.baseURL.path) "
                + "seconds=\(Int(Date().timeIntervalSince(startedA)))\n"
                + "state=\(stateA)\n\(transcriptA)")
        if case .completed = stateA {} else {
            Issue.record("Word phase A did not complete: \(stateA)")
            return
        }

        let documentURL = workspace.appendingPathComponent("acceptance.docx")
        #expect(FileManager.default.fileExists(atPath: documentURL.path),
                "the assistant must have created acceptance.docx\n\(transcriptA)")
        let afterA = try QualificationWordDocument(url: documentURL)
        #expect(afterA.texts.contains("第一段：原始内容保持不动（FLOE-WORD-P1）。"),
                "the created document must keep the original first paragraph: \(afterA.texts)")
        #expect(afterA.texts.contains("第二段：第一次编辑完成（FLOE-WORD-E1）。"))
        #expect(afterA.texts.contains("第三段：第二次编辑完成（FLOE-WORD-E2）。"))
        #expect(!afterA.texts.contains("第二段：这一段将在第一次编辑中被替换。"))
        #expect(!afterA.texts.contains("第三段：这一段将在第二次编辑中被替换。"))
        let createdCalls = await recorder.calls(named: "document.createWord")
        let updateCalls = await recorder.calls(named: "document.office.updateText")
        #expect(createdCalls.contains { $0.status == "ok" },
                "the creation must be a real successful tool call: \(transcriptA)")
        #expect(updateCalls.filter { $0.status == "ok" }.count >= 2,
                "two successive successful updateText edits are required: \(transcriptA)")
        let allWordCalls = await recorder.calls
        #expect(allWordCalls.allSatisfy { $0.status != "needsUser" },
                "the qualification binding must not trigger a confirmation card: \(transcriptA)")

        let phaseASHA = try LiveOfficeQualification.sha256Hex(of: documentURL)

        // ---- Phase B: engine route on a real visible editor session.
        let editor = LiveOfficeEditorSession()
        editor.mountVisibleSurface()
        let opened = await editor.openCommandReady(relativePath: "acceptance.docx",
                                                   root: workspace,
                                                   conversationID: conversationID)
        defer { Task { await editor.release() } }
        if let opened {
            await editor.release()
            Issue.record("the Word editor session was not command-ready: \(opened)")
            return
        }

        let runtimeB = LiveOfficeQualification.makeRuntime(
            reference: reference, workspace: workspace, conversationID: conversationID,
            allowedTools: LiveOfficeQualification.wordEngineTools, executor: executor)
        await runtimeB.injectSystemContext("""
        The document acceptance.docx is open in the Floe Office editor. \
        Do exactly these steps, in order, then stop:
        1. Call document.office.edit with action="read", path="acceptance.docx". \
        Copy the exact sha256.
        2. Call document.office.edit with action="propose", path="acceptance.docx", \
        expected_sha256=<that sha256>, summary="Insert a 2x3 table", \
        commands=[{"id":"word.insertTable","arguments":{"rows":"2","columns":"3"}}].
        3. Copy the proposal_id from the propose result and call document.office.edit with \
        action="apply", path="acceptance.docx", proposal_id=<that proposal_id>, \
        output="acceptance-table.docx". Do not pass grant_id.
        Do not call any other tool. Then reply in one short sentence.
        """)
        let startedB = Date()
        try await runtimeB.start(goal: "按步骤在 acceptance.docx 的引擎会话中插入表格。")
        let stateB = await runtimeB.state
        let transcriptB = await recorder.dump()
        LiveOfficeQualification.exportEvidence(
            label: "word-phase-b",
            text: "model=\(reference.remoteModelID) seconds=\(Int(Date().timeIntervalSince(startedB)))\n"
                + "state=\(stateB)\n\(transcriptB)")
        await editor.release()
        if case .completed = stateB {} else {
            Issue.record("Word phase B did not complete: \(stateB)")
            return
        }

        let editCalls = await recorder.calls(named: "document.office.edit")
        #expect(editCalls.contains { $0.arguments.contains("\"apply\"") && $0.output.contains("status=saved") },
                "the engine apply must complete and publish a verified copy: \(transcriptB)")
        #expect(editCalls.contains { $0.output.contains("mode=automatic-copy sourceUnchanged=true") },
                "the source must be reported unchanged by the automatic copy: \(transcriptB)")

        let tableURL = workspace.appendingPathComponent("acceptance-table.docx")
        #expect(FileManager.default.fileExists(atPath: tableURL.path),
                "the verified edited copy acceptance-table.docx must exist: \(transcriptB)")
        let tableDocument = try QualificationWordDocument(url: tableURL)
        #expect(tableDocument.tableCount >= 1, "the edited copy must contain a real table")
        #expect(tableDocument.tableShapes.contains { $0.rows == 2 && $0.columns == 3 },
                "the engine insertTable(rows:2,columns:3) must reopen as a real 2x3 table: \(tableDocument.tableShapes)")
        #expect(tableDocument.texts.contains("第一段：原始内容保持不动（FLOE-WORD-P1）。"),
                "the copy must keep the untouched first paragraph: \(tableDocument.texts)")
        #expect(tableDocument.texts.contains("第二段：第一次编辑完成（FLOE-WORD-E1）。"),
                "the copy must keep the first engine-visible edit paragraph: \(tableDocument.texts)")
        #expect(tableDocument.texts.contains("第三段：第二次编辑完成（FLOE-WORD-E2）。"),
                "the copy must keep the second engine-visible edit paragraph: \(tableDocument.texts)")
        #expect(try LiveOfficeQualification.sha256Hex(of: documentURL) == phaseASHA,
                "the automatic copy must never modify the source document")
        let sourceDocument = try QualificationWordDocument(url: documentURL)
        #expect(sourceDocument.tableCount == 0, "the source must not gain the table")

        // Export the real artifacts (and hashes) BEFORE any cleanup so the
        // integration owner can inspect/open them without another paid run.
        try LiveOfficeQualification.exportArtifacts(
            label: "word", workspace: workspace,
            files: [("acceptance.docx", documentURL), ("acceptance-table.docx", tableURL)])
    }

    // MARK: Excel — file-level edits, then engine recalculation with cached values

    @Test(.timeLimit(.minutes(15)), .enabled(if: LiveOfficeQualification.isEnabled))
    func excelAssistantEditsFormulasAndRecalculatesCachedValues() async throws {
        let reference = try LiveOfficeQualification.providerReference()
        let workspace = try LiveOfficeQualification.makeWorkspace(label: "excel")
        defer { LiveOfficeQualification.cleanupIfExported(workspace) }
        let conversationID = UUID()
        let workbookURL = workspace.appendingPathComponent("excel-acceptance.xlsx")
        // Task-owned synthetic fixture: numeric values, a SUM over a
        // cross-sheet range, zero results that must stay valid zeros, a real
        // division-by-zero error and constant arithmetic.
        try OfficeDocumentBuilder.createWorkbook(at: workbookURL, sheets: [
            OfficeWorkbookSheet(name: "Input", rows: [
                ["Item", "Qty", "Price"], ["A", "0", "10"], ["B", "2", "5"], ["C", "3", "7"]
            ]),
            OfficeWorkbookSheet(name: "Calc", rows: [
                ["Metric", "Value", "Note"],
                ["TotalQty", "=SUM(Input!B2:B4)", "sum of the Qty column on the Input sheet"],
                ["ZeroRef", "=Input!B2", "the zero quantity must stay a valid zero"],
                ["ZeroSum", "=SUM(Input!B2:B2)", "zero sum must stay a valid zero"],
                ["ErrorCase", "=1/0", "division by zero must persist as a real error"],
                ["Arith", "=2+3*4", "constant arithmetic"]
            ])
        ])

        let registry = ToolRunnerRegistry()
        _ = registerDocumentTools(registry: registry, rootProvider: { workspace })
        registerOfficeEditTools(center: OfficeCommandCenter(), registry: registry)
        let recorder = LiveToolCallRecorder()
        let executor = RecordingCatalogExecutor(inner: CatalogToolExecutor(runners: registry),
                                                recorder: recorder)

        // ---- Phase A: two file-level formula edits through the real tools.
        let runtimeA = LiveOfficeQualification.makeRuntime(
            reference: reference, workspace: workspace, conversationID: conversationID,
            allowedTools: LiveOfficeQualification.excelFileLevelTools, executor: executor)
        await runtimeA.injectSystemContext("""
        An editable workbook excel-acceptance.xlsx exists in the task workspace. \
        Work only inside the task workspace and do not use the web.
        Do exactly these steps, in order, then stop:
        1. Call document.office.inspect with path="excel-acceptance.xlsx". Copy the exact \
        sha256, the exact id= of the cell whose text is exactly "2" and whose id ends with \
        "sheet1.xml|c|B3" (the Input sheet quantity), and the exact id= of the cell \
        whose text is exactly "=SUM(Input!B2:B4)" and whose id ends with "sheet2.xml|c|B2".
        2. Call document.office.updateText with path="excel-acceptance.xlsx", \
        expectedSHA256=<the sha256 from step 1>, \
        updates={<the sheet1 B3 id from step 1>: "4"}.
        3. Call document.office.inspect again. Copy the NEW sha256.
        4. Call document.office.updateText with path="excel-acceptance.xlsx", \
        expectedSHA256=<the sha256 from step 3>, \
        updates={<the sheet2 B2 id from step 1>: "=SUM(Input!B2:B4)*2"}.
        Do not call any other tool. Then reply in one short sentence.
        """)
        let startedA = Date()
        try await runtimeA.start(goal: "按照步骤编辑 excel-acceptance.xlsx 的数值和公式。")
        let stateA = await runtimeA.state
        let transcriptA = await recorder.dump()
        LiveOfficeQualification.exportEvidence(
            label: "excel-phase-a",
            text: "model=\(reference.remoteModelID) seconds=\(Int(Date().timeIntervalSince(startedA)))\n"
                + "state=\(stateA)\n\(transcriptA)")
        if case .completed = stateA {} else {
            Issue.record("Excel phase A did not complete: \(stateA)")
            return
        }

        let edited = try QualificationWorkbook(url: workbookURL)
        #expect(edited.cell(sheet: "Input", "B3")?.value == "4",
                "the assistant's numeric edit must be persisted: \(transcriptA)")
        #expect(edited.cell(sheet: "Calc", "B2")?.formula == "SUM(Input!B2:B4)*2",
                "the assistant's formula edit must stay a formula: \(transcriptA)")
        let phaseASHA = try LiveOfficeQualification.sha256Hex(of: workbookURL)

        // ---- Phase B: engine recalculation on a real visible editor session.
        let editor = LiveOfficeEditorSession()
        editor.mountVisibleSurface()
        let opened = await editor.openCommandReady(relativePath: "excel-acceptance.xlsx",
                                                   root: workspace,
                                                   conversationID: conversationID)
        defer { Task { await editor.release() } }
        if let opened {
            await editor.release()
            Issue.record("the Excel editor session was not command-ready: \(opened)")
            return
        }

        let runtimeB = LiveOfficeQualification.makeRuntime(
            reference: reference, workspace: workspace, conversationID: conversationID,
            allowedTools: LiveOfficeQualification.excelEngineTools, executor: executor)
        await runtimeB.injectSystemContext("""
        The workbook excel-acceptance.xlsx is open in the Floe Office editor. \
        Do exactly these steps, in order, then stop:
        1. Call document.office.edit with action="read", path="excel-acceptance.xlsx". \
        Copy the exact sha256.
        2. Call document.office.edit with action="propose", path="excel-acceptance.xlsx", \
        expected_sha256=<that sha256>, summary="Recalculate all formulas", \
        commands=[{"id":"excel.recalculate"}].
        3. Copy the proposal_id from the propose result and call document.office.edit with \
        action="apply", path="excel-acceptance.xlsx", proposal_id=<that proposal_id>. \
        Do not pass grant_id and do not pass output: the verified edited copy keeps the \
        engine's default name.
        Do not call any other tool. Then reply in one short sentence.
        """)
        let startedB = Date()
        try await runtimeB.start(goal: "按步骤重算 excel-acceptance.xlsx 的公式缓存。")
        let stateB = await runtimeB.state
        let transcriptB = await recorder.dump()
        LiveOfficeQualification.exportEvidence(
            label: "excel-phase-b",
            text: "model=\(reference.remoteModelID) seconds=\(Int(Date().timeIntervalSince(startedB)))\n"
                + "state=\(stateB)\n\(transcriptB)")
        await editor.release()
        if case .completed = stateB {} else {
            Issue.record("Excel phase B did not complete: \(stateB)")
            return
        }

        let editCalls = await recorder.calls(named: "document.office.edit")
        #expect(editCalls.contains { $0.arguments.contains("\"apply\"") && $0.output.contains("status=saved") },
                "the recalculation apply must complete: \(transcriptB)")
        #expect(editCalls.contains { $0.output.contains("formulaSummary=") || $0.output.contains("recalc=") },
                "the receipt must carry the measured formula summary: \(transcriptB)")
        #expect(editCalls.contains { $0.output.contains("excel-acceptance.edited.xlsx") },
                "an apply without output must publish the default edited copy: \(transcriptB)")

        // Default copy name (no `output` argument): `<name>.edited.<ext>`.
        let recalculatedURL = workspace.appendingPathComponent("excel-acceptance.edited.xlsx")
        #expect(FileManager.default.fileExists(atPath: recalculatedURL.path),
                "the verified default-named recalculated copy must exist: \(transcriptB)")
        let recalculated = try QualificationWorkbook(url: recalculatedURL)

        // Formulas remain formulas, and the engine's persisted cached values
        // are checked independently of the product verifier.
        let total = try #require(recalculated.cell(sheet: "Calc", "B2"))
        #expect(total.formula?.replacingOccurrences(of: " ", with: "") == "SUM(Input!B2:B4)*2",
                "the recalculated copy must keep the edited formula")
        #expect(total.value == "14", "cross-sheet SUM*2 cached value must be 14, got \(total.value ?? "nil")")
        #expect(recalculated.cell(sheet: "Calc", "B3")?.value == "0",
                "a zero direct-reference result must stay a valid cached zero")
        #expect(recalculated.cell(sheet: "Calc", "B4")?.value == "0",
                "a zero SUM result must stay a valid cached zero")
        let errorCell = try #require(recalculated.cell(sheet: "Calc", "B5"))
        #expect(errorCell.type == "e" && errorCell.value?.contains("DIV/0") == true,
                "the division-by-zero must persist as a real cached error, got \(errorCell)")
        #expect(recalculated.cell(sheet: "Calc", "B6")?.value == "14",
                "constant arithmetic must be recalculated")
        #expect(recalculated.cell(sheet: "Input", "B2")?.value == "0",
                "the untouched zero input must stay a typed zero")
        #expect(try LiveOfficeQualification.sha256Hex(of: workbookURL) == phaseASHA,
                "the automatic copy must never modify the source workbook")

        try LiveOfficeQualification.exportArtifacts(
            label: "excel", workspace: workspace,
            files: [("excel-acceptance.xlsx", workbookURL),
                    ("excel-acceptance.edited.xlsx", recalculatedURL)])
    }

    // MARK: Presentation — slide text + notes, then engine slide duplicate

    @Test(.timeLimit(.minutes(15)), .enabled(if: LiveOfficeQualification.isEnabled))
    func presentationAssistantEditsSlideNotesThenDuplicatesASlide() async throws {
        let reference = try LiveOfficeQualification.providerReference()
        let workspace = try LiveOfficeQualification.makeWorkspace(label: "presentation")
        defer { LiveOfficeQualification.cleanupIfExported(workspace) }
        let conversationID = UUID()
        let deckURL = workspace.appendingPathComponent("deck-acceptance.pptx")
        try OfficeDocumentBuilder.createPresentation(at: deckURL, title: "验收演示", slides: [
            OfficePresentationSlide(title: "第一页：保持不变", bullets: ["要点一", "要点二"],
                                    notes: "备注一：保持不变。"),
            OfficePresentationSlide(title: "第二页：原始标题", bullets: ["要点A", "要点B"],
                                    notes: "备注二：原始备注内容。")
        ])

        let registry = ToolRunnerRegistry()
        _ = registerDocumentTools(registry: registry, rootProvider: { workspace })
        registerOfficeEditTools(center: OfficeCommandCenter(), registry: registry)
        let recorder = LiveToolCallRecorder()
        let executor = RecordingCatalogExecutor(inner: CatalogToolExecutor(runners: registry),
                                                recorder: recorder)

        // ---- Phase A: selected-slide text + speaker notes through the real tools.
        let runtimeA = LiveOfficeQualification.makeRuntime(
            reference: reference, workspace: workspace, conversationID: conversationID,
            allowedTools: LiveOfficeQualification.presentationFileLevelTools, executor: executor)
        await runtimeA.injectSystemContext("""
        An editable presentation deck-acceptance.pptx exists in the task workspace. \
        Work only inside the task workspace and do not use the web.
        Do exactly these steps, in order, then stop:
        1. Call document.office.inspect with path="deck-acceptance.pptx". Copy the exact sha256, \
        the exact id= of the slide-2 title paragraph whose text is exactly "第二页：原始标题" \
        (its id ends with "ppt/slides/slide2.xml|p|0"), and the exact id= of the slide-2 speaker \
        notes paragraph whose text is exactly "备注二：原始备注内容。" (its id contains \
        "ppt/notesSlides/notesSlide2.xml").
        2. Call document.office.updateText with path="deck-acceptance.pptx", \
        expectedSHA256=<the sha256 from step 1>, updates={<the slide-2 title id>: \
        "第二页：第一次编辑完成（FLOE-PPT-E1）", <the slide-2 notes id>: \
        "备注二：第一次编辑完成（FLOE-PPT-E1）。"}.
        Do not call any other tool. Then reply in one short sentence.
        """)
        let startedA = Date()
        try await runtimeA.start(goal: "按照步骤编辑 deck-acceptance.pptx 第二页的标题和演讲备注。")
        let stateA = await runtimeA.state
        let transcriptA = await recorder.dump()
        LiveOfficeQualification.exportEvidence(
            label: "presentation-phase-a",
            text: "model=\(reference.remoteModelID) seconds=\(Int(Date().timeIntervalSince(startedA)))\n"
                + "state=\(stateA)\n\(transcriptA)")
        if case .completed = stateA {} else {
            Issue.record("Presentation phase A did not complete: \(stateA)")
            return
        }

        let edited = try QualificationPresentation(url: deckURL)
        #expect(edited.slideTexts.count == 2, "the edited deck must keep two slides: \(transcriptA)")
        if edited.slideTexts.count == 2 {
            #expect(edited.slideTexts[0].contains("第一页：保持不变"))
            #expect(edited.slideTexts[1].contains("第二页：第一次编辑完成（FLOE-PPT-E1）"),
                    "the selected slide title edit must persist: \(transcriptA)")
        }
        #expect(edited.notesTexts.count == 2, "the edited deck must keep two notes slides: \(transcriptA)")
        if edited.notesTexts.count == 2 {
            #expect(edited.notesTexts[0].contains("备注一：保持不变。"),
                    "the unmodified slide's notes must be preserved")
            #expect(edited.notesTexts[1].contains("备注二：第一次编辑完成（FLOE-PPT-E1）。"),
                    "the speaker notes edit must persist: \(transcriptA)")
        }
        let phaseASHA = try LiveOfficeQualification.sha256Hex(of: deckURL)

        // ---- Phase B: one supported structure operation through the engine.
        let editor = LiveOfficeEditorSession()
        editor.mountVisibleSurface()
        let opened = await editor.openCommandReady(relativePath: "deck-acceptance.pptx",
                                                   root: workspace,
                                                   conversationID: conversationID)
        defer { Task { await editor.release() } }
        if let opened {
            await editor.release()
            Issue.record("the presentation editor session was not command-ready: \(opened)")
            return
        }

        let runtimeB = LiveOfficeQualification.makeRuntime(
            reference: reference, workspace: workspace, conversationID: conversationID,
            allowedTools: LiveOfficeQualification.presentationEngineTools, executor: executor)
        await runtimeB.injectSystemContext("""
        The presentation deck-acceptance.pptx is open in the Floe Office editor. \
        Do exactly these steps, in order, then stop:
        1. Call document.office.edit with action="read", path="deck-acceptance.pptx". \
        Copy the exact sha256.
        2. Call document.office.edit with action="propose", path="deck-acceptance.pptx", \
        expected_sha256=<that sha256>, summary="Duplicate the first slide", \
        commands=[{"id":"pptx.duplicateSlide","arguments":{"at":"1"}}].
        3. Copy the proposal_id from the propose result and call document.office.edit with \
        action="apply", path="deck-acceptance.pptx", proposal_id=<that proposal_id>, \
        output="deck-duplicated.pptx". Do not pass grant_id.
        Do not call any other tool. Then reply in one short sentence.
        """)
        let startedB = Date()
        try await runtimeB.start(goal: "按步骤复制 deck-acceptance.pptx 的第一页。")
        let stateB = await runtimeB.state
        let transcriptB = await recorder.dump()
        LiveOfficeQualification.exportEvidence(
            label: "presentation-phase-b",
            text: "model=\(reference.remoteModelID) seconds=\(Int(Date().timeIntervalSince(startedB)))\n"
                + "state=\(stateB)\n\(transcriptB)")
        await editor.release()
        if case .completed = stateB {} else {
            Issue.record("Presentation phase B did not complete: \(stateB)")
            return
        }

        let editCalls = await recorder.calls(named: "document.office.edit")
        #expect(editCalls.contains { $0.arguments.contains("\"apply\"") && $0.output.contains("status=saved") },
                "the slide duplicate apply must complete: \(transcriptB)")

        let duplicatedURL = workspace.appendingPathComponent("deck-duplicated.pptx")
        #expect(FileManager.default.fileExists(atPath: duplicatedURL.path),
                "the verified duplicated copy must exist: \(transcriptB)")
        // Contract: `pptx.duplicateSlide{at:N}` duplicates the slide at
        // 1-based position N and the engine inserts the copy immediately
        // AFTER its source (the plan sends `.uno:DuplicatePage` with
        // InsertPos = N-1; the pinned engine keeps the standard
        // duplicate-right-after-source order, it does not append at the end).
        // So duplicating slide 1 of [第一页, 第二页(edited)] yields
        // [第一页, 第一页 copy, 第二页(edited)].
        let duplicated = try QualificationPresentation(url: duplicatedURL)
        #expect(duplicated.slideTexts.count == 3, "the edited copy must contain the duplicated slide: \(transcriptB)")
        if duplicated.slideTexts.count == 3 {
            #expect(duplicated.slideTexts[0].contains("第一页：保持不变"))
            #expect(duplicated.slideTexts[1].contains("第一页：保持不变"),
                    "the duplicate must sit immediately after its source slide: \(duplicated.slideTexts)")
            #expect(duplicated.slideTexts[2].contains("第二页：第一次编辑完成（FLOE-PPT-E1）"),
                    "the edited slide must follow the inserted copy: \(duplicated.slideTexts)")
        }
        #expect(duplicated.notesTexts.count == 3,
                "the duplicated slide must carry a notes slide: \(duplicated.notesTexts)")
        if duplicated.notesTexts.count == 3 {
            #expect(duplicated.notesTexts[1].contains("备注一：保持不变。"),
                    "the duplicated slide must keep its speaker notes next to its source: \(duplicated.notesTexts)")
            #expect(duplicated.notesTexts[2].contains("备注二：第一次编辑完成（FLOE-PPT-E1）。"),
                    "the edited notes slide must follow the inserted copy: \(duplicated.notesTexts)")
        }
        #expect(try LiveOfficeQualification.sha256Hex(of: deckURL) == phaseASHA,
                "the automatic copy must never modify the source deck")

        try LiveOfficeQualification.exportArtifacts(
            label: "presentation", workspace: workspace,
            files: [("deck-acceptance.pptx", deckURL), ("deck-duplicated.pptx", duplicatedURL)])
    }

    // MARK: Notes cover — internal assistant read -> set -> read -> restore

    @Test(.timeLimit(.minutes(10)), .enabled(if: LiveOfficeQualification.isEnabled))
    func notesCoverAssistantSetsReadsAndRestoresTheCover() async throws {
        let reference = try LiveOfficeQualification.providerReference()
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-live-cover-\(UUID().uuidString)", isDirectory: true)
        // The store root keeps the cover resource the test asserts on: it is
        // deleted only after that resource was exported.
        defer { LiveOfficeQualification.cleanupIfExported(storeRoot) }
        let store = try NotesStore(root: storeRoot)
        await NotesRepository.shared.setStoreOverride(store)
        defer { Task { await NotesRepository.shared.setStoreOverride(nil) } }

        // Task-owned synthetic raster attached to the selected document, so
        // the read's `availableImageResources` and the resourceID route are
        // both exercised through the real asset authorization.
        let rasterURL = storeRoot.appendingPathComponent("cover-candidate.png")
        try Self.syntheticPNG(seed: 7).write(to: rasterURL)
        let rasterResourceID = try await store.importResource(from: rasterURL, mediaType: "image/png")

        var document = NoteDocument(kind: .notebook, title: "封面验收文档")
        document.pages[0].elements = [
            NoteElement(frame: NoteRect(x: 40, y: 40, width: 400, height: 120),
                        text: "正文段落保持不动（FLOE-COVER-BODY）。", fontSize: 24),
            NoteElement(kind: .image, frame: NoteRect(x: 40, y: 200, width: 120, height: 120),
                        text: "", resourceID: rasterResourceID)
        ]
        let created = try await store.create(document)
        let conversationID = UUID()
        try await store.bindAssistant(conversationID: conversationID,
                                      documentID: created.id, canEdit: true)

        let registry = ToolRunnerRegistry()
        NotesToolRegistration.register()
        registry.register(NotesReadTool())
        registry.register(NotesCoverTool())
        let recorder = LiveToolCallRecorder()
        let executor = RecordingCatalogExecutor(inner: CatalogToolExecutor(runners: registry),
                                                recorder: recorder)

        let runtime = LiveOfficeQualification.makeRuntime(
            reference: reference, workspace: storeRoot, conversationID: conversationID,
            allowedTools: LiveOfficeQualification.coverTools, executor: executor)
        await runtime.injectSystemContext("""
        This is an authorized synthetic Notes qualification run on a review device. \
        The task already has exactly one editable Notes document selected: \
        documentID=\(created.id.uuidString), content revision=\(created.revision). \
        Do exactly these steps, in order, then stop:
        1. Call notes.cover with documentID="\(created.id.uuidString)" to read the current \
        cover. Then call notes.read with that same documentID once to confirm the document \
        summary (coverMode/coverRevision).
        2. Call notes.cover with documentID="\(created.id.uuidString)", action="set", \
        expectedRevision=\(created.revision), expectedCoverRevision=<the coverRevision you \
        just read>, resourceID=<the image resourceID listed in the cover read result's \
        availableImageResources>.
        3. Call notes.cover with documentID="\(created.id.uuidString)" again to read the \
        settled cover (expect mode=custom).
        4. Call notes.cover with documentID="\(created.id.uuidString)", action="restore", \
        expectedRevision=\(created.revision), expectedCoverRevision=<the coverRevision from \
        step 3>.
        Do not call any other tool. Then reply in one short sentence.
        """)
        let started = Date()
        try await runtime.start(goal: "按步骤读取、设置并恢复该手记文档的自定义封面。")
        let state = await runtime.state
        let transcript = await recorder.dump()
        LiveOfficeQualification.exportEvidence(
            label: "notes-cover",
            text: "model=\(reference.remoteModelID) seconds=\(Int(Date().timeIntervalSince(started)))\n"
                + "state=\(state)\n\(transcript)")
        await NotesRepository.shared.setStoreOverride(nil)
        if case .completed = state {} else {
            Issue.record("The cover run did not complete: \(state)")
            return
        }

        let coverCalls = await recorder.calls(named: "notes.cover")
        #expect(coverCalls.count >= 4, "read -> set -> read -> restore needs four notes.cover calls: \(transcript)")
        #expect(coverCalls.contains { $0.arguments.contains("\"set\"") && $0.status == "ok" },
                "the cover set must execute through the real tool: \(transcript)")
        #expect(coverCalls.contains { $0.arguments.contains("\"restore\"") && $0.status == "ok" },
                "the cover restore must execute through the real tool: \(transcript)")
        let allCoverCalls = await recorder.calls
        #expect(allCoverCalls.allSatisfy { $0.status != "needsUser" },
                "the cover binding must not trigger a confirmation card: \(transcript)")

        // Store truth after the run: restored, revisions and body intact.
        let live = try await store.document(created.id)
        #expect(live.coverResourceID == nil, "restore must return to the automatic cover")
        #expect(live.normalizedCoverRevision == 2, "set+restore must land on cover revision 2")
        #expect(live.revision == created.revision, "cover commands never move the content revision")
        #expect(live.title == created.title)
        #expect(live.pages == created.pages, "the original document body must be unchanged")

        // The cover asset really persisted while set: read the resource id the
        // set call reported and prove its file exists with an image type.
        if let setCall = coverCalls.first(where: { $0.arguments.contains("\"set\"") }),
           let setOutput = Self.json(fromToolOutput: setCall.output),
           let cover = setOutput["cover"] as? [String: Any],
           let resourceIDString = cover["resourceID"] as? String,
           let resourceID = UUID(uuidString: resourceIDString) {
            let resourceURL = try await store.resourceURL(resourceID)
            let mediaType = try await store.resourceMediaType(resourceID)
            #expect(FileManager.default.fileExists(atPath: resourceURL.path),
                    "the applied cover resource must persist on disk")
            #expect(mediaType == "image/png",
                    "the applied cover must be a normalized stored PNG")
            try LiveOfficeQualification.exportArtifacts(
                label: "notes-cover", workspace: storeRoot,
                files: [("applied-cover.png", resourceURL)])
        } else {
            Issue.record("the set call did not report a cover resourceID: \(transcript)")
        }
    }

    // MARK: Live helpers

    /// A real 2x2 PNG (alpha) whose pixel bytes differ per seed.
    private static func syntheticPNG(seed: UInt8) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            context.cgContext.setFillColor(UIColor(red: CGFloat(seed) / 255.0,
                                                   green: 0.25, blue: 0.75, alpha: 1).cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return image.pngData() ?? Data()
    }

    /// Extracts the first JSON object from a tool output summary (tolerates
    /// any `key=value` prefix the tool may print before its JSON body).
    private static func json(fromToolOutput output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        let candidate = String(output[start...])
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
#endif
