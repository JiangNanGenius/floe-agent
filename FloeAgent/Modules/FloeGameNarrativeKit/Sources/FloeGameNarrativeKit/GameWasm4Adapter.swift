// SPDX-License-Identifier: MPL-2.0
// The newly authored starter cartridge is additionally MIT-licensed.
import Foundation
import FloeGameCore

/// Real WASM-4 fantasy-console adapter.
///
/// Projects carry an actual `.wasm` WASM-4 cartridge (`cart.wasm`). Starter
/// cartridges are produced procedurally by this module's small WASM encoder and
/// implement the documented WASM-4 ABI: they import `env.memory` plus the
/// `env.rect` / `env.text` drawing calls and export `start` + `update`.
/// The Web artifact embeds the pinned upstream `wasm4.js` web runtime (ISC) and
/// the official `<wasm4-app>` player element, which loads `cart.wasm` from the
/// same artifact and runs the cartridge for real (framebuffer + audio path).
public enum GameWasm4Adapter {
    public static let version = "2.7.1"
    public static let runtimeSHA256 = "266557b8523c0d6af73e506e326fbc7fcdf4a45c23420afb553f9ce8f4156c8b"
    public static let styleSHA256 = "98b8f8fccb57578e57361a03df2522eab6457363508a76f3b5cef1520e332aac"
    public static let licenseSHA256 = "57dece2bb0324db24532eba37aa2f9103e2f7f96bfbfea535358bf66ba5a1f1b"

    public static let profile = NarrativeEngineProfile(
        engine: .wasm4,
        runtimeVersion: version,
        upstream: "https://github.com/aduros/wasm4/tree/v2.7.1/runtimes/web",
        license: "ISC (top-level WASM-4)",
        licenseBundle: "Lit 3.1.2 BSD-3-Clause; Press Start 2P OFL-1.1; combined third-party notice",
        licenseBundleRequired: true,
        licenseURL: "https://github.com/aduros/wasm4",
        entry: "index.html",
        supportsInput: true,
        supportsChoose: false,
        supportsPointer: true,
        supportsState: true,
        stateContract: "snapshot() = {memory: base64(64KiB cart memory), globals: exported global values, disk: base64(persistent disk)} captured through the upstream SavedGameState path (FloeGame bridge calls saveGameState then serializes the runtime state object); restore(state) rebuilds that object and calls the upstream loadGameState, which writes memory/globals/disk back into the running cartridge.",
        requiredCSPAdditions: [],
        requiredMIMETypes: ["wasm": "application/wasm"]
    )

    /// The upstream web runtime enforces `1 << 16` bytes for release carts.
    public static let maximumCartBytes = 65_536

    /// WASM-4 framebuffer/palette addresses used by generated starter cartridges.
    static let addressPalette: Int32 = 0x04
    static let addressDrawColors: Int32 = 0x14
    static let addressGamepad1: Int32 = 0x16
    static let dataOffset: Int32 = 0x7000
    static let starterLabel = "FLOE WASM-4 POSTIE"

    // MARK: - Authoring

