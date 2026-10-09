//
//  CADScriptService.swift
//  FloeCADKit
//
//  ShapeScript records for one FloeCAD document: list/put/remove plus
//  preview (never writes) and apply (one undoable body create/update).
//
//  Parameters: ShapeScript has no public API to override top-level `option`
//  values, so a numeric parameter `foo` is injected as a generated
//  `define param_foo <value>` prelude line; scripts read `param_foo`.
//  Parameter names must match `[A-Za-z_][A-Za-z0-9_]*` (max 64 chars) and
//  values must be finite JSON numbers with |v| ≤ 1e15. Error line numbers are
//  re-based to the user's script (the prelude is not counted). No file paths
//  are accepted anywhere; imports inside a script are refused by
//  `ShapeScriptKit`'s sandboxed delegate.
//
//  Records persist as one JSON blob on `Project.scriptsData` (sliced into
//  `document.json` by `FileCADDocumentStore`), independent of the body
//  records. Removing a record keeps its output body.
//
//  Result binding: every apply records a SHA-256 of the produced render mesh
//  (`outputRenderSHA256`). A later apply re-hashes the live output body; if it
//  no longer matches (a manual edit, an undo, or any other writer) the apply
//  is REFUSED unless the caller makes the conflict explicit with
//  `conflict` = "fork" (keep the edited body, make the script's output a new
//  body) or "rebuild" (explicitly overwrite it). The record metadata is never
//  treated as proof that the body still contains the script output.
//
//  Evaluation runs OFF the main actor (`handle` is async and the interpreter
//  work happens in a detached task) with the wall-clock limit plus task
//  cancellation; callers must await it, so a hostile script cannot freeze the
//  UI. Body/record mutation still happens on the main actor afterwards.
//

import Foundation
import CoreFoundation
import CryptoKit

// MARK: - Record

public nonisolated struct CADScriptRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var source: String
    public var parameters: [String: Double]
    /// The body this script last produced, by stable `BodyID`.
    public var outputBodyID: UUID?
    /// Bumped whenever `source` or `parameters` change.
    public var sourceRevision: Int
    /// `sourceRevision` at the last successful apply.
    public var appliedSourceRevision: Int?
    public var outputTriangleCount: Int?
    /// SHA-256 of the output body's render mesh at the last successful apply.
    /// The live body is re-hashed before an apply; a mismatch is a conflict.
    public var outputRenderSHA256: String?
    /// `FloeCADDocument.revision` at the last successful apply (informational:
    /// the render SHA, not this revision, is the drift check).
    public var outputDocumentRevision: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                name: String,
                source: String,
                parameters: [String: Double] = [:],
                outputBodyID: UUID? = nil,
                sourceRevision: Int = 1,
                appliedSourceRevision: Int? = nil,
                outputTriangleCount: Int? = nil,
                outputRenderSHA256: String? = nil,
                outputDocumentRevision: Int? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.source = source
        self.parameters = parameters
        self.outputBodyID = outputBodyID
        self.sourceRevision = sourceRevision
        self.appliedSourceRevision = appliedSourceRevision
        self.outputTriangleCount = outputTriangleCount
        self.outputRenderSHA256 = outputRenderSHA256
        self.outputDocumentRevision = outputDocumentRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Service

@MainActor
public final class CADScriptService {
    /// The user script's own byte limit (`ShapeScriptKit` re-checks the
    /// composed source, prelude included).
    public static let maxScriptBytes = 64 * 1024
    /// Parameter `foo` is injected into the script as `param_foo`.
    public static let parameterPrefix = "param_"

    private let document: FloeCADDocument
    private var lastEvaluation: [String: Any]?

    public init(document: FloeCADDocument) {
        self.document = document
    }

    // MARK: Action router

    /// All actions are async: the two that evaluate a script (`preview`,
    /// `apply`) run the interpreter in a detached task with the wall-clock
    /// limit and task cancellation, so a hostile script never blocks the main
    /// actor. The cheap record actions complete without suspension.
    public func handle(action: String, args: [String: Any]) async -> [String: Any] {
        switch action {
        case "list": return list()
        case "put": return put(args)
        case "remove": return remove(args)
        case "preview": return await preview(args)
        case "apply": return await apply(args)
        case "status": return status()
        default:
            return Self.fail("unknown_action",
                             "Unknown script action '\(action)'. Use list, put, remove, preview, apply or status.")
        }
    }

