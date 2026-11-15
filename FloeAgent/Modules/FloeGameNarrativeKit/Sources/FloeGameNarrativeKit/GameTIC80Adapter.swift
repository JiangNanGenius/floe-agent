// SPDX-License-Identifier: MPL-2.0
// The newly authored starter cartridge is additionally MIT-licensed.
import Foundation
import FloeGameCore

/// Real TIC-80 fantasy-console adapter.
///
/// Projects carry a genuine `.tic` cartridge: the upstream chunk container
/// (little-endian 32-bit chunk headers: type:5, bank:3, size:16, temp:8) with
/// `DEFAULT`/`CODE`/`LANG` chunks. Unknown chunks are preserved byte-exact on
/// parse and re-serialize. The Web artifact embeds the pinned upstream TIC-80
/// emscripten player (`tic80.js` + `tic80js.wasm`, MIT) and a real
/// `<canvas id="canvas">`; the player itself preloads and boots `cart.tic`
/// through its own `FS.createPreloadedFile` path (`Module.arguments`).
public enum GameTIC80Adapter {
    public static let version = "1.4.1"
    public static let resourceRevision = "1.4.1-floe-cleared-assets-1"
    public static let jsSHA256 = "71c7afcb770410bb01806f268203839e91578fb81d6ca4b86ca8972de532c02d"
    public static let wasmSHA256 = "9fc28f31dd953eb5350cab5823f4e2dd063516895a0d356d3b5312d6673b8f0c"
    public static let licenseSHA256 = "f78d627327e763b070de95b2da58c5f040343a5290961d7fc88c578ae4c59f33"

    public static let profile = NarrativeEngineProfile(
        engine: .tic80,
        runtimeVersion: version,
        upstream: "https://github.com/nesbox/TIC-80/releases/tag/v1.4.1",
        license: "MIT (top-level TIC-80)",
        licenseBundle: "Original third-party licenses retained, including LGPL-2.1-or-later (blip_buf). Exact corresponding source, all pinned submodules, build and relink scripts and toolchain identity are bundled. Baseline and modified blip_buf were rebuilt and run in WebKit. Uncleared embedded community demos are omitted; original source and historical notices remain available in the companion. This is not Apple approval or a relicensing of project content.",
        licenseBundleRequired: true,
        licenseURL: "https://github.com/nesbox/TIC-80",
        entry: "index.html",
        supportsInput: true,
        supportsChoose: false,
        supportsPointer: true,
        supportsState: false,
        stateContract: "No document-level snapshot API is exposed by the upstream TIC-80 wasm player; the bridge reports state:false and the host implements restart by reloading the artifact. Save data inside a cartridge (its own persistence calls) is not extracted into FloeGame state.",
        requiredCSPAdditions: [],
        requiredMIMETypes: ["wasm": "application/wasm"]
    )

    /// Script identifiers used by TIC-80's `LANG` chunk (src/api/*.c).
    public enum Language: UInt8, Sendable {
        case lua = 10, js = 12, moon = 13, fennel = 14, squirrel = 15, wren = 16
        case wasm = 17, janet = 18, scheme = 19, python = 20, mruby = 11
    }

    // MARK: - Project