    public static func createProject(at target: URL, title: String) throws {
        guard target.isFileURL, NarrativeValidation.validIdentifier(title),
              !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let cart = try starterCart()
        let stage = target.deletingLastPathComponent().appendingPathComponent(".wasm4-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let files: [String: Data] = [
            "cart.wasm": cart,
            "project.json": try projectJSON(title: title),
            NarrativeInputs.fileName: try NarrativeInputs.encodedDefault(for: .wasm4),
            "licenses/LICENSE.wasm4.txt": Data(wasm4License.utf8),
            "licenses/FLOE-STARTER-MIT.txt": Data(NarrativeLicenses.starterMIT.utf8)
        ]
        for (path, data) in files {
            let output = stage.appendingPathComponent(path)
            try NarrativeWriter.directory(output.deletingLastPathComponent())
            try NarrativeWriter.atomicWrite(data, to: output)
        }
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    /// Imports an original WASM-4 cartridge (`.wasm`), preserving its bytes
    /// exactly. The cartridge ABI is validated structurally (magic + export
    /// names) before import so a mislabeled file is rejected.
    public static func importProject(from source: URL, to target: URL, title: String) throws {
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let tree = try NarrativeProjectTree(root: source)
        let entries = try tree.walk()
        guard let cartEntry = entries.first(where: { !$0.directory && $0.path.hasSuffix(".wasm") }) else {
            throw NarrativeAdapterError.invalidProject("no .wasm cartridge")
        }
        let cart = try tree.read(cartEntry.path)
        guard cart.count >= 8, cart.count <= maximumCartBytes, cart.prefix(4) == Data([0x00, 0x61, 0x73, 0x6D]) else {
            throw NarrativeAdapterError.invalidProject("not a WebAssembly module or larger than the upstream 64 KiB cart limit")
        }
        let exports = try WasmModuleReader.exports(cart)
        guard exports.contains("start") || exports.contains("update") else {
            throw NarrativeAdapterError.invalidProject("cartridge exports neither start nor update")
        }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".wasm4-import-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        for entry in entries {
            let output = stage.appendingPathComponent("original/" + entry.path)
            if entry.directory {
                try NarrativeWriter.directory(output)
            } else {
                try NarrativeWriter.directory(output.deletingLastPathComponent())
                try NarrativeWriter.atomicWrite(try tree.read(entry.path), to: output)
            }
        }
        try NarrativeWriter.atomicWrite(cart, to: stage.appendingPathComponent("cart.wasm"))
        let metadata = try entries.contains(where: { $0.path == "project.json" && !$0.directory })
            ? tree.read("project.json") : projectJSON(title: title)
        let inputs = try entries.contains(where: { $0.path == NarrativeInputs.fileName && !$0.directory })
            ? tree.read(NarrativeInputs.fileName) : NarrativeInputs.encodedDefault(for: .wasm4)
        try NarrativeWriter.atomicWrite(metadata, to: stage.appendingPathComponent("project.json"))
        try NarrativeWriter.atomicWrite(inputs,
                                        to: stage.appendingPathComponent(NarrativeInputs.fileName))
        // Imported content retains its original licenses. Engine notices are
        // attached when the corresponding runtime is actually packaged.
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    // MARK: - Artifact

    public static func buildArtifact(projectAt project: URL, to target: URL, resources: URL) throws {
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let runtime = resources.appendingPathComponent("wasm4/wasm4.js")
        let style = resources.appendingPathComponent("wasm4/wasm4.css")
        let license = resources.appendingPathComponent("wasm4/LICENSE.wasm4.txt")
        for url in [runtime, style, license] where !FileManager.default.fileExists(atPath: url.path) {
            throw NarrativeAdapterError.missingResource("wasm4 resource pack")
        }
        let runtimeBytes = try Data(contentsOf: runtime)
        let styleBytes = try Data(contentsOf: style)
        let licenseBytes = try Data(contentsOf: license)
        guard GameDigest.sha256(runtimeBytes) == runtimeSHA256 else { throw NarrativeAdapterError.resourceChanged("wasm4/wasm4.js") }
        guard GameDigest.sha256(styleBytes) == styleSHA256 else { throw NarrativeAdapterError.resourceChanged("wasm4/wasm4.css") }
        guard GameDigest.sha256(licenseBytes) == licenseSHA256 else { throw NarrativeAdapterError.resourceChanged("wasm4/LICENSE.wasm4.txt") }
        let cart = try Data(contentsOf: project.appendingPathComponent("cart.wasm"))
        guard cart.count >= 8, cart.count <= maximumCartBytes, cart.prefix(4) == Data([0x00, 0x61, 0x73, 0x6D]) else {
            throw NarrativeAdapterError.invalidProject("invalid or oversized cart.wasm (upstream limit 64 KiB)")
        }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".wasm4-artifact-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }

        var artifact = NarrativeArtifactBuilder(engine: .wasm4)
        try artifact.add(path: "index.html", data: Data(try NarrativeSupportAssets.shell("wasm4.html").utf8),
                         role: .htmlShell, license: "MPL-2.0")
        for file in ["floe-host.js", "wasm4-bridge.js"] {
            try artifact.add(path: "support/" + file,
                             data: try NarrativeSupportAssets.support(file),
                             role: .floeSupport, license: "MPL-2.0")
        }
        try artifact.add(path: "support/wasm4-shell.css",
                         data: try NarrativeSupportAssets.support("wasm4-shell.css"),
                         role: .floeStyle, license: "MPL-2.0")
        try artifact.add(path: "wasm4.js", data: runtimeBytes, role: .thirdPartyRuntime,
                         license: "WASM-4 top-level ISC; selected Lit BSD-3-Clause/font OFL-1.1 bundle terms in licenses/THIRD-PARTY-NOTICES.txt", upstream: profile.upstream)
        try artifact.add(path: "wasm4.css", data: styleBytes, role: .thirdPartyRuntime,
                         license: "WASM-4 top-level ISC; selected font OFL-1.1 bundle terms in licenses/THIRD-PARTY-NOTICES.txt", upstream: profile.upstream)
        try artifact.add(path: "licenses/LICENSE.wasm4.txt", data: licenseBytes,
                         role: .thirdPartyLicense, license: "ISC", upstream: profile.upstream)
        for notice in try NarrativeLicenseAugmentation.load(for: .wasm4, resources: resources,
                                                           upstream: profile.upstream) {
            try artifact.add(path: notice.artifactPath, data: notice.data,
                             role: notice.role, license: notice.license, upstream: notice.upstream)
        }
        try artifact.add(path: "cart.wasm", data: cart, role: .cartridge,
                         license: "original project cartridge (not relicensed)")
        try artifact.add(path: NarrativeInputs.fileName,
                         data: try NarrativeInputs.artifactFile(project: project, engine: .wasm4),
                         role: .inputDeclaration, license: "project input declaration (not relicensed)")
        let originalNotices = try NarrativeOriginalNotices.discover(projectAt: project)
        try NarrativeLicenses.addArtifactNotices(to: &artifact, engine: .wasm4, originals: originalNotices)
        try artifact.write(to: stage)
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    // MARK: - Original starter cartridge

    /// Builds the original Floe starter cartridge as actual WASM-4 bytecode.
    public static func starterCart() throws -> Data {
        var module = WasmModuleBuilder()
        // Types: 0 = (i32,i32,i32,i32)->(), 1 = (i32,i32,i32)->(), 2 = ()->()
        module.addType([0x7F, 0x7F, 0x7F, 0x7F], [])
        module.addType([0x7F, 0x7F, 0x7F], [])
        module.addType([], [])
        // Imports: env.memory, env.rect(type 0), env.text(type 1).
        module.addMemoryImport(module: "env", field: "memory", minimum: 1, maximum: 1)
        module.addFunctionImport(module: "env", field: "rect", type: 0)
        module.addFunctionImport(module: "env", field: "text", type: 1)
        // Defined functions: start (type 2), update (type 2) -> indices 2, 3.
        module.addFunction(type: 2)
        module.addFunction(type: 2)
        // Globals: px, py, frames (mutable i32).
        module.addGlobal(type: 0x7F, mutable: true, initial: 76)
        module.addGlobal(type: 0x7F, mutable: true, initial: 76)
        module.addGlobal(type: 0x7F, mutable: true, initial: 0)
        module.addExport(name: "start", kind: 0x00, index: 2)
        module.addExport(name: "update", kind: 0x00, index: 3)
        // Export the starter's mutable globals so the upstream SavedGameState
        // path captures/restores position deterministically (upstream also
        // patches missing globals, but explicit exports make the contract real).
        module.addExport(name: "px", kind: 0x03, index: 0)
        module.addExport(name: "py", kind: 0x03, index: 1)
        module.addExport(name: "frames", kind: 0x03, index: 2)

        // start: install the starter palette (4 x 0x00RRGGBB at 0x04).
        var start = WasmFunctionBody(locals: [])
        for (offset, color) in [(Int32(0x04), Int32(0x001A2B22)), (0x08, 0x0086C06C), (0x0C, 0x00306850), (0x10, 0x00F6E7B0)] {
            start.i32Const(offset); start.i32Const(color); start.i32Store(align: 2, offset: 0)
        }
        start.end()

        // update: read GAMEPAD1, move a 12x12 dot, draw border + label, count frames.
        var update = WasmFunctionBody(locals: [0x7F, 0x7F, 0x7F]) // g, dx, dy
        // g = load8_u(0x16)
        update.i32Const(addressGamepad1); update.i32Load8(align: 0, offset: 0); update.localSet(0)
        // dx = ((g>>5)&1)*2 - ((g>>4)&1)*2   (right/left)
        update.localGet(0); update.i32Const(5); update.shrS(); update.i32Const(1); update.and(); update.i32Const(2); update.mul()
        update.localGet(0); update.i32Const(4); update.shrS(); update.i32Const(1); update.and(); update.i32Const(2); update.mul()
        update.sub(); update.localSet(1)
        // dy = ((g>>7)&1)*2 - ((g>>6)&1)*2   (down/up)
        update.localGet(0); update.i32Const(7); update.shrS(); update.i32Const(1); update.and(); update.i32Const(2); update.mul()
        update.localGet(0); update.i32Const(6); update.shrS(); update.i32Const(1); update.and(); update.i32Const(2); update.mul()
        update.sub(); update.localSet(2)
        // px += dx, clamp to [2, 150]
        update.globalGet(0); update.localGet(1); update.add(); update.globalSet(0)
        update.globalGet(0); update.i32Const(2); update.ltS()
        update.ifResultI32 { $0.i32Const(2) } else: { $0.globalGet(0) }
        update.globalSet(0)
        update.globalGet(0); update.i32Const(150); update.gtS()
        update.ifResultI32 { $0.i32Const(150) } else: { $0.globalGet(0) }
        update.globalSet(0)
        // py += dy, clamp to [2, 150]
        update.globalGet(1); update.localGet(2); update.add(); update.globalSet(1)
        update.globalGet(1); update.i32Const(2); update.ltS()
        update.ifResultI32 { $0.i32Const(2) } else: { $0.globalGet(1) }
        update.globalSet(1)
        update.globalGet(1); update.i32Const(150); update.gtS()
        update.ifResultI32 { $0.i32Const(150) } else: { $0.globalGet(1) }
        update.globalSet(1)
        // Border in color index 2 (DRAW_COLORS fill nibble = 3).
        update.i32Const(addressDrawColors); update.i32Const(3); update.i32Store(align: 1, offset: 0)
        for rect in [(Int32(0), Int32(0), Int32(160), Int32(2)),
                     (0, 158, 160, 2), (0, 0, 2, 160), (158, 0, 2, 160)] {
            update.i32Const(rect.0); update.i32Const(rect.1); update.i32Const(rect.2); update.i32Const(rect.3)
            update.call(0)
        }
        // Dot in color index 3 (fill nibble = 4).
        update.i32Const(addressDrawColors); update.i32Const(4); update.i32Store(align: 1, offset: 0)
        update.globalGet(0); update.globalGet(1); update.i32Const(12); update.i32Const(12); update.call(0)
        // Label in color index 3 (text ink = high nibble).
        update.i32Const(addressDrawColors); update.i32Const(0x40); update.i32Store(align: 1, offset: 0)
        update.i32Const(dataOffset); update.i32Const(8); update.i32Const(8); update.call(1)
        // frames += 1
        update.globalGet(2); update.i32Const(1); update.add(); update.globalSet(2)
        update.end()

        module.addCode(start)
        module.addCode(update)
        var data = Array(starterLabel.utf8); data.append(0)
        module.addData(offset: dataOffset, bytes: data)
        return module.serialize()
    }

    private static func projectJSON(title: String) throws -> Data {
        let object: [String: Any] = ["engine": "wasm4", "runtime": "wasm4 \(version)", "title": title,
                                     "cartridge": "cart.wasm", "unknownFieldsExample": ["preserved": true]]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static let wasm4License = """
    MIT/ISC License (WASM-4)

    WASM-4 is distributed under the ISC License (runtime) with Apache-2.0/MIT
    tooling; see the prepared resource pack's LICENSE.wasm4.txt for the exact
    upstream text. Source: https://github.com/aduros/wasm4 (v2.7.1).
    The Floe starter cartridge emitted by this adapter is original content
    licensed MIT (licenses/FLOE-STARTER-MIT.txt).
    """
}

// MARK: - Minimal WASM encoder

struct WasmFunctionBody {
    var locals: [UInt8]
    var code: [UInt8] = []

    mutating func op(_ byte: UInt8) { code.append(byte) }
    mutating func i32Const(_ value: Int32) { op(0x41); code += NarrativeBytes.leb128(value) }
    mutating func localGet(_ index: UInt32) { op(0x20); code += NarrativeBytes.leb128(index) }
    mutating func localSet(_ index: UInt32) { op(0x21); code += NarrativeBytes.leb128(index) }
    mutating func globalGet(_ index: UInt32) { op(0x23); code += NarrativeBytes.leb128(index) }
    mutating func globalSet(_ index: UInt32) { op(0x24); code += NarrativeBytes.leb128(index) }
    mutating func call(_ index: UInt32) { op(0x10); code += NarrativeBytes.leb128(index) }
    mutating func i32Load8(align: UInt32, offset: UInt32) { op(0x2D); code += NarrativeBytes.leb128(align); code += NarrativeBytes.leb128(offset) }
    mutating func i32Store(align: UInt32, offset: UInt32) { op(0x36); code += NarrativeBytes.leb128(align); code += NarrativeBytes.leb128(offset) }
    mutating func add() { op(0x6A) }
    mutating func sub() { op(0x6B) }
    mutating func mul() { op(0x6C) }
    mutating func and() { op(0x71) }
    mutating func shl() { op(0x74) }
    mutating func shrS() { op(0x75) }
    mutating func ltS() { op(0x48) }
    mutating func gtS() { op(0x4A) }
    mutating func end() { op(0x0B) }

    /// `if (result i32) ... else ... end` — both branches must leave one i32.
    mutating func ifResultI32(_ then: (inout WasmFunctionBody) -> Void, else elseBody: (inout WasmFunctionBody) -> Void) {
        op(0x04); op(0x7F)
        then(&self)
        op(0x05)
        elseBody(&self)
        end()
    }

    func encoded() -> [UInt8] {
        var localsSection: [UInt8]
        if locals.isEmpty {
            localsSection = [0x00]
        } else {
            // Our bodies only use uniform i32 locals: one group of N i32s.
            precondition(locals.allSatisfy { $0 == 0x7F }, "only i32 locals are supported")
            localsSection = [0x01, UInt8(locals.count), 0x7F]
        }
        return localsSection + code
    }
}

struct WasmModuleBuilder {
    private var types: [[UInt8]] = []
    private var imports: [UInt8] = []
    private var importCount = 0
    private var functions: [UInt8] = []
    private var functionCount = 0
    private var globals: [[UInt8]] = []
    private var exports: [UInt8] = []
    private var exportCount = 0
    private var codes: [[UInt8]] = []
    private var data: [UInt8] = []
    private var dataCount = 0
    private var memoryImported = false

    mutating func addType(_ parameters: [UInt8], _ results: [UInt8]) {
        var entry: [UInt8] = [0x60]
        entry += NarrativeBytes.leb128(UInt32(parameters.count)) + parameters
        entry += NarrativeBytes.leb128(UInt32(results.count)) + results
        types.append(entry)
    }

    private mutating func addImport(module: String, field: String, entry: [UInt8]) {
        imports += NarrativeBytes.leb128(UInt32(module.utf8.count)) + Array(module.utf8)
        imports += NarrativeBytes.leb128(UInt32(field.utf8.count)) + Array(field.utf8)
        imports += entry
        importCount += 1
    }

    mutating func addMemoryImport(module: String, field: String, minimum: UInt32, maximum: UInt32) {
        var entry: [UInt8] = [0x02, 0x01]
        entry += NarrativeBytes.leb128(minimum) + NarrativeBytes.leb128(maximum)
        addImport(module: module, field: field, entry: entry)
        memoryImported = true
    }

    mutating func addFunctionImport(module: String, field: String, type: UInt32) {
        addImport(module: module, field: field, entry: [0x00] + NarrativeBytes.leb128(type))
    }

    mutating func addFunction(type: UInt32) {
        functions += NarrativeBytes.leb128(type)
        functionCount += 1
    }

    mutating func addGlobal(type: UInt8, mutable: Bool, initial: Int32) {
        var entry: [UInt8] = [type, mutable ? 0x01 : 0x00, 0x41]
        entry += NarrativeBytes.leb128(initial)
        entry.append(0x0B)
        globals.append(entry)
    }

    mutating func addExport(name: String, kind: UInt8, index: UInt32) {
        exports += NarrativeBytes.leb128(UInt32(name.utf8.count)) + Array(name.utf8) + [kind] + NarrativeBytes.leb128(index)
        exportCount += 1
    }

    mutating func addCode(_ body: WasmFunctionBody) { codes.append(body.encoded()) }
    mutating func addData(offset: Int32, bytes: [UInt8]) {
        data += [0x00]  // memory index
        data += [0x41] + NarrativeBytes.leb128(offset) + [0x0B]
        data += NarrativeBytes.leb128(UInt32(bytes.count)) + bytes
        dataCount += 1
    }

    func serialize() -> Data {
        var output: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
        func section(_ id: UInt8, _ content: [UInt8]) {
            output.append(id)
            output += NarrativeBytes.leb128(UInt32(content.count))
            output += content
        }
        var typeContent = NarrativeBytes.leb128(UInt32(types.count))
        for type in types { typeContent += type }
        section(1, typeContent)
        if !imports.isEmpty { section(2, NarrativeBytes.leb128(UInt32(importCount)) + imports) }
        // `functions` already stores each type index in order; the vec count prefixes it.
        let functionContent = NarrativeBytes.leb128(UInt32(functionCount)) + functions
        section(3, functionContent)
        if !globals.isEmpty {
            var globalContent = NarrativeBytes.leb128(UInt32(globals.count))
            for entry in globals { globalContent += entry }
            section(6, globalContent)
        }
        if exportCount > 0 { section(7, NarrativeBytes.leb128(UInt32(exportCount)) + exports) }
        var codeContent = NarrativeBytes.leb128(UInt32(codes.count))
        for body in codes {
            codeContent += NarrativeBytes.leb128(UInt32(body.count)) + body
        }
        section(10, codeContent)
        if dataCount > 0 { section(11, NarrativeBytes.leb128(UInt32(dataCount)) + data) }
        return Data(output)
    }
}

/// Structural reader used by import validation and tests.
enum WasmModuleReader {
    static func exports(_ data: Data) throws -> Set<String> {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4] == [0x00, 0x61, 0x73, 0x6D], bytes[4..<8] == [0x01, 0x00, 0x00, 0x00] else {
            throw NarrativeAdapterError.invalidProject("bad wasm header")
        }
        var index = 8
        var result = Set<String>()
        while index < bytes.count {
            let id = bytes[index]; index += 1
            let (size, afterSize) = readUnsigned(bytes, index)
            guard let size, afterSize <= bytes.count, afterSize + Int(size) <= bytes.count else {
                throw NarrativeAdapterError.invalidProject("truncated wasm section")
            }
            let end = afterSize + Int(size)
            if id == 7 {
                var cursor = afterSize
                let (count, next) = readUnsigned(bytes, cursor)
                guard let count else { throw NarrativeAdapterError.invalidProject("bad export count") }
                cursor = next
                for _ in 0..<count {
                    let (nameLength, nameStart) = readUnsigned(bytes, cursor)
                    guard let nameLength, nameStart + Int(nameLength) <= end else { throw NarrativeAdapterError.invalidProject("bad export name") }
                    let name = String(decoding: bytes[nameStart..<(nameStart + Int(nameLength))], as: UTF8.self)
                    cursor = nameStart + Int(nameLength) + 1 // kind byte
                    let (_, afterIndex) = readUnsigned(bytes, cursor)
                    cursor = afterIndex
                    result.insert(name)
                }
            }
            index = end
        }
        return result
    }

    static func readUnsigned(_ bytes: [UInt8], _ start: Int) -> (UInt32?, Int) {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt32(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, index) }
            shift += 7
            if shift > 28 { return (nil, index) }
        }
        return (nil, index)
    }
}