    // MARK: list / status

    private func list() -> [String: Any] {
        let records = loadRecords()
        let bodies = document.session.document.bodies
        let scripts: [[String: Any]] = records.map { record in
            var entry = Self.json(record)
            let output = record.outputBodyID.flatMap { output in
                bodies.first { $0.id.raw == output }
            }
            let present = output != nil
            let matches = output.flatMap { body in
                guard let recorded = record.outputRenderSHA256 else { return false }
                return Self.renderHash(body.render) == recorded
            } ?? false
            entry["outputBodyPresent"] = present
            entry["outputMatches"] = matches
            // A record is stale when its source changed since the last apply,
            // its output body is gone, or the body no longer contains exactly
            // what the script produced (manual edit / undo / another writer).
            entry["stale"] = record.outputBodyID == nil
                || record.appliedSourceRevision != record.sourceRevision
                || !present
                || !matches
            return entry
        }
        return ["ok": true, "action": "list", "count": scripts.count, "scripts": scripts]
    }

    private func status() -> [String: Any] {
        ["ok": true,
         "action": "status",
         "hasLastEvaluation": lastEvaluation != nil,
         "lastEvaluation": lastEvaluation ?? [:]]
    }

    // MARK: put / remove

    private func put(_ args: [String: Any]) -> [String: Any] {
        guard let source = args["source"] as? String else {
            return Self.fail("bad_request", "'source' is required.")
        }
        guard source.utf8.count <= Self.maxScriptBytes else {
            return Self.fail("limit_source",
                             "Source is \(source.utf8.count) bytes; the limit is \(Self.maxScriptBytes).")
        }
        let parameters: [String: Double]
        switch Self.parseParameters(args["parameters"]) {
        case .ok(let values): parameters = values
        case .failure(let message): return Self.fail("bad_request", message)
        }
        let name = Self.sanitizeName(args["name"]) ?? "Script"

        var records = loadRecords()
        var record: CADScriptRecord
        if let idString = args["id"] as? String {
            guard let uuid = UUID(uuidString: idString) else {
                return Self.fail("bad_request", "'id' must be a script UUID.")
            }
            if let index = records.firstIndex(where: { $0.id == uuid }) {
                var existing = records[index]
                if existing.source != source || existing.parameters != parameters {
                    existing.sourceRevision += 1
                }
                existing.name = name
                existing.source = source
                existing.parameters = parameters
                existing.updatedAt = Date()
                records[index] = existing
                record = existing
            } else {
                record = CADScriptRecord(id: uuid, name: name, source: source, parameters: parameters)
                records.append(record)
            }
        } else {
            record = CADScriptRecord(name: name, source: source, parameters: parameters)
            records.append(record)
        }
        let persisted = storeRecords(records)
        var response: [String: Any] = ["ok": true,
                                       "action": "put",
                                       "recordPersisted": persisted,
                                       "script": Self.json(record)]
        // The record blob is document state: it must be committed by the
        // caller, or the edit would be lost on reopen.
        response["mutated"] = true
        return response
    }

    private func remove(_ args: [String: Any]) -> [String: Any] {
        guard let idString = args["id"] as? String, let uuid = UUID(uuidString: idString) else {
            return Self.fail("bad_request", "'id' must be a script UUID.")
        }
        var records = loadRecords()
        guard let index = records.firstIndex(where: { $0.id == uuid }) else {
            return Self.fail("unknown_script", "No script with id \(idString).")
        }
        let removed = records.remove(at: index)
        let persisted = storeRecords(records)
        return ["ok": true,
                "action": "remove",
                "mutated": true,
                "recordPersisted": persisted,
                "removed": removed.id.uuidString,
                "note": "The script record was removed; its output body (if any) is kept."]
    }

    // MARK: preview (never writes)

