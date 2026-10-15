// FloeWorkbench — CAD session identity + transaction gate tests (Build265 review).
import Foundation
import Testing
@testable import FloeWorkbench

@Suite("CAD document session identity and gating")
struct CadDocumentSupportTests {
    @Test("same relative filename under different roots yields different session keys")
    func distinctRootsDistinctKeys() {
        let owner = UUID()
        let a = CadDocumentIdentity.sessionKey(environmentID: "env", ownerKind: "workspace",
                                               ownerID: owner, rootPath: "/w/one",
                                               relativePath: "plan.dwg")
        let b = CadDocumentIdentity.sessionKey(environmentID: "env", ownerKind: "workspace",
                                               ownerID: owner, rootPath: "/w/two",
                                               relativePath: "plan.dwg")
        #expect(a != b, "two workspace roots must never share a CAD engine session")
    }

    @Test("identity separates environment and owner")
    func distinctOwnersDistinctKeys() {
        let base = CadDocumentIdentity.sessionKey(environmentID: "e1", ownerKind: "chat",
                                                  ownerID: UUID(), rootPath: "/w", relativePath: "a.dxf")
        let otherEnv = CadDocumentIdentity.sessionKey(environmentID: "e2", ownerKind: "chat",
                                                      ownerID: UUID(), rootPath: "/w", relativePath: "a.dxf")
        #expect(base != otherEnv)
    }

    @Test("async mutex serializes overlapping transactions")
    func mutexSerializes() async {
        let mutex = AsyncMutex()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await mutex.withLock {
                        // Non-atomic read-modify-write would lose increments if
                        // the gate did not serialize.
                        let value = await counter.value
                        try? await Task.sleep(for: .microseconds(50))
                        await counter.set(value + 1)
                    }
                }
            }
        }
        #expect(await counter.value == 20)
    }

    @Test("withLock releases after a thrown error")
    func mutexReleasesOnError() async {
        let mutex = AsyncMutex()
        struct Boom: Error {}
        do {
            try await mutex.withLock { throw Boom() }
        } catch {}
        #expect(await mutex.isBusy == false)
        // The lock must be reusable.
        let value = await mutex.withLock { 7 }
        #expect(value == 7)
    }

    private actor Counter {
        private(set) var value = 0
        func set(_ newValue: Int) { value = newValue }
    }

    @Test("a transaction task cancelled while queued never runs and frees the gate")
    func queuedCancellation() async {
        let gate = CadDocumentGate()
        let ran = Counter()
        try? await gate.acquire() // current holder
        let waiter = Task { () -> Bool in
            do {
                try await gate.acquire()
                await ran.set(1)
                await gate.release()
                return true
            } catch {
                return false
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await gate.release() // the cancelled waiter is resumed here
        let executed = await waiter.value
        #expect(executed == false, "a cancelled queued transaction must not execute")
        #expect(await ran.value == 0)
        // The gate was handed on/freed, so a later acquirer still works.
        let next = Task { () -> Bool in
            do {
                try await gate.acquire()
                await gate.release()
                return true
            } catch { return false }
        }
        #expect(await next.value == true)
        #expect(await gate.isBusy == false)
    }

    @Test("gate serializes overlapping acquisitions without loss")
    func gateFairness() async {
        let gate = CadDocumentGate()
        let order = OrderRecorder()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    do {
                        try await gate.acquire()
                        await order.append(index)
                        try? await Task.sleep(for: .microseconds(100))
                        await gate.release()
                    } catch {}
                }
            }
        }
        #expect(await order.values.count == 10)
    }

    private actor OrderRecorder {
        private(set) var values: [Int] = []
        func append(_ value: Int) { values.append(value) }
    }
}

// MARK: - R2 native package naming / capability matrix

@Suite("Native CAD naming and path policy")
struct NativeCADPolicyTests {
    @Test("stem sanitization strips separators and control characters")
    func sanitizesNames() {
        #expect(NativeCADPolicy.sanitizedStem("Bracket") == "Bracket")
        #expect(NativeCADPolicy.sanitizedStem("  Bracket  ") == "Bracket")
        #expect(NativeCADPolicy.sanitizedStem("../escape") == "escape")
        #expect(NativeCADPolicy.sanitizedStem("a/b\\c") == "a b c")
        #expect(NativeCADPolicy.sanitizedStem("plate.floecad") == "plate")
        #expect(NativeCADPolicy.sanitizedStem("plate.floecad.floecad") == "plate")
        #expect(NativeCADPolicy.sanitizedStem("///") == nil)
        #expect(NativeCADPolicy.sanitizedStem("   ") == nil)
        #expect(NativeCADPolicy.sanitizedStem(".hidden") == "hidden")
        let long = String(repeating: "x", count: 200)
        let cleaned = try? #require(NativeCADPolicy.sanitizedStem(long))
        #expect((cleaned?.count ?? 0) <= NativeCADPolicy.maximumStemLength)
    }