    public static func createProject(at target: URL, title: String) throws {
        guard target.isFileURL, NarrativeValidation.validIdentifier(title),
              !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let cart = try starterCart()
        let stage = target.deletingLastPathComponent().appendingPathComponent(".tic80-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let files: [String: Data] = [
            "cart.tic": cart,
            "project.json": try projectJSON(title: title, language: "js"),
            NarrativeInputs.fileName: try NarrativeInputs.encodedDefault(for: .tic80),
            "licenses/LICENSE.tic80.txt": Data(tic80LicenseNotice.utf8),
            "licenses/FLOE-STARTER-MIT.txt": Data(NarrativeLicenses.starterMIT.utf8)
        ]
        for (path, data) in files {
            let output = stage.appendingPathComponent(path)
            try NarrativeWriter.directory(output.deletingLastPathComponent())
            try NarrativeWriter.atomicWrite(data, to: output)
        }
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    /// Imports an original `.tic` cartridge byte-exact, validating the chunk
    /// container first and preserving all unknown chunks.
    public static func importProject(from source: URL, to target: URL, title: String) throws {
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let tree = try NarrativeProjectTree(root: source)
        let entries = try tree.walk()
        guard let cartEntry = entries.first(where: { !$0.directory && $0.path.hasSuffix(".tic") }) else {
            throw NarrativeAdapterError.invalidProject("no .tic cartridge")
        }
        let cartBytes = try tree.read(cartEntry.path)
        let cart = try TICCart.parse(cartBytes)
        guard !cart.codeBytes().isEmpty else { throw NarrativeAdapterError.corruptCart("cartridge has no CODE chunk") }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".tic80-import-" + UUID().uuidString)
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
        try NarrativeWriter.atomicWrite(cartBytes, to: stage.appendingPathComponent("cart.tic"))
        let metadata = try entries.contains(where: { $0.path == "project.json" && !$0.directory })
            ? tree.read("project.json") : projectJSON(title: title, language: cart.languageName)
        let inputs = try entries.contains(where: { $0.path == NarrativeInputs.fileName && !$0.directory })
            ? tree.read(NarrativeInputs.fileName) : NarrativeInputs.encodedDefault(for: .tic80)
        try NarrativeWriter.atomicWrite(metadata,
                                        to: stage.appendingPathComponent("project.json"))
        try NarrativeWriter.atomicWrite(inputs,
                                        to: stage.appendingPathComponent(NarrativeInputs.fileName))
        // Do not apply Floe starter licensing to somebody else's cartridge.
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    // MARK: - Artifact

    public static func buildArtifact(projectAt project: URL, to target: URL, resources: URL,
                                     rebuiltRuntime: GameTIC80RebuiltRuntime? = nil) throws {
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let js = resources.appendingPathComponent("tic80/tic80.js")
        let wasm = resources.appendingPathComponent("tic80/tic80js.wasm")
        let license = resources.appendingPathComponent("tic80/LICENSE.tic80.txt")
        for url in [js, wasm, license] where !FileManager.default.fileExists(atPath: url.path) {
            throw NarrativeAdapterError.missingResource("tic80 resource pack")
        }
        let jsBytes = try Data(contentsOf: js)
        let wasmBytes = try Data(contentsOf: wasm)
        let licenseBytes = try Data(contentsOf: license)
        guard GameDigest.sha256(jsBytes) == (rebuiltRuntime?.jsSHA256 ?? jsSHA256) else { throw NarrativeAdapterError.resourceChanged("tic80/tic80.js") }
        guard GameDigest.sha256(wasmBytes) == (rebuiltRuntime?.wasmSHA256 ?? wasmSHA256),
              wasmBytes.prefix(8) == Data([0, 97, 115, 109, 1, 0, 0, 0]) else {
            throw NarrativeAdapterError.resourceChanged("tic80/tic80js.wasm")
        }
        guard GameDigest.sha256(licenseBytes) == licenseSHA256 else { throw NarrativeAdapterError.resourceChanged("tic80/LICENSE.tic80.txt") }
        let cartBytes = try Data(contentsOf: project.appendingPathComponent("cart.tic"))
        _ = try TICCart.parse(cartBytes) // refuse to package a corrupt cartridge
        let stage = target.deletingLastPathComponent().appendingPathComponent(".tic80-artifact-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }

        var artifact = NarrativeArtifactBuilder(engine: .tic80)
        if let rebuiltRuntime {
            try artifact.add(path: "third-party-source/tic80/REBUILT-SOURCE.zip",
                data: rebuiltRuntime.sourceCompanion, role: .thirdPartySource,
                license: "Original source licenses and MPL-2.0 helper scripts; see companion notices",
                upstream: profile.upstream)
            let identity: [String: String] = ["revision": rebuiltRuntime.revision,
                "jsSHA256": rebuiltRuntime.jsSHA256, "wasmSHA256": rebuiltRuntime.wasmSHA256,
                "sourceSHA256": rebuiltRuntime.sourceSHA256,
                "sourceCompanion": "third-party-source/tic80/REBUILT-SOURCE.zip"]
            try artifact.add(path: "licenses/TIC80-REBUILT-IDENTITY.json",
                data: JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]),
                role: .thirdPartyNotice, license: "Runtime identity; original licenses remain applicable",
                upstream: profile.upstream)
        }
        try artifact.add(path: "index.html", data: Data(try NarrativeSupportAssets.shell("tic80.html").utf8),
                         role: .htmlShell, license: "MPL-2.0")
        for file in ["floe-host.js", "tic80-boot.js", "tic80-bridge.js"] {
            try artifact.add(path: "support/" + file,
                             data: try NarrativeSupportAssets.support(file),
                             role: .floeSupport, license: "MPL-2.0")
        }
        try artifact.add(path: "support/tic80.css", data: try NarrativeSupportAssets.support("tic80.css"),
                         role: .floeStyle, license: "MPL-2.0")
        try artifact.add(path: "tic80.js", data: jsBytes, role: .thirdPartyRuntime,
                         license: "TIC-80: top-level MIT; linked blip_buf LGPL-2.1-or-later and other original licenses; exact source/relink companion included", upstream: profile.upstream)
        try artifact.add(path: "tic80js.wasm", data: wasmBytes, role: .thirdPartyRuntime,
                         license: "TIC-80: top-level MIT; linked blip_buf LGPL-2.1-or-later and other original licenses; exact source/relink companion included", upstream: profile.upstream)
        try artifact.add(path: "licenses/LICENSE.tic80.txt", data: licenseBytes,
                         role: .thirdPartyLicense, license: "MIT", upstream: profile.upstream)
        for notice in try NarrativeLicenseAugmentation.load(for: .tic80, resources: resources,
                                                           upstream: profile.upstream) {
            try artifact.add(path: notice.artifactPath, data: notice.data,
                             role: notice.role, license: notice.license, upstream: notice.upstream)
        }
        try artifact.add(path: "cart.tic", data: cartBytes, role: .cartridge,
                         license: "original project cartridge (not relicensed)")
        for source in try NarrativeSourceBundle.tic80(resources: resources, upstream: profile.upstream) {
            try artifact.add(path: source.artifactPath, data: source.data, role: .thirdPartySource,
                             license: source.license, upstream: source.upstream)
        }
        try artifact.add(path: NarrativeInputs.fileName,
                         data: try NarrativeInputs.artifactFile(project: project, engine: .tic80),
                         role: .inputDeclaration, license: "project input declaration (not relicensed)")
        let originalNotices = try NarrativeOriginalNotices.discover(projectAt: project)
        try NarrativeLicenses.addArtifactNotices(to: &artifact, engine: .tic80, originals: originalNotices)
        try artifact.write(to: stage)
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    // MARK: - Starter cartridge

    static let starterSource = """
    // script: js
    // title: Floe TIC-80 starter
    // author: Floe contributors
    // desc: original MIT starter — dpad moves the marker
    var x = 114, y = 64;

    function TIC() {
      if (btn(2)) x -= 2;
      if (btn(3)) x += 2;
      if (btn(0)) y -= 2;
      if (btn(1)) y += 2;
      x = Math.max(4, Math.min(234, x));
      y = Math.max(14, Math.min(130, y));
      cls(0);
      rectb(0, 0, 240, 136, 12);
      rectb(2, 2, 236, 132, 5);
      rect(x, y, 8, 8, 12);
      print("FLOE TIC-80", 8, 8, 12, false, 1, false);
    }
    """

    /// Builds the original starter `.tic` cartridge with real chunk encoding.
    public static func starterCart() throws -> Data {
        let sourceBytes = Data(starterSource.utf8)
        var cart = TICCart(chunks: [])
        cart.append(TICCart.Chunk(type: TICCart.ChunkType.defaultChunk.rawValue, bank: 0, data: Data()))
        cart.append(TICCart.Chunk(type: TICCart.ChunkType.code.rawValue, bank: 0, data: sourceBytes))
        cart.append(TICCart.Chunk(type: TICCart.ChunkType.language.rawValue, bank: 0, data: Data([Language.js.rawValue])))
        return cart.serialized()
    }

    private static func projectJSON(title: String, language: String) throws -> Data {
        let object: [String: Any] = ["engine": "tic80", "runtime": "tic80 \(version)", "title": title,
                                     "cartridge": "cart.tic", "language": language,
                                     "unknownFieldsExample": ["preserved": true]]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static let tic80LicenseNotice = """
    TIC-80 — MIT License

    Copyright (c) 2017 Vadim Grigoruk @nesbox

    The full upstream license text is distributed with the prepared resource
    pack as tic80/LICENSE.tic80.txt. Source:
    https://github.com/nesbox/TIC-80 (tag v1.4.1). The Floe starter cartridge is
    original content licensed MIT (licenses/FLOE-STARTER-MIT.txt).
    """
}

// MARK: - .tic cartridge container

/// The upstream `.tic` chunk container: 4-byte little-endian chunk headers
/// (type:5 bits, bank:3 bits, size:16 bits, temp:8 bits) followed by payload.
public struct TICCart: Sendable, Equatable {
    public struct Chunk: Sendable, Equatable {
        public let type: UInt8
        public let bank: UInt8
        public var data: Data
        public init(type: UInt8, bank: UInt8, data: Data) { self.type = type; self.bank = bank; self.data = data }
    }

    public enum ChunkType: UInt8, Sendable {
        case dummy = 0, tiles = 1, sprites = 2, cover = 3, map = 4, code = 5, flags = 6
        case samples = 9, waveform = 10, palette = 12, music = 14, patterns = 15
        case zipCode = 16, defaultChunk = 17, screen = 18, binary = 19, language = 20
    }

    public static let bankSize = 65_536
    public var chunks: [Chunk]
    public init(chunks: [Chunk]) { self.chunks = chunks }

    public static func parse(_ data: Data) throws -> TICCart {
        guard data.count >= 4, data.count <= 16 * 1_024 * 1_024 else { throw NarrativeAdapterError.corruptCart("size") }
        var chunks: [Chunk] = []
        var index = 0
        let bytes = [UInt8](data)
        while index + 4 <= bytes.count {
            let raw = UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8)
                | (UInt32(bytes[index + 2]) << 16) | (UInt32(bytes[index + 3]) << 24)
            index += 4
            let type = UInt8(raw & 0x1F)
            let bank = UInt8((raw >> 5) & 0x07)
            let size = Int((raw >> 8) & 0xFFFF)
            let payload: Int
            if size == 0 && (type == ChunkType.code.rawValue || type == ChunkType.binary.rawValue) {
                payload = bankSize
            } else {
                payload = size
            }
            guard index + payload <= bytes.count else { throw NarrativeAdapterError.corruptCart("truncated chunk \(type)") }
            chunks.append(Chunk(type: type, bank: bank, data: Data(bytes[index..<(index + payload)])))
            index += payload
            guard chunks.count <= 4_096 else { throw NarrativeAdapterError.corruptCart("too many chunks") }
        }
        guard index == bytes.count else { throw NarrativeAdapterError.corruptCart("trailing bytes") }
        return TICCart(chunks: chunks)
    }

    public func serialized() -> Data {
        var output: [UInt8] = []
        for chunk in chunks {
            guard chunk.data.count <= Self.bankSize else { continue }
            let size = UInt32(chunk.data.count) & 0xFFFF
            // A full 64K CODE/BINARY chunk is spelled with size 0 upstream.
            let encodedSize = (chunk.data.count == Self.bankSize
                && (chunk.type == ChunkType.code.rawValue || chunk.type == ChunkType.binary.rawValue)) ? 0 : size
            let raw = UInt32(chunk.type) | (UInt32(chunk.bank & 0x07) << 5)
                | (encodedSize << 8)
            output.append(UInt8(raw & 0xFF)); output.append(UInt8((raw >> 8) & 0xFF))
            output.append(UInt8((raw >> 16) & 0xFF)); output.append(UInt8((raw >> 24) & 0xFF))
            output.append(contentsOf: [UInt8](chunk.data))
        }
        return Data(output)
    }

    /// Concatenated CODE chunks in bank order (as the TIC-80 loader assembles them).
    public func codeBytes() -> Data {
        var code = Data(count: 0)
        for bank in 0..<8 {
            for chunk in chunks where chunk.type == ChunkType.code.rawValue && Int(chunk.bank) == bank {
                code.append(chunk.data)
            }
        }
        return code
    }

    public func codeString() -> String? {
        let bytes = codeBytes()
        guard let terminator = bytes.firstIndex(of: 0) else { return String(data: bytes, encoding: .utf8) }
        return String(data: bytes.prefix(upTo: terminator), encoding: .utf8)
    }

    public var language: UInt8? {
        chunks.first(where: { $0.type == ChunkType.language.rawValue })?.data.first
    }

    public var languageName: String {
        switch language {
        case 10: "lua"; case 12: "js"; case 13: "moon"; case 14: "fennel"; case 15: "squirrel"
        case 16: "wren"; case 17: "wasm"; case 18: "janet"; case 19: "scheme"; case 20: "python"
        case 11: "mruby"; default: "unknown"
        }
    }

    public mutating func append(_ chunk: Chunk) { chunks.append(chunk) }
}