    private func preview(_ args: [String: Any]) async -> [String: Any] {
        let records = loadRecords()
        let source: String
        let parameters: [String: Double]
        var scriptID: UUID?
        var sourceRevision: Int?
        switch resolve(args, records: records) {
        case .failed(let response):
            return response
        case let .inline(inlineSource, inlineParameters):
            source = inlineSource
            parameters = inlineParameters
        case .stored(let record):
            source = record.source
            parameters = record.parameters
            scriptID = record.id
            sourceRevision = record.sourceRevision
        }

        let outcome = await Self.evaluateScript(source: source, parameters: parameters)
        recordEvaluation(action: "preview", scriptID: scriptID, outcome: outcome)
        if let code = outcome.errorCode {
            var response = Self.fail(code, outcome.errorMessage ?? "Evaluation failed.")
            response["line"] = outcome.errorLine
            return response
        }

        var response: [String: Any] = ["ok": true,
                                       "action": "preview",
                                       "preview": true,
                                       "mutated": false,
                                       "triangleCount": outcome.triangleCount,
                                       "polygonCount": outcome.polygonCount,
                                       "parameterPrefix": Self.parameterPrefix,
                                       "unit": "mm"]
        if let scriptID {
            response["scriptID"] = scriptID.uuidString
            response["sourceRevision"] = sourceRevision
        }
        if let mesh = outcome.mesh {
            let aabb = mesh.localAABB
            response["bounds"] = [
                [Double(aabb.min.x), Double(aabb.min.y), Double(aabb.min.z)],
                [Double(aabb.max.x), Double(aabb.max.y), Double(aabb.max.z)],
            ]
            // Transient preview geometry for the UI: the actual evaluated
            // mesh (bounded) plus the content hash/change count that bind the
            // subsequent apply. Nothing here writes the document.
            // `outcome.mesh` is already the render mesh (positions/indices).
            let render = mesh
            if let previewHash = CADTransientMeshPreview.hash(of: render) {
                response["previewHash"] = previewHash
                response["previewRevision"] = document.store.revision
                response["previewChangeCount"] = document.session.changeCount
            }
            if let snapshot = CADTransientMeshPreview.snapshot(of: [render]) {
                response["mesh"] = CADTransientMeshPreview.payload(snapshot)
            }
        }
        return response
    }

    // MARK: apply (one undoable body create/update + record binding)

    /// Conflict mode when the recorded output body no longer carries exactly
    /// the script result (manual edit, undo, another writer). The default
    /// (`auto`) refuses; `fork` keeps the edited body and makes the script's
    /// output a new body; `rebuild` overwrites the edited body explicitly.
    private enum ApplyConflict: String {
        case auto, fork, rebuild
    }