    @Test("package paths never traverse and keep the parent directory")
    func packagePaths() {
        #expect(NativeCADPolicy.packageRelativePath(parent: "", stem: "Part") == "Part.floecad")
        #expect(NativeCADPolicy.packageRelativePath(parent: "cad", stem: "Part") == "cad/Part.floecad")
        #expect(NativeCADPolicy.packageRelativePath(parent: "../etc", stem: "x") == "etc/x.floecad")
        #expect(NativeCADPolicy.packageRelativePath(parent: "a/./b", stem: "x") == "a/b/x.floecad")
    }

    @Test("unique-ify never overwrites and stops at the first free name")
    func uniqueNaming() {
        var existing: Set<String> = ["Part.floecad", "Part 2.floecad"]
        let result = NativeCADPolicy.uniquePackagePath(relativePath: "Part.floecad") {
            existing.contains($0)
        }
        #expect(result == "Part 3.floecad")
        existing.insert(result)
        let again = NativeCADPolicy.uniquePackagePath(relativePath: "Part.floecad") {
            existing.contains($0)
        }
        #expect(again == "Part 4.floecad")
        let free = NativeCADPolicy.uniquePackagePath(relativePath: "New.floecad") { _ in false }
        #expect(free == "New.floecad")
    }

    @Test("import format normalization covers aliases and rejects others")
    func importFormats() {
        #expect(NativeCADPolicy.normalizedImportFormat("STEP") == "step")
        #expect(NativeCADPolicy.normalizedImportFormat("stp") == "step")
        #expect(NativeCADPolicy.normalizedImportFormat("IGS") == "iges")
        #expect(NativeCADPolicy.normalizedImportFormat("glb") == "glb")
        #expect(NativeCADPolicy.normalizedImportFormat("gltf") == "gltf")
        #expect(NativeCADPolicy.normalizedImportFormat("dwg") == nil)
        #expect(NativeCADPolicy.normalizedImportFormat("3mf") == nil)
        #expect(NativeCADPolicy.normalizedImportFormat(nil) == nil)
    }
}

// MARK: - Authoritative workbench service operation catalog

@Suite("Workbench service operation catalog")
struct CadServiceOperationCatalogTests {

    /// The exact drawing action vocabulary of the real `CADDrawingService`
    /// router (and the mutate/read split of `CADServiceOperations`). Locked
    /// here; the App-level closure test and the cross-source parity check
    /// re-verify it against the engine.
    private static let drawingActions = ["standardSheet", "addPage", "updatePage", "removePage",
                                         "pages", "project", "dimensions", "export"]
    private static let drawingMutating: Set<String> = ["standardSheet", "addPage", "updatePage", "removePage"]
    private static let assemblyActions = ["addInstance", "addConstraint", "removeInstance",
                                          "setTransform", "setVisible", "removeConstraint",
                                          "suppressConstraint", "solve", "sourceUpdate", "clear",
                                          "report", "instances", "dof", "interference"]
    private static let assemblyMutating: Set<String> = ["addInstance", "addConstraint", "removeInstance",
                                                        "setTransform", "setVisible", "removeConstraint",
                                                        "suppressConstraint", "solve", "sourceUpdate", "clear"]

