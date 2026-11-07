import Foundation
import FloeChemistryCore

public actor ChemistryService {
    public let store: ChemistryProjectStore
    private let authorize: ChemistryAuthorizer
    var backends: [String: any ChemistryBackend]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var ownedRuns: Set<UUID> = []

    public init(store: ChemistryProjectStore, backends: [any ChemistryBackend] = [NativeChemistryBackend()],
                authorize: @escaping ChemistryAuthorizer) throws {
        guard Set(backends.map(\.environmentID)).count == backends.count else { throw ChemistryError.invalid("Duplicate execution environment.") }
        self.store = store; self.backends = Dictionary(uniqueKeysWithValues: backends.map { ($0.environmentID, $0) }); self.authorize = authorize
    }
    func access(_ id: UUID?, _ action: ChemistryAccessAction, _ environment: String? = nil) async throws {
        try await authorize(ChemistryAccess(projectID: id, action: action, environmentID: environment))
    }
    public func capabilities() -> [String: [String]] { backends.mapValues { $0.methods.sorted() } }
    public func projects() async throws -> [ChemistryProject] {
        try await access(nil, .list)
        return try await store.list()
    }
    public func create(title: String) async throws -> ChemistryProject {
        let project = ChemistryProject(title: title)
        try await access(project.id, .create)
        return try await store.save(project, expectedRevision: 0)
    }
    public func project(_ id: UUID) async throws -> ChemistryProject {
        try await access(id, .read)
        var p = try await store.load(id)
        for i in p.runs.indices where [.queued, .running].contains(p.runs[i].status) && !ownedRuns.contains(p.runs[i].id) && p.runs[i].externalExecution == nil {
            p.runs[i].status = .interrupted; p.runs[i].error = "Execution was interrupted; the saved input can be run again."
            p.runs[i].finishedAt = Date()
        }
        // Reads never write storage or require an edit grant. Interrupted ownership is
        // reflected now and persisted with the next authorized mutation.
        return p
    }
    func mutate(_ id: UUID, _ change: (inout ChemistryProject) throws -> Void) async throws -> ChemistryProject {
        var lastConflict: ChemistryError?
        for _ in 0..<4 {
            var p = try await store.load(id); let revision = p.revision; let original = p
            for i in p.runs.indices where [.queued, .running].contains(p.runs[i].status) && !ownedRuns.contains(p.runs[i].id) && p.runs[i].externalExecution == nil {
                p.runs[i].status = .interrupted; p.runs[i].finishedAt = Date()
                p.runs[i].error = "Execution was interrupted; the saved input can be run again."
            }
            try change(&p)
            if p == original { return p }
            do { return try await store.save(p, expectedRevision: revision) }
            catch let e as ChemistryError {
                guard case .conflict = e else { throw e }; lastConflict = e
            }
        }
        throw lastConflict ?? ChemistryError.invalid("Cannot update the project.")
    }
    public func saveDocument(_ id: UUID, blocks: [ChemistryBlock], expectedRevision: UInt64) async throws -> ChemistryProject {
        try await access(id, .edit)
        var p = try await store.load(id)
        guard p.revision == expectedRevision else { throw ChemistryError.conflict(expected: expectedRevision, actual: p.revision) }
        p.blocks = blocks
        return try await store.save(p, expectedRevision: expectedRevision)
    }
    public func addText(_ id: UUID, text: String) async throws -> ChemistryProject {
        try await access(id, .edit)
        return try await mutate(id) { $0.blocks.append(ChemistryBlock(text: text)) }
    }
    public func updateText(_ id: UUID, blockID: UUID, expectedText: String, text: String) async throws -> ChemistryProject {
        try await access(id, .edit)
        return try await mutate(id) { p in
            guard let i = p.blocks.firstIndex(where: { $0.id == blockID }), p.blocks[i].text == expectedText else { throw ChemistryError.invalid("The document block changed; your draft is retained.") }
            p.blocks[i].text = text
        }
    }
    public func history(_ id: UUID) async throws -> [ChemistryRevision] {
        try await access(id, .read); return try await store.history(id)
    }
    public func restore(_ revision: ChemistryRevision, expectedRevision: UInt64) async throws -> ChemistryProject {
        try await access(revision.projectID, .restore)
        let p = try await store.load(revision.projectID)
        guard !p.runs.contains(where: {
            ownedRuns.contains($0.id) || ($0.externalExecution != nil && [.queued, .running].contains($0.status))
        }) else { throw ChemistryError.unavailable("Stop active calculations before restoring a revision.") }
        return try await store.restore(revision, expectedRevision: expectedRevision)
    }
    public func setEnvironment(_ id: UUID, environmentID: String) async throws -> ChemistryProject {
        try await access(id, .edit, environmentID)
        guard backends[environmentID] != nil else { throw ChemistryError.unavailable("Configure this execution environment first.") }
        return try await mutate(id) { $0.defaultEnvironmentID = environmentID }
    }
    private func prepare(title: String, kind: ChemicalKind, format: String, source: String) async throws -> ChemicalObject {
        guard source.utf8.count <= 16 * 1024 * 1024 else { throw ChemistryError.invalid("Input exceeds its size limit.") }
        if kind == .spectrum {
            let result = try SpectrumAnalysis.csv(source)
            let facts = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
            return ChemicalObject(title: title, kind: kind, format: "csv", source: source, facts: facts)
        }
        if kind == .note { return ChemicalObject(title: title, kind: kind, format: "text", source: source) }
        if kind == .reaction {
            let facts = try await NativeChemistryBackend().evaluate(ChemistryRequest(operation: "reaction.balance", format: "reaction.json", data: source))
            return ChemicalObject(title: title, kind: kind, format: "reaction.json", source: source,
                                  facts: facts)
        }
        let result = try await NativeChemistryBackend().evaluate(ChemistryRequest(operation: "parse", format: format, data: source))
        guard result["cjson"]?.string != nil else { throw ChemistryError.invalid("The engine did not return a structure.") }
        // Keep the authoritative input. CJSON is derived display/calculation data and
        // cannot represent every stereo descriptor, residue record or drawing annotation.
        var object = ChemicalObject(title: title, kind: kind, format: format, source: source, facts: result)
        object.originalFormat = format; object.originalSource = source
        return object
    }
    /// Save Ketcher's full drawing even when it is incomplete or has no MOL equivalent.
    /// Numerical methods continue to receive the explicitly identified source format.
    public func saveSketch(_ id: UUID, objectID: UUID, expectedObjectRevision: UInt64,
                           ket: String, format: String?, source: String?, smiles: String?, properties: [String: String]? = nil) async throws -> ChemicalObject {
        try await access(id, .edit)
        guard ket.utf8.count <= 16 * 1024 * 1024,
              (source?.utf8.count ?? 0) <= 16 * 1024 * 1024,
              (smiles?.utf8.count ?? 0) <= 1024 * 1024,
              expectedObjectRevision < UInt64.max,
              format == nil || ["mol", "rxn"].contains(format!),
              case .object = try JSONDecoder().decode(JSONValue.self, from: Data(ket.utf8)) else {
            throw ChemistryError.invalid("Invalid or oversized chemical drawing.")
        }
        let p = try await store.load(id)
        guard var object = p.objects.first(where: { $0.id == objectID }), [.molecule, .reaction].contains(object.kind) else {
            throw ChemistryError.invalid("This object is not a chemical drawing.")
        }
        object.format = source == nil ? "ket" : (format ?? "ket")
        object.source = source ?? ket; object.sketchDocument = ket; object.sketchSMILES = smiles
        object.revision = expectedObjectRevision + 1
        if object.format == "rxn" { object.kind = .reaction }
        else if object.format == "mol" { object.kind = .molecule }
        if object.format == "mol", let result = try? await NativeChemistryBackend().evaluate(ChemistryRequest(operation: "parse", format: "mol", data: object.source)) {
            object.facts = result
        } else {
            object.facts = .object(["drawingOnly": .bool(true)])
        }
        if object.format == "mol", case .object(var facts) = object.facts {
            facts["compositionOnly"] = .bool(true)
            facts["geometryDimension"] = .number(2)
            if let gross = properties?["gross"]?.replacingOccurrences(of: " ", with: ""), gross.utf8.count <= 4096,
               let composition = try? ChemicalFormula(gross), let explicit = facts["formula"]?.string.flatMap({ try? ChemicalFormula($0) }),
               composition.elements.filter({ $0.key != "H" }) == explicit.elements.filter({ $0.key != "H" }),
               let weightText = properties?["molecular-weight"], let weight = Double(weightText), weight.isFinite, weight > 0, weight < 1e9 {
                facts["formula"] = .string(gross); facts["mass"] = .number(weight)
                facts["compositionOnly"] = .bool(false)
                facts["implicitHydrogens"] = .number(Double(max(0,(composition.elements["H"] ?? 0)-(explicit.elements["H"] ?? 0))))
                facts["descriptorEngine"] = .string("Indigo WebAssembly · Ketcher 3.18.0")
            }
            object.facts = .object(facts)
        }
        let recovery = ChemistryDrawingRecovery(projectID: id, object: object)
        try await store.saveDrawingRecovery(recovery)
        try await access(id, .edit)
        let replacement = object
        _ = try await mutate(id) { p in
            guard let i = p.objects.firstIndex(where: { $0.id == objectID }) else { throw ChemistryError.invalid("Object not found.") }
            guard p.objects[i].revision == expectedObjectRevision else { throw ChemistryError.conflict(expected: expectedObjectRevision, actual: p.objects[i].revision) }
            p.objects[i] = replacement
        }
        try? await store.removeDrawingRecovery(id, recoveryID: recovery.id)
        return replacement
    }
    public func drawingRecoveries(_ id: UUID) async throws -> [ChemistryDrawingRecovery] {
        try await access(id, .read); return try await store.drawingRecoveries(id)
    }
    public func recoverDrawing(_ id: UUID, recoveryID: UUID) async throws -> ChemicalObject {
        try await access(id, .edit)
        guard var object = try await store.drawingRecoveries(id).first(where: { $0.id == recoveryID })?.object else { throw ChemistryError.invalid("Drawing recovery not found.") }
        object.id = UUID(); object.revision = 0; object.title += " · " + "Recovered"
        let recovered = object
        _ = try await mutate(id) { p in p.objects.append(recovered); p.blocks.append(ChemistryBlock(objectID: recovered.id)) }
        try? await store.removeDrawingRecovery(id, recoveryID: recoveryID)
        return recovered
    }
    public func createDrawing(_ id: UUID, title: String) async throws -> ChemicalObject {
        try await access(id, .edit)
        let ket = "{\"root\":{\"nodes\":[]}}"
        var object = ChemicalObject(title: title, format: "ket", source: ket)
        object.sketchDocument = ket
        _ = try await mutate(id) { p in p.objects.append(object); p.blocks.append(ChemistryBlock(objectID: object.id)) }
        return object
    }
    @discardableResult
    public func importObject(_ id: UUID, title: String, kind: ChemicalKind = .molecule, format: String,
                             source: String, deferPreparation: Bool = false) async throws -> ChemicalObject {
        try await access(id, .edit)
        let object: ChemicalObject
        if deferPreparation {
            guard source.utf8.count <= 16 * 1024 * 1024, !source.isEmpty,
                  [.molecule, .crystal, .biomolecule, .reaction].contains(kind),
                  ["smi", "smiles", "mol", "sdf", "pdb", "xyz", "cjson", "cif", "mmcif", "reaction.json"].contains(format) else {
                throw ChemistryError.invalid("Unsupported or oversized source for worker preparation.")
            }
            var preserved = ChemicalObject(title: title, kind: kind, format: format, source: source,
                facts: .object(["preparationRequired": .bool(true)]))
            preserved.originalFormat = format; preserved.originalSource = source
            object = preserved
        } else {
            object = try await prepare(title: title, kind: kind, format: format, source: source)
        }
        try await access(id, .edit)
        _ = try await mutate(id) { p in
            p.objects.append(object); p.blocks.append(ChemistryBlock(objectID: object.id))
        }
        return object
    }
    public func replaceObject(_ id: UUID, objectID: UUID, expectedObjectRevision: UInt64,
                              format: String, source: String) async throws -> ChemicalObject {
        try await replace(id, objectID: objectID, expectedObjectRevision: expectedObjectRevision,
                          format: format, source: source, matchingInput: nil)
    }
    private func replace(_ id: UUID, objectID: UUID, expectedObjectRevision: UInt64,
                         format: String, source: String, matchingInput: ChemicalObject?,
                         matchingRun: ChemistryRun? = nil) async throws -> ChemicalObject {
        try await access(id, .edit)
        let p = try await store.load(id)
        guard let previous = p.objects.first(where: { $0.id == objectID }) else { throw ChemistryError.invalid("Object not found.") }
        guard previous.revision == expectedObjectRevision else { throw ChemistryError.conflict(expected: expectedObjectRevision, actual: previous.revision) }
        guard matchingInput == nil || matchingInput == previous else { throw ChemistryError.invalid("This result belongs to a different input snapshot.") }
        var updated = try await prepare(title: previous.title, kind: previous.kind, format: format, source: source)
        guard expectedObjectRevision < UInt64.max else { throw ChemistryError.invalid("Object revision overflow.") }
        updated.id = objectID; updated.revision = expectedObjectRevision + 1
        updated.originalFormat = previous.originalFormat; updated.originalSource = previous.originalSource
        try await access(id, .edit)
        let replacement = updated
        _ = try await mutate(id) { p in
            guard let i = p.objects.firstIndex(where: { $0.id == objectID }) else { throw ChemistryError.invalid("Object not found.") }
            guard p.objects[i].revision == expectedObjectRevision else { throw ChemistryError.conflict(expected: expectedObjectRevision, actual: p.objects[i].revision) }
            guard p.objects[i] == previous else { throw ChemistryError.invalid("The input changed while the replacement was being prepared.") }
            if let matchingRun {
                guard p.runs.first(where: { $0.id == matchingRun.id }) == matchingRun, matchingRun.status == .succeeded else {
                    throw ChemistryError.invalid("The calculation changed while its result was being applied.")
                }
            }
            p.objects[i] = replacement
        }
        return replacement
    }
    public func editObject(_ id: UUID, objectID: UUID, expectedObjectRevision: UInt64, edits: JSONValue) async throws -> ChemicalObject {
        try await access(id, .edit)
        let p = try await store.load(id)
        guard let object = p.objects.first(where: { $0.id == objectID }), object.revision == expectedObjectRevision else { throw ChemistryError.invalid("Object changed or is missing.") }
        let output = try await NativeChemistryBackend().evaluate(ChemistryRequest(operation: "edit", format: object.format, data: object.source, options: .object(["edits": edits])))
        guard let source = output["cjson"]?.string else { throw ChemistryError.invalid("No edited structure returned.") }
        return try await replace(id, objectID: objectID, expectedObjectRevision: expectedObjectRevision,
                                 format: "cjson", source: source, matchingInput: object)
    }
    public func start(_ id: UUID, objectID: UUID, method: String, options: JSONValue = .object([:]), environmentID: String? = nil) async throws -> UUID {
        try await access(id, .read)
        let p = try await store.load(id)
        let env = environmentID ?? p.defaultEnvironmentID
        guard let backend = backends[env], backend.methods.contains(method) else { throw ChemistryError.unavailable("Configure an execution environment that supports this method.") }
        guard backend.executionMode == .immediate else { throw ChemistryError.unavailable("Prepare this calculation through its task's configured background jobs.") }
        try await access(id, .compute, env)
        guard let input = p.objects.first(where: { $0.id == objectID }) else { throw ChemistryError.invalid("Object not found.") }
        if ["uff.energy", "uff.optimize"].contains(method), input.requires3DPreparation {
            throw ChemistryError.requiresPrepared3DStructure
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = ChemistryProjectStore.digest(try encoder.encode(input))
        let run = ChemistryRun(input: input, inputDigest: digest, method: method, options: options, environmentID: env, engineVersion: backend.engineVersion)
        ownedRuns.insert(run.id)
        do {
            _ = try await mutate(id) { p in
                guard p.objects.first(where: { $0.id == objectID }) == input else { throw ChemistryError.invalid("Input changed before execution.") }
                p.runs.append(run)
            }
        } catch { ownedRuns.remove(run.id); throw error }
        let request = ChemistryRequest(operation: method, format: input.format, data: input.source, options: options)
        tasks[run.id] = Task {
            do {
                _ = try await self.mutate(id) { p in
                    guard let i = p.runs.firstIndex(where: { $0.id == run.id }), p.runs[i].status == .queued else { throw ChemistryError.cancelled }
                    p.runs[i].status = .running
                }
                let result = try await backend.evaluate(request)
                try Task.checkCancellation()
                try await self.complete(id, runID: run.id, status: .succeeded, result: result, error: nil)
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? ChemistryError) == .cancelled
                try? await self.complete(id, runID: run.id, status: cancelled ? .cancelled : .failed, result: nil, error: error.localizedDescription)
            }
            self.tasks.removeValue(forKey: run.id)
            self.ownedRuns.remove(run.id)
        }
        return run.id
    }
    private func complete(_ id: UUID, runID: UUID, status: ChemistryRunStatus, result: JSONValue?, error: String?) async throws {
        _ = try await mutate(id) { p in
            guard let i = p.runs.firstIndex(where: { $0.id == runID }) else { throw ChemistryError.invalid("Run no longer exists.") }
            guard [.queued, .running].contains(p.runs[i].status) else { return }
            p.runs[i].status = status; p.runs[i].result = result; p.runs[i].error = error; p.runs[i].finishedAt = Date()
        }
    }
    public func cancel(_ id: UUID, runID: UUID) async throws {
        try await access(id, .read)
        let p = try await store.load(id)
        guard let run = p.runs.first(where: { $0.id == runID }) else { throw ChemistryError.invalid("Run not found in this project.") }
        try await access(id, .compute, run.environmentID)
        guard run.externalExecution == nil else {
            throw ChemistryError.unavailable("Cancel this calculation through its execution task so the background job also stops.")
        }
        tasks[runID]?.cancel()
        try await complete(id, runID: runID, status: .cancelled, result: nil, error: "Cancelled.")
    }
    public func wait(_ id: UUID, runID: UUID) async throws -> ChemistryRun {
        try await access(id, .read)
        guard try await store.load(id).runs.contains(where: { $0.id == runID }) else { throw ChemistryError.invalid("Run not found in this project.") }
        if let task = tasks[runID] { await task.value }
        guard let run = try await store.load(id).runs.first(where: { $0.id == runID }) else { throw ChemistryError.invalid("Run not found.") }
        return run
    }
    public func apply(_ id: UUID, runID: UUID, expectedObjectRevision: UInt64) async throws -> ChemicalObject {
        try await access(id, .edit)
        let p = try await store.load(id)
        guard let run = p.runs.first(where: { $0.id == runID }), run.status == .succeeded,
              let result = run.result else { throw ChemistryError.invalid("No completed structure result to apply.") }
        guard expectedObjectRevision == run.input.revision else { throw ChemistryError.invalid("Result belongs to a different input revision.") }
        guard p.objects.first(where: { $0.id == run.input.id }) == run.input else {
            throw ChemistryError.invalid("The input changed after this calculation. Keep the result or run the calculation again.")
        }
        // RDKit's MOL output retains explicit stereochemistry and 3D coordinates.
        // Derived CJSON remains the fallback for engines without a richer structure.
        if let mol = result["molblock"]?.string, !mol.isEmpty {
            return try await replace(id, objectID: run.input.id, expectedObjectRevision: expectedObjectRevision,
                                     format: "mol", source: mol, matchingInput: run.input, matchingRun: run)
        }
        guard let source = result["cjson"]?.string else { throw ChemistryError.invalid("No completed structure result to apply.") }
        return try await replace(id, objectID: run.input.id, expectedObjectRevision: expectedObjectRevision,
                                 format: "cjson", source: source, matchingInput: run.input, matchingRun: run)
    }
    public func export(_ id: UUID, objectID: UUID, format: String) async throws -> String {
        try await access(id, .export)
        guard let object = try await store.load(id).objects.first(where: { $0.id == objectID }) else { throw ChemistryError.invalid("Object not found.") }
        if format == "ket", let drawing = object.sketchDocument { return drawing }
        if format == object.format { return object.source }
        if object.kind == .spectrum || object.kind == .reaction || object.kind == .note {
            guard format == object.format else { throw ChemistryError.unavailable("This object supports its original export format.") }; return object.source
        }
        let result = try await NativeChemistryBackend().evaluate(ChemistryRequest(operation: "export", format: object.format, data: object.source, options: .object(["outputFormat": .string(format)])))
        guard let text = result["text"]?.string else { throw ChemistryError.invalid("Export produced no data.") }; return text
    }
}
