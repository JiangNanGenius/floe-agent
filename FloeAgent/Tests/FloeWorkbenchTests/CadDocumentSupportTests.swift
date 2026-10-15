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