    @Test("table mirrors the engine routers and separates mutating from read-only")
    func tableIntegrity() throws {
        #expect(CadServiceOperationCatalog.kinds == ["assembly", "drawing", "script", "mesh"])
        var seen = Set<String>()
        for operation in CadServiceOperationCatalog.operations {
            let key = "\(operation.kind).\(operation.action)"
            #expect(seen.insert(key).inserted, "duplicate operation \(key)")
            #expect(operation.op == key)
            #expect(!operation.summary.isEmpty, "\(key) needs a summary")
            #expect(!operation.examples.isEmpty, "\(key) needs a runnable example")
            #expect(operation.proposeExample.contains(operation.op))
            // Examples must be JSON objects so the model can copy them.
            for example in operation.examples {
                let object = try? JSONSerialization.jsonObject(with: Data(example.utf8)) as? [String: Any]
                #expect(object != nil, "\(key) example must be a JSON object: \(example)")
            }
        }
        #expect(CadServiceOperationCatalog.actionNames(forKind: "drawing") == Self.drawingActions)
        #expect(CadServiceOperationCatalog.actionNames(forKind: "assembly") == Self.assemblyActions)
        for action in Self.drawingActions {
            #expect(CadServiceOperationCatalog.isMutating(kind: "drawing", action: action)
                    == Self.drawingMutating.contains(action), "drawing.\(action) mutate classification")
        }
        for action in Self.assemblyActions {
            #expect(CadServiceOperationCatalog.isMutating(kind: "assembly", action: action)
                    == Self.assemblyMutating.contains(action), "assembly.\(action) mutate classification")
        }
        // The two reported model guesses are NOT aliases; they are refused.
        #expect(CadServiceOperationCatalog.normalizedAction(kind: "drawing", raw: "createPage") == nil)
        #expect(CadServiceOperationCatalog.suggestion(for: "drawing.createPage") == "addPage")
    }

    @Test("resolution accepts the canonical action and the documented legacy op forms")
    func resolutionAcceptsDocumentedForms() throws {
        let canonical = try CadServiceOperationCatalog.resolve(
            kind: "drawing", payload: ["action": "addPage", "kind": "front"])
        #expect(canonical.operation.action == "addPage")
        #expect(canonical.operation.mutating)
        #expect(canonical.arguments["kind"] as? String == "front")
        #expect(canonical.arguments["action"] == nil)

        let prefixedOp = try CadServiceOperationCatalog.resolve(
            kind: "drawing", payload: ["op": "drawing.addPage", "kind": "top"])
        #expect(prefixedOp.operation.action == "addPage")

        let bareOp = try CadServiceOperationCatalog.resolve(
            kind: "assembly", payload: ["op": "addInstance", "bodyID": "B"])
        #expect(bareOp.operation.action == "addInstance")

        let prefixedAction = try CadServiceOperationCatalog.resolve(
            kind: "assembly", payload: ["action": "assembly.report"])
        #expect(prefixedAction.operation.action == "report")
        #expect(prefixedAction.operation.mutating == false)

        // A documented legacy alias normalizes explicitly.
        let alias = try CadServiceOperationCatalog.resolve(kind: "drawing",
                                                           payload: ["op": "drawing.sheet"])
        #expect(alias.operation.action == "standardSheet")

        // The propose-shaped envelope flattens `args` into the arguments.
        let nested = try CadServiceOperationCatalog.resolve(
            kind: "drawing", payload: ["op": "drawing.addPage",
                                       "args": ["kind": "iso", "scale": 0.5]])
        #expect(nested.arguments["kind"] as? String == "iso")
        #expect((nested.arguments["scale"] as? NSNumber)?.doubleValue == 0.5)

        // A matching action + op pair is accepted once.
        let both = try CadServiceOperationCatalog.resolve(
            kind: "drawing", payload: ["action": "pages", "op": "drawing.pages"])
        #expect(both.operation.action == "pages")
    }

    @Test("a malformed request is refused — never defaulted to a read")
    func malformedRequestsAreRefused() throws {
        // Missing action: the exact old silent-default case.
        do {
            _ = try CadServiceOperationCatalog.resolve(kind: "drawing", payload: [:])
            Issue.record("an empty payload must not resolve")
        } catch let failure as CadServiceOperationCatalog.ResolutionFailure {
            #expect(failure.code == "missing_action")
            #expect(failure.message.contains("addPage"))
            #expect(failure.message.contains("standardSheet"))
            #expect(failure.message.contains("never defaulted"))
        }
        // The reported model guess.
        do {
            _ = try CadServiceOperationCatalog.resolve(kind: "drawing",
                                                       payload: ["op": "drawing.createPage"])
            Issue.record("an unknown op must not resolve")
        } catch let failure as CadServiceOperationCatalog.ResolutionFailure {
            #expect(failure.code == "unknown_op")
            #expect(failure.message.contains("createPage"))
            #expect(failure.message.contains("Did you mean 'addPage'?"))
        }
        // Unknown action, wrong kind prefix, conflicting selectors, bad types.
        for (kind, payload, code) in [
            ("assembly", ["action": "explode"], "unknown_action"),
            ("drawing", ["op": "assembly.addInstance"], "unknown_op"),
            ("drawing", ["action": "pages", "op": "drawing.addPage"], "conflicting_selector"),
            ("drawing", ["action": 7], "bad_action"),
            ("drawing", ["action": "pages", "args": "nope"], "bad_args"),
            ("drawing", ["action": "pages", "offset": 1, "args": ["offset": 2]], "conflicting_args"),
        ] as [(String, [String: Any], String)] {
            do {
                _ = try CadServiceOperationCatalog.resolve(kind: kind, payload: payload)
                Issue.record("payload \(payload) must be refused")
            } catch let failure as CadServiceOperationCatalog.ResolutionFailure {
                #expect(failure.code == code, "expected \(code) for \(payload), got \(failure.code)")
            }
        }
        // An unknown KIND is refused too.
        do {
            _ = try CadServiceOperationCatalog.resolve(kind: "sketch", payload: ["action": "create"])
            Issue.record("an unknown service kind must be refused")
        } catch let failure as CadServiceOperationCatalog.ResolutionFailure {
            #expect(failure.code == "unknown_kind")
        }
    }

    @Test("capabilities serves a compact summary and a bounded per-kind page")
    func capabilitiesPaging() throws {
        let summary = try CadServiceOperationCatalog.capabilitiesJSON()
        let kinds = try #require(summary["kinds"] as? [String: Any])
        #expect(kinds.count == 4)
        #expect(kinds["drawing"] as? Int == 8, "the compact summary carries counts only")
        #expect(summary["detail"] == nil)
        #expect((summary["detail_hint"] as? String)?.contains("kind=") == true)

        let full = CadServiceOperationCatalog.summaryJSON(compact: false)
        let fullKinds = try #require(full["kinds"] as? [String: Any])
        let drawing = try #require(fullKinds["drawing"] as? [String: Any])
        #expect((drawing["mutating"] as? [String])?.contains("addPage") == true)
        #expect((drawing["read_only"] as? [String])?.contains("pages") == true)

        let page = try CadServiceOperationCatalog.capabilitiesJSON(detailKind: "drawing",
                                                                   offset: 0, limit: 3)
        let detail = try #require(page["detail"] as? [String: Any])
        #expect(detail["total"] as? Int == 8)
        #expect(detail["next_offset"] as? Int == 3)
        let operations = try #require(detail["operations"] as? [[String: Any]])
        #expect(operations.count == 3)
        let first = try #require(operations.first)
        #expect(first["action"] as? String == "standardSheet")
        #expect((first["args"] as? [[String: Any]])?.isEmpty == false)
        #expect((first["examples"] as? [String])?.isEmpty == false)

        let last = try CadServiceOperationCatalog.capabilitiesJSON(detailKind: "drawing",
                                                                   offset: 6, limit: 3)
        let lastDetail = try #require(last["detail"] as? [String: Any])
        #expect(lastDetail["next_offset"] is NSNull)
        #expect((lastDetail["operations"] as? [[String: Any]])?.count == 2)

        do {
            _ = try CadServiceOperationCatalog.capabilitiesJSON(detailKind: "unknown")
            Issue.record("an unknown detail kind must be refused")
        } catch let failure as CadServiceOperationCatalog.ResolutionFailure {
            #expect(failure.code == "unknown_kind")
        }

        // A plain merge keeps a host-provided catalog untouched; a detail
        // merge replaces the (potentially huge) engine reply with the
        // catalog-focused page and stays inside the model-visible budget.
        let merged = CadServiceOperationCatalog.mergingCapabilities(
            into: #"{"ok":true,"service_operations":{"kinds":{"drawing":{}}}}"#,
            detailKind: nil, offset: 0, limit: nil)
        let mergedObject = try #require((try? JSONSerialization.jsonObject(with: Data(merged.utf8))) as? [String: Any])
        let existing = try #require(mergedObject["service_operations"] as? [String: Any])
        #expect(existing["detail_hint"] == nil, "a host-provided catalog must not be overwritten")

        let bigEngineReply = #"{"ok":true,"padding":"\#(String(repeating: "x", count: 3700))"}"#
        let detailReply = CadServiceOperationCatalog.mergingCapabilities(
            into: bigEngineReply, detailKind: "drawing", offset: 0, limit: 8)
        #expect(detailReply.utf8.count <= CadServiceOperationCatalog.modelSummaryBudget)
        let detailObject = try #require((try? JSONSerialization.jsonObject(with: Data(detailReply.utf8))) as? [String: Any])
        let serviceDetail = try #require((detailObject["service_operations"] as? [String: Any])?["detail"] as? [String: Any])
        #expect(serviceDetail["kind"] as? String == "drawing")
        #expect((serviceDetail["operations"] as? [[String: Any]])?.isEmpty == false,
                "the page shrinks to what fits instead of truncating the JSON")
    }
}