    private func apply(_ args: [String: Any]) async -> [String: Any] {
        let conflictRaw = (args["conflict"] as? String) ?? ApplyConflict.auto.rawValue
        guard let conflict = ApplyConflict(rawValue: conflictRaw) else {
            return Self.fail("bad_request",
                             "'conflict' must be auto, fork or rebuild (got '\(conflictRaw)').")
        }
        var records = loadRecords()
        var record: CADScriptRecord
        var recordIndex: Int?
        switch resolve(args, records: records) {
        case .failed(let response):
            return response
        case let .inline(source, parameters):
            record = CADScriptRecord(name: Self.sanitizeName(args["name"]) ?? "Script",
                                     source: source,
                                     parameters: parameters)
        case .stored(let stored):
            record = stored
            recordIndex = records.firstIndex { $0.id == stored.id }
        }

        let outcome = await Self.evaluateScript(source: record.source, parameters: record.parameters)
        recordEvaluation(action: "apply", scriptID: recordIndex.map { records[$0].id }, outcome: outcome)
        if let code = outcome.errorCode {
            var response = Self.fail(code, outcome.errorMessage ?? "Evaluation failed.")
            response["line"] = outcome.errorLine
            response["mutated"] = false
            return response
        }
        guard let render = outcome.mesh else {
            return Self.fail("empty_geometry", "The script produced no mesh; nothing was created.")
        }
        guard let renderHash = Self.renderHash(render) else {
            return Self.fail("hash_failed", "The script result could not be fingerprinted; nothing was created.")
        }

        // Preview binding: when the caller previewed this exact evaluation it
        // passes the transient preview hash (and optionally the change count).
        // A mismatch means the inputs moved between preview and apply — refuse
        // rather than commit geometry the user never saw.
        if let expectedHash = args["expectedPreviewHash"] as? String, !expectedHash.isEmpty {
            guard let previewHash = CADTransientMeshPreview.hash(of: render),
                  previewHash == expectedHash else {
                return Self.fail("preview_stale",
                                 "The script output changed since the preview; preview again before applying.")
            }
        }
        if let rawCount = args["expectedChangeCount"] {
            let expectedCount = (rawCount as? Int) ?? (rawCount as? NSNumber)?.intValue
            if let expectedCount, expectedCount != document.session.changeCount {
                return Self.fail("preview_stale",
                                 "The document changed since the preview; preview again before applying.")
            }
        }

        // Result binding: the record's output body must still contain exactly
        // the mesh the last apply produced, and the document must still be at
        // the revision that apply committed. A live hash mismatch is a manual
        // edit or an undo; a revision mismatch is ANY other committed change.
        // Neither is silently overwritten — re-applying stale script output
        // over someone else's edit is exactly the corruption this gate exists
        // to prevent.
        let existing = record.outputBodyID.flatMap { output in
            document.session.document.bodies.first { $0.id.raw == output }
        }
        if let existing, conflict == .auto {
            let liveHash = Self.renderHash(existing.render)
            let hashMismatch = liveHash != record.outputRenderSHA256
            let revisionMismatch = record.outputDocumentRevision
                .map { $0 != document.revision } ?? false
            if hashMismatch || revisionMismatch {
                let reason = hashMismatch
                    ? "The script's output body '\(existing.name)' was edited (or the apply was undone) since the last run."
                    : "The document changed (revision \(record.outputDocumentRevision ?? -1) → \(document.revision)) since the script's last apply."
                return Self.fail(
                    "output_changed",
                    "\(reason) Re-run with conflict=fork to keep the current state and create "
                    + "a new script output, or conflict=rebuild to overwrite it explicitly.")
            }
        }

        // Create or update the output body AND update the record blob in ONE
        // composite command: a single undo reverses geometry and metadata
        // together, so the applied metadata can never go stale on its own.
        // An in-place update keeps the live body's ID, name, placement and
        // appearance (`ReplaceBodyCommand` preserves appearance itself).
        let outputID: UUID
        let updated: Bool
        let bodyCommand: DocumentCommand
        if let existing, conflict != .fork {
            var localDocument = document.session.document
            var body = Body(id: existing.id,
                            name: existing.name,
                            transform: existing.transform,
                            primitive: nil,
                            render: render,
                            revision: localDocument.nextRevision())
            body.euclid = EuclidBridge.euclidMesh(from: render)
            bodyCommand = ReplaceBodyCommand(title: "Update Script",
                                             before: existing,
                                             after: body)
            outputID = existing.id.raw
            updated = true
        } else {
            var localDocument = document.session.document
            let base = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = localDocument.uniqueBodyName(base: base.isEmpty ? "Script" : base)
            var body = Body(id: BodyID(),
                            name: name,
                            transform: .identity,
                            primitive: nil,
                            render: render,
                            revision: localDocument.nextRevision())
            body.euclid = EuclidBridge.euclidMesh(from: render)
            bodyCommand = AddBodyCommand(body: body, title: "Script \(name)")
            outputID = body.id.raw
            updated = false
        }

        record.outputBodyID = outputID
        record.appliedSourceRevision = record.sourceRevision
        record.outputTriangleCount = outcome.triangleCount
        record.outputRenderSHA256 = renderHash
        record.outputDocumentRevision = document.revision
        record.updatedAt = Date()
        if let recordIndex {
            records[recordIndex] = record
        } else {
            records.append(record)
        }
        guard let scriptsData = try? JSONEncoder().encode(records) else {
            return Self.fail("persist_failed",
                             "The script result could not be recorded; nothing was applied.")
        }
        document.session.perform(CompositeCommand(
            title: "Apply Script",
            commands: [
                bodyCommand,
                SetScriptsDataCommand(before: document.session.document.scriptsData,
                                      after: scriptsData),
            ]))

        return ["ok": true,
                "action": "apply",
                "mutated": true,
                "updated": updated,
                "recordPersisted": true,
                "outputBodyID": outputID.uuidString,
                "triangleCount": outcome.triangleCount,
                "polygonCount": outcome.polygonCount,
                "parameterPrefix": Self.parameterPrefix,
                "sourceRevision": record.sourceRevision,
                "documentRevision": document.revision,
                "conflictMode": conflict.rawValue,
                "exactness": "mesh",
                "script": Self.json(record)]
    }

    /// SHA-256 of a render mesh in its persisted blob form. Used as the
    /// result binding; nil when the mesh cannot be encoded.
    static func renderHash(_ mesh: RenderMesh) -> String? {
        guard let data = try? MeshBlob.encode(mesh) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Resolution

    private enum ScriptResolution {
        case inline(source: String, parameters: [String: Double])
        case stored(CADScriptRecord)
        case failed([String: Any])
    }

    private func resolve(_ args: [String: Any], records: [CADScriptRecord]) -> ScriptResolution {
        if let idString = args["id"] as? String {
            guard let uuid = UUID(uuidString: idString) else {
                return .failed(Self.fail("bad_request", "'id' must be a script UUID."))
            }
            guard let record = records.first(where: { $0.id == uuid }) else {
                return .failed(Self.fail("unknown_script", "No script with id \(idString)."))
            }
            return .stored(record)
        }
        if let source = args["source"] as? String {
            guard source.utf8.count <= Self.maxScriptBytes else {
                return .failed(Self.fail("limit_source",
                                         "Source is \(source.utf8.count) bytes; the limit is \(Self.maxScriptBytes)."))
            }
            switch Self.parseParameters(args["parameters"]) {
            case .ok(let parameters):
                return .inline(source: source, parameters: parameters)
            case .failure(let message):
                return .failed(Self.fail("bad_request", message))
            }
        }
        return .failed(Self.fail("bad_request", "Provide 'id' or 'source'."))
    }

    // MARK: Evaluation (off the main actor)

    /// Runs the interpreter in a detached task. The wall-clock limit is
    /// enforced by `ShapeScriptKit`; task cancellation (tool/session cancel)
    /// is folded into the same cancellation closure, so a cancelled apply
    /// stops building geometry instead of finishing on the main thread.
    private static func evaluateScript(source: String,
                                       parameters: [String: Double]) async -> ShapeScriptOutcome {
        guard let prelude = parameterPrelude(parameters) else {
            return ShapeScriptOutcome(errorCode: "bad_request",
                                      errorMessage: "Parameters failed validation.")
        }
        var limits = ShapeScriptLimits()
        // The user's script is independently capped at `maxScriptBytes`; the
        // kit's own cap is widened by the small generated prelude so a
        // just-under-limit script cannot fail on the header.
        limits.maxSourceBytes = Self.maxScriptBytes + prelude.utf8.count
        let preludeLines = prelude.isEmpty ? 0 : prelude.components(separatedBy: "\n").count - 1
        let composed = prelude + source
        let flag = ScriptCancellationFlag()
        let task = Task.detached(priority: .userInitiated) {
            ShapeScriptKit.evaluate(source: composed,
                                    limits: limits,
                                    lineOffset: preludeLines,
                                    externalCancellation: { flag.isCancelled || Task.isCancelled })
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            flag.cancel()
            task.cancel()
        }
    }

    /// `define param_<name> <value>` lines, one per parameter, plus a comment
    /// line and a trailing blank line. Scripts refer to `param_<name>`.
    private static func parameterPrelude(_ parameters: [String: Double]) -> String? {
        guard !parameters.isEmpty else { return "" }
        var lines = ["// FloeCAD parameters: available as param_<name>; 1 unit = 1 mm."]
        for key in parameters.keys.sorted() {
            guard let value = parameters[key], let text = formatParameter(value) else { return nil }
            lines.append("define \(parameterPrefix)\(key) \(text)")
        }
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Fixed-notation decimal (ShapeScript's lexer has no exponent syntax).
    private static func formatParameter(_ value: Double) -> String? {
        guard value.isFinite, abs(value) <= 1e15 else { return nil }
        if value == 0 { return "0" }
        var text = String(format: "%.15f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }

    private enum ParameterParse {
        case ok([String: Double])
        case failure(String)
    }

    private static func parseParameters(_ raw: Any?) -> ParameterParse {
        guard let raw else { return .ok([:]) }
        guard let dictionary = raw as? [String: Any] else {
            return .failure("'parameters' must be a JSON object of number values.")
        }
        var result: [String: Double] = [:]
        for (key, value) in dictionary {
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#,
                            options: .regularExpression) != nil else {
                return .failure("Parameter name '\(key)' must match [A-Za-z_][A-Za-z0-9_]* "
                                + "(max 64 characters).")
            }
            if isBoolean(value) {
                return .failure("Parameter '\(key)' must be a number.")
            }
            let number: Double
            if let nsNumber = value as? NSNumber {
                number = nsNumber.doubleValue
            } else if let double = value as? Double {
                number = double
            } else if let integer = value as? Int {
                number = Double(integer)
            } else {
                return .failure("Parameter '\(key)' must be a number.")
            }
            guard number.isFinite, abs(number) <= 1e15 else {
                return .failure("Parameter '\(key)' must be finite with magnitude ≤ 1e15.")
            }
            result[key] = number
        }
        return .ok(result)
    }

    /// `NSNumber(1) is Bool` is true under Swift bridging, so JSON numbers
    /// must be distinguished from real booleans by their CoreFoundation type.
    private static func isBoolean(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        return value is Bool
    }

    // MARK: Persistence

    private func loadRecords() -> [CADScriptRecord] {
        guard let data = document.session.document.scriptsData, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([CADScriptRecord].self, from: data)) ?? []
    }

    @discardableResult
    private func storeRecords(_ records: [CADScriptRecord]) -> Bool {
        guard let data = try? JSONEncoder().encode(records) else { return false }
        document.session.perform(SetScriptsDataCommand(
            before: document.session.document.scriptsData, after: data))
        return true
    }

    // MARK: Stats / JSON

    private func recordEvaluation(action: String,
                                  scriptID: UUID?,
                                  outcome: ShapeScriptOutcome) {
        var entry: [String: Any] = ["action": action,
                                    "triangleCount": outcome.triangleCount,
                                    "polygonCount": outcome.polygonCount,
                                    "at": Self.isoFormatter.string(from: Date())]
        if let scriptID { entry["scriptID"] = scriptID.uuidString }
        if let code = outcome.errorCode { entry["error"] = code }
        if let message = outcome.errorMessage { entry["message"] = message }
        if let line = outcome.errorLine { entry["line"] = line }
        lastEvaluation = entry
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private static func json(_ record: CADScriptRecord) -> [String: Any] {
        var entry: [String: Any] = ["id": record.id.uuidString,
                                    "name": record.name,
                                    "source": record.source,
                                    "parameters": record.parameters,
                                    "sourceRevision": record.sourceRevision,
                                    "createdAt": isoFormatter.string(from: record.createdAt),
                                    "updatedAt": isoFormatter.string(from: record.updatedAt)]
        if let outputBodyID = record.outputBodyID { entry["outputBodyID"] = outputBodyID.uuidString }
        if let applied = record.appliedSourceRevision { entry["appliedSourceRevision"] = applied }
        if let count = record.outputTriangleCount { entry["outputTriangleCount"] = count }
        if let hash = record.outputRenderSHA256 { entry["outputRenderSHA256"] = hash }
        if let revision = record.outputDocumentRevision { entry["outputDocumentRevision"] = revision }
        return entry
    }

    // MARK: Response helpers

    static func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }

    private static func sanitizeName(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(120))
    }
}

/// Cross-thread cancellation flag handed to `ShapeScriptKit`'s detached
/// evaluation. `@unchecked Sendable`: only the lock-guarded boolean is shared.
private nonisolated final class ScriptCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