@Suite("Native CAD capability matrix")

struct NativeCADCapabilityMatrixTests {
    @Test("creation describes the native package; exchange rows state view/edit/export separately")
    func rowsAreExplicit() throws {
        let floecad = try #require(NativeCADCapabilityMatrix.row(forFormat: "floecad"))
        #expect(floecad.create == true)
        #expect(floecad.import == false)
        #expect(floecad.edit == true)

        let step = try #require(NativeCADCapabilityMatrix.row(forFormat: "stp"))
        #expect(step.format == "step")
        #expect(step.geometryClass == "brep")
        #expect(step.import == true)
        #expect(step.edit == true)

        let iges = try #require(NativeCADCapabilityMatrix.row(forFormat: "iges"))
        #expect(iges.export.contains("step"))
        #expect(!iges.export.contains("iges"), "IGES export is not available in this build")

        for meshFormat in ["stl", "obj", "glb", "gltf"] {
            let row = try #require(NativeCADCapabilityMatrix.row(forFormat: meshFormat))
            #expect(row.geometryClass == "mesh", "\(meshFormat) imports as render meshes")
            #expect(row.edit == false, "\(meshFormat) bodies have no parametric history editing")
            #expect(row.import == true)
            #expect(row.view == true)
        }
    }

    @Test("JSON matrix carries create/import/view/edit/export for every row")
    func jsonShape() throws {
        let rows = NativeCADCapabilityMatrix.json()
        #expect(rows.count >= 6)
        for row in rows {
            for key in ["format", "geometry_class", "create", "import", "view", "edit", "export"] {
                #expect(row[key] != nil, "missing \(key) in \(row)")
            }
        }
    }
}

// MARK: - Unicode document names (Chinese/mixed) and actionable refusals

extension NativeCADPolicyTests {
    @Test("Chinese and mixed names are usable; unsafe names are refused with a bilingual reason")
    func unicodeNamesAndRefusals() {
        // Letters/digits of any language survive sanitization.
        #expect(NativeCADPolicy.sanitizedStem("中文支架") == "中文支架")
        #expect(NativeCADPolicy.sanitizedStem("混合 Mixed 名称") == "混合 Mixed 名称")
        #expect(NativeCADPolicy.sanitizedStem("支架 v2 (左)") == "支架 v2 (左)")
        #expect(NativeCADPolicy.sanitizedStem("Кронштейн-2") == "Кронштейн-2")
        #expect(NativeCADPolicy.sanitizedStem("ブラケット") == "ブラケット")
        #expect(NativeCADPolicy.sanitizedStem("中文 支架") == "中文 支架")

        // …and are accepted by the strict validator (this is what the create
        // flow calls before the factory).
        #expect(NativeCADPolicy.validateName("中文支架") == nil)
        #expect(NativeCADPolicy.validateName("混合 Mixed 名称") == nil)
        #expect(NativeCADPolicy.validateName("  中文支架  ") == nil)

        // Control/invisible characters are refused (not silently mangled).
        let control = NativeCADPolicy.validateName("bad\u{0007}name")
        #expect(control != nil)
        #expect(control?.contains("控制字符") == true)
        #expect(control?.contains("control or invisible") == true)
        #expect(NativeCADPolicy.validateName("two\nlines") != nil)
        #expect(NativeCADPolicy.validateName("zero\u{200D}width") != nil)
        #expect(NativeCADPolicy.validateName("bidi\u{202E}reorder") != nil)

        // Path separators and traversal are refused.
        let separator = NativeCADPolicy.validateName("folder/name")
        #expect(separator != nil)
        #expect(separator?.contains("路径分隔符") == true)
        #expect(NativeCADPolicy.validateName("folder\\name") != nil)
        #expect(NativeCADPolicy.validateName("..") != nil)
        #expect(NativeCADPolicy.validateName(".") != nil)

        // Length is bounded, counted in characters, with the limit stated.
        #expect(NativeCADPolicy.validateName(String(repeating: "长", count: 120)) == nil)
        let tooLong = NativeCADPolicy.validateName(String(repeating: "长", count: 121))
        #expect(tooLong != nil)
        #expect(tooLong?.contains("121") == true)
        #expect(tooLong?.contains("120") == true)

        // Empty and unusable-only names are refused with a usable-character hint.
        #expect(NativeCADPolicy.validateName("   ") != nil)
        let emoji = NativeCADPolicy.validateName("🚀")
        #expect(emoji != nil)
        #expect(emoji?.contains("可用字符") == true)

        // The sanitizer itself never emits a separator, a leading dot or an
        // empty stem for a refused name.
        for raw in ["folder/name", "..", ".hidden", "a\\b"] {
            if let stem = NativeCADPolicy.sanitizedStem(raw) {
                #expect(!stem.contains("/") && !stem.contains("\\"))
                #expect(!stem.hasPrefix("."))
            }
        }
    }
}
