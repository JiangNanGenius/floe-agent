// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// One file in a generated narrative Web artifact. `role` is the machine-readable
/// statement of what the file is: Floe MPL support source, original game source
/// or data, or an unchanged third-party runtime/notice. The role is written into
/// `floe-artifact.json`; it is not inferred from a filename.
public enum NarrativeArtifactRole: String, Codable, Sendable, CaseIterable {
    /// Floe-authored HTML shell. It references support/data files and contains
    /// no game source text. The Twine shell also carries the upstream SugarCube
    /// page template (BSD-2-Clause), which is marked in its file entry.
    case htmlShell = "html-shell"
    /// Readable Floe-authored JavaScript support source (MPL-2.0).
    case floeSupport = "floe-support-source"
    /// Readable Floe-authored CSS support source (MPL-2.0).
    case floeStyle = "floe-support-style"
    /// Original game source file (ink/microScript file, Twine story model).
    case gameSource = "original-game-source"
    /// Original game data compiled/derived for the engine (source maps, resource
    /// metadata). It is user content, never relicensed as Floe support.
    case gameData = "original-game-data"
    /// Original game asset bytes (sprites, maps, audio, assets).
    case gameAsset = "original-game-asset"
    /// Original cartridge bytes (.wasm/.tic).
    case cartridge = "original-game-cartridge"
    /// Unchanged third-party runtime or its extracted source bytes.
    case thirdPartyRuntime = "third-party-runtime"
    /// Exact selected third-party source archive/pin bytes carried in the
    /// artifact. This is not a full license clearance or relink proof.
    case thirdPartySource = "third-party-source"
    /// Combined third-party notice, not a single license text.
    case thirdPartyNotice = "third-party-notice"
    /// Source/relink information. The role does not create a written offer
    /// or establish that its remaining conditions have been fulfilled.
    case thirdPartySourceOffer = "third-party-source-offer"
    /// Individual third-party license text.
    case thirdPartyLicense = "third-party-license"
    /// Full MPL license text.
    case floeLicense = "floe-license"
    /// Generated Floe notice describing this artifact's file boundary.
    case floeNotice = "floe-notice"
    /// The additional MIT notice for Floe-authored starter content.
    case starterLicense = "floe-starter-license"
    /// Original project license/NOTICE/COPYING bytes, preserved unchanged.
    case originalNotice = "original-notice"
    /// `floe-inputs.json`, a host input declaration. It is never a command,
    /// evaluator or permission source.
    case inputDeclaration = "host-input-declaration"
}

struct NarrativeArtifactEntry: Sendable {
    let path: String
    let data: Data
    let role: NarrativeArtifactRole
    let license: String
    let upstream: String?
}

/// Deterministic, collision-checked artifact assembly. Every file is added with
/// an explicit role and license; `finish()` adds a total file manifest with
/// path, role, license, size and SHA-256. The manifest never includes itself.
struct NarrativeArtifactBuilder {
    let engine: GameEngineID
    let entry: String
    private var entries: [String: NarrativeArtifactEntry] = [:]

    init(engine: GameEngineID, entry: String = "index.html") {
        self.engine = engine
        self.entry = entry
    }

    var floeSupportFiles: [String] { paths(for: [.floeSupport, .floeStyle]) }
    var originalGameFiles: [String] { paths(for: [.gameSource, .gameData, .gameAsset, .cartridge]) }
    var thirdPartyRuntimeFiles: [String] { paths(for: [.thirdPartyRuntime]) }
    var thirdPartySourceFiles: [String] { paths(for: [.thirdPartySource]) }
    var licenseFiles: [String] {
        paths(for: [.thirdPartyLicense, .thirdPartyNotice, .thirdPartySourceOffer,
                    .floeLicense, .floeNotice, .starterLicense, .originalNotice])
    }

    mutating func add(path: String, data: Data, role: NarrativeArtifactRole, license: String,
                      upstream: String? = nil) throws {
        let clean = try Self.validated(path)
        guard entries[clean] == nil else {
            throw NarrativeAdapterError.invalidProject("artifact path collision: " + clean)
        }
        entries[clean] = .init(path: clean, data: data, role: role, license: license, upstream: upstream)
    }

    mutating func add(_ files: [NarrativeLicenseFile]) throws {
        for file in files {
            try add(path: file.artifactPath, data: file.data, role: file.role, license: file.license,
                    upstream: file.upstream)
        }
    }

    /// All artifact files plus the deterministic manifest.
    func finish() throws -> [String: Data] {
        guard entries[entry] != nil else {
            throw NarrativeAdapterError.invalidProject("artifact entry missing: " + entry)
        }
        guard entries["floe-artifact.json"] == nil else {
            throw NarrativeAdapterError.invalidProject("reserved artifact path: floe-artifact.json")
        }
        var files: [String: Data] = [:]
        var manifestFiles: [[String: Any]] = []
        for path in entries.keys.sorted(by: Self.utf8Less) {
            let entry = entries[path]!
            files[path] = entry.data
            var object: [String: Any] = [
                "path": path,
                "role": entry.role.rawValue,
                "license": entry.license,
                "bytes": entry.data.count,
                "sha256": GameDigest.sha256(entry.data)
            ]
            if let upstream = entry.upstream { object["upstream"] = upstream }
            manifestFiles.append(object)
        }
        let manifest: [String: Any] = [
            "format": "floe-narrative-artifact",
            "version": 1,
            "engine": engine.rawValue,
            "entry": entry,
            "floeLicense": "MPL-2.0",
            "supportSource": "support/ (readable source form included in this artifact)",
            "files": manifestFiles,
            "fileCount": manifestFiles.count,
            "floeSupportFiles": floeSupportFiles,
            "originalGameFiles": originalGameFiles,
            "thirdPartyRuntimeFiles": thirdPartyRuntimeFiles,
            "thirdPartySourceFiles": thirdPartySourceFiles,
            "licenseFiles": licenseFiles,
            "sourceAvailability": engine == .twine
                ? "Floe support Source Code Form: the exact readable files under support/ are bundled in this artifact. index.html includes the upstream BSD-licensed SugarCube template and readable Floe substitutions under MPL-2.0. This artifact does not assert a public URL or a complete SDK source handoff; that SDK/source distribution is separate. Original game content is listed under originalGameFiles and retains its own license."
                : "Floe support Source Code Form: the exact readable files under support/ plus the Floe HTML shell index.html are bundled in this artifact. This artifact does not assert a public URL or a complete SDK source handoff; that SDK/source distribution is separate. Original game content is listed under originalGameFiles and retains its own license."
        ]
        files["floe-artifact.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        return files
    }

    func write(to stage: URL) throws {
        let files = try finish()
        for path in files.keys.sorted(by: Self.utf8Less) {
            let output = stage.appendingPathComponent(path)
            try NarrativeWriter.directory(output.deletingLastPathComponent())
            try NarrativeWriter.atomicWrite(files[path]!, to: output)
        }
    }

    private func paths(for roles: [NarrativeArtifactRole]) -> [String] {
        entries.values.filter { roles.contains($0.role) }.map(\.path).sorted(by: Self.utf8Less)
    }

    func entries(for roles: [NarrativeArtifactRole]) -> [NarrativeArtifactEntry] {
        entries.values.filter { roles.contains($0.role) }
            .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    private static func validated(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NarrativeAdapterError.invalidProject("unsafe artifact path: " + path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NarrativeAdapterError.invalidProject("unsafe artifact path: " + path)
        }
        return path
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

/// Support files are stored as real readable package resources rather than
/// minified inline strings. They are copied byte-exact into artifacts.
enum NarrativeSupportAssets {
    static func data(_ name: String, subdirectory: String) throws -> Data {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let candidates: [String?] = [subdirectory, "Resources/" + subdirectory, nil]
        for candidate in candidates {
            if let url = Bundle.module.url(forResource: base, withExtension: ext.isEmpty ? nil : ext,
                                           subdirectory: candidate) {
                return try Data(contentsOf: url)
            }
        }
        throw NarrativeAdapterError.missingResource("package resource \(subdirectory)/\(name)")
    }

    static func support(_ name: String) throws -> Data { try data(name, subdirectory: "Support") }

    static func shell(_ name: String) throws -> String {
        String(decoding: try data(name, subdirectory: "Shells"), as: UTF8.self)
    }
}

/// Exact selected third-party source bytes carried with a conditional artifact.
struct NarrativeSourceFile: Sendable {
    let artifactPath: String
    let data: Data
    let license: String
    let upstream: String?
}

/// Carries the exact rebuilt runtime's complete corresponding source and build
/// receipt, plus unchanged selected-source records from the earlier resource
/// review. Historical records do not replace the mandatory complete companion.
enum NarrativeSourceBundle {
    private struct Item {
        let name: String
        let sha256: String
        let bytes: Int
        let license: String
    }

    private static let tic80Items = [
        Item(name: "TIC80-EXACT-CORRESPONDING-SOURCE.zip",
             sha256: "5717a89efbb1604e0bbc903154827efe973e306cec7b9ed7882e0b3e3548d08e",
             bytes: 37_410_174,
             license: "Exact corresponding source, pinned submodules, build/relink helpers and original licenses"),
        Item(name: "CURRENT-BUILD-AND-RELINK.json",
             sha256: "34d17969bc251feec9ff944c1f637fa8982dd4eaf0ff41ef1fae1ca6a19749cb",
             bytes: 949, license: "Exact runtime/source identity and observed rebuild/relink evidence"),
        Item(name: "TIC-80-b3dbd59-source.tar.gz",
             sha256: "d5d95c1e591602ce9574d363fadaab60cc5433e368c07a1745a288040c21e569",
             bytes: 2_923_598,
             license: "TIC-80 selected source bundle; selected transitive terms apply; see SOURCE-OFFER.md (not full LGPL clearance)"),
        Item(name: "TIC-80-b3dbd59-source.tar.gz.sha256",
             sha256: "bb5e75b26e902b8661599b596b99ac01f7531b3c3b37ea8b1857569b254e3267",
             bytes: 95, license: "SHA-256 sidecar"),
        Item(name: "blip-buf-330226d-source.tar.gz",
             sha256: "e86870ecb4b7c3feac6afbf5ddd0aff809e14b2d16d9bde251b712fd4ecd6d99",
             bytes: 51_181,
             license: "LGPL-2.1-or-later selected blip_buf source; relink/clearance not proven"),
        Item(name: "blip-buf-330226d-source.tar.gz.sha256",
             sha256: "3465e4e865ba05ce08b3f421c48c8b88aba5d01bf4b07ae6a91a29abaa4d860e",
             bytes: 97, license: "SHA-256 sidecar"),
        Item(name: "TIC80-SUBMODULE-PINS.json",
             sha256: "65ba3e857571f0f1738300bb1c04e06120bdd8d769070f9c36d046ae90e4edab",
             bytes: 2_983,
             license: "submodule pin record; submodule contents not bundled or verified"),
        Item(name: "SOURCE-OFFER.md",
             sha256: "066b181f1cca08ec5b85adaf064438fc281bbe58e0f8934c6d0e4f395f461d78",
             bytes: 3_225,
             license: "source offer record as bundled; conditional, not a full clearance")
    ]

    private static let maximumFileBytes = 48 * 1_024 * 1_024
    private static let maximumTotalBytes = 56 * 1_024 * 1_024

    /// Loads and verifies the exact TIC-80 selected source bundle. Missing or
    /// changed bytes fail the artifact build.
    static func tic80(resources: URL, upstream: String) throws -> [NarrativeSourceFile] {
        let root = resources.appendingPathComponent("tic80/source")
        let tree: NarrativeBuildTree
        do { tree = try NarrativeBuildTree(root: root) }
        catch { throw NarrativeAdapterError.missingResource("tic80 selected source bundle") }
        let entries = try tree.walk()
        var result: [NarrativeSourceFile] = []
        var total = 0
        for item in tic80Items.sorted(by: { $0.name < $1.name }) {
            guard let entry = entries.first(where: {
                !$0.directory && $0.regular && !$0.symlink && $0.path == item.name
            }) else {
                throw NarrativeAdapterError.missingResource("tic80/source/" + item.name)
            }
            guard entry.bytes <= maximumFileBytes else {
                throw NarrativeAdapterError.invalidProject("source bundle file too large: " + item.name)
            }
            total += entry.bytes
            guard total <= maximumTotalBytes else {
                throw NarrativeAdapterError.invalidProject("source bundle exceeds bounds")
            }
            let data = try tree.read(item.name, maximum: maximumFileBytes)
            guard data.count == item.bytes, GameDigest.sha256(data) == item.sha256 else {
                throw NarrativeAdapterError.resourceChanged("tic80/source/" + item.name)
            }
            result.append(.init(artifactPath: "source/tic80/" + item.name, data: data,
                                license: item.license, upstream: upstream))
        }
        return result
    }
}

/// One third-party notice/license file selected for an artifact. It comes from
/// the prepared resource pack; its bytes are never rewritten.
struct NarrativeLicenseFile: Sendable {
    let resourcePath: String
    let artifactPath: String
    let data: Data
    let role: NarrativeArtifactRole
    let license: String
    let upstream: String?
}

/// Ready-to-attach transitive notice bundle loader.
///
/// Selected engines ship more than their top-level license. The license/profile
/// owner prepares `resources/<engine>/THIRD-PARTY-NOTICES.*` and
/// `resources/<engine>/LICENSES|licenses/*`. This loader copies exactly those
/// bytes into `licenses/` and verifies them against an optional adjacent
/// `NOTICE-PATCH.json`. It fails closed when a conditional engine's bundle is
/// missing, so an artifact can never silently claim to carry notices it does
/// not have. NarrativeSourceBundle separately carries the selected exact
/// source archives. The accompanying source/relink record is informational;
/// it is not an assertion that conditional LGPL relink work is complete.
enum NarrativeLicenseAugmentation {
    private struct Spec {
        let resourceRoot: String
        let requiredTopLevel: [String]
        let licenseDirectories: [String]
        let sourceOffer: (resource: String, artifact: String)?
    }

    /// Frozen SHA-256 receipt for every selected notice/offer byte copied into
    /// a conditional artifact. The prepared pack may also carry NOTICE-PATCH.json;
    /// either way, bytes outside this receipt are refused rather than silently
    /// attached.
    private static let frozenHashes: [String: String] = [
        "sugarcube/THIRD-PARTY-NOTICES.txt": "ccfc10de3c1ea3c1fa7c49473b1ef79d51f251febde5e763b86f5a4be9e81a1c",
        "sugarcube/licenses/FileSaver-MIT.txt": "2d1d7a93b46e4274355ac2904428707c4ee47ee8c6029fa394ebf405648d3f63",
        "sugarcube/licenses/classList-Unlicense.txt": "ca2abdf695884c77ea4b4a5b64ca7b732d9d9dbade4eebc1c2e76c53e9e3bc83",
        "sugarcube/licenses/es5-shim-4.5.14-LICENSE.txt": "68f7e459f79180b490520f06eddb1715650d5f1af5583ff3f8447e795b2a6a2f",
        "sugarcube/licenses/es6-shim-0.35.4-LICENSE.txt": "ac03daa0b0495dcff2c6c6541a2b5808c32ea14ddf8804709dcfdb3f7a46543e",
        "sugarcube/licenses/ev-emitter-1.1.0-MIT.txt": "67d7aeb3eec70dfb944c9de5bacd4b14997ff584a500544475b943779332c2c3",
        "sugarcube/licenses/imagesLoaded-4.1.4-MIT.txt": "19f5e29a01e16cfd404b3bf8ca2c2f338c5abb7b215efc9ddd898a6d1e74e71d",
        "sugarcube/licenses/jquery-3.7.1-LICENSE.txt": "d4db9ebe6f29f5168eac45ad713f055623ac5d0dcd5ba92da23d650ae012020d",
        "sugarcube/licenses/jquery-throttle-debounce-1.1-LICENSE.txt": "1c53a0aa7fd459dab0d144cdc89a13686597ddbcf106fb9dee81435d3d8631be",
        "sugarcube/licenses/lz-string-1.5.0-LICENSE.txt": "433fc9dfe659dbfb1e91eed8351f13651e97bfa3ac6d03394c3d63f61d4bbc80",
        "sugarcube/licenses/normalize.css-3.0.3-LICENSE.txt": "8781bc9996713938f6baea8a10c8426f9ae06778e562fafe5353669ae6c05f07",
        "sugarcube/licenses/seedrandom-3.0.5-MIT.txt": "d83e5c9638599ddc8a5e685332d08630db89bfc96ab0967f890295897151757b",
        "tic80/LICENSES/0BSD.txt": "e3f18c71e10d673590eb9856c1d79dd3b4b0d65404efb5e8584dbede7edd608b",
        "tic80/LICENSES/BSD-3-Clause.txt": "5a93d5831e1297ab10fe643e1a631e83be392896da14ee2951285a79012df69d",
        "tic80/LICENSES/GPL-3.0-or-later.txt": "fb981668c18a279e285fc4d83fba1e836cc84dd4daa73c9697d3cfd2d8aca6e0",
        "tic80/LICENSES/Gravity-MIT.txt": "640152b59af917876ef4728ddb7f8824e42b6fbab8ee6fd5ba59cfd8c1e21e74",
        "tic80/LICENSES/LGPL-2.1-or-later-blip_buf.txt": "319daefe38ebeead3df178e5937898a52d67c0c795f54f1c0bb10ac3b9cffb63",
        "tic80/LICENSES/LGPL-2.1-or-later.txt": "5749785c8bdefafcb5d798270ed0a967036fe2ca63dcedade1627565dfef81d2",
        "tic80/LICENSES/LicenseRef-Public-Domain.txt": "407aad5685ffaa4f6fd27b89cde6606629bf081da5bc156841ed22dae998544a",
        "tic80/LICENSES/MIT.txt": "b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5",
        "tic80/LICENSES/MiniScript2-MIT.txt": "9ead32bdfceaaf8a62992d936e529bee491f1fab1dc28bf9a35383acb2843e70",
        "tic80/LICENSES/Unlicense.txt": "0bdebfeda07d45dada625ae1317c6f833186e798b171d0db640bcf32e92a8240",
        "tic80/LICENSES/Zlib.txt": "bfb1112d49db5b1daecdfef24bd7e2f3ea0bafb33aa67aa0ab51e2bf8407c03d",
        "tic80/LICENSES/libpng-2.0.txt": "f207d0f7375b977f76ce2437962c1c12a646f15cda3df48d5472ac95eb68e8ff",
        "tic80/LICENSES/miniaudio-MIT-0-or-Unlicense.txt": "bd3d6cac4cc7cedde4d51c00a8e157ecdc675b6b98d201945c66fc62728e7e9d",
        "tic80/THIRD-PARTY-NOTICES.md": "ce637ceabf8794820a9a328189cea9cb3310e4179c490b2bb8babd7628edf567",
        "tic80/source/SOURCE-OFFER.md": "066b181f1cca08ec5b85adaf064438fc281bbe58e0f8934c6d0e4f395f461d78",
        "wasm4/LIT-3.1.2-BSD-3-Clause.txt": "45d31799d0db956cc3eb5469346abbd9b7025babc5ff29fab10d7095da992ef1",
        "wasm4/PRESS-START-2P-OFL-1.1.txt": "1ce424c20a36bc74b3001ed50f34c0e2d91a6d8ba941f2dacc7587d6c36a1ae7",
        "wasm4/THIRD-PARTY-NOTICES.txt": "0dc82dd67d5a6e704ad06d9c3b9dc8e15a3f84e5739992f054740b8b40ba86b5",
    ]

    private static let maximumFiles = 96
    private static let maximumFileBytes = 512 * 1_024
    private static let maximumTotalBytes = 4 * 1_024 * 1_024

    private static func spec(for engine: GameEngineID) -> Spec? {
        switch engine {
        case .tic80:
            return Spec(resourceRoot: "tic80",
                        requiredTopLevel: ["THIRD-PARTY-NOTICES.md"],
                        licenseDirectories: ["LICENSES"],
                        sourceOffer: ("BLIP-BUF-SOURCE-OFFER.md", "licenses/BLIP-BUF-SOURCE-OFFER.md"))
        case .wasm4:
            return Spec(resourceRoot: "wasm4",
                        requiredTopLevel: ["THIRD-PARTY-NOTICES.txt",
                                           "LIT-3.1.2-BSD-3-Clause.txt",
                                           "PRESS-START-2P-OFL-1.1.txt"],
                        licenseDirectories: [],
                        sourceOffer: nil)
        case .twine:
            return Spec(resourceRoot: "sugarcube",
                        requiredTopLevel: ["THIRD-PARTY-NOTICES.txt"],
                        licenseDirectories: ["licenses"],
                        sourceOffer: nil)
        default:
            return nil
        }
    }

    static func required(for engine: GameEngineID) -> Bool { spec(for: engine) != nil }

    static func load(for engine: GameEngineID, resources: URL, upstream: String) throws -> [NarrativeLicenseFile] {
        guard let spec = spec(for: engine) else { return [] }
        let root = resources.appendingPathComponent(spec.resourceRoot)
        let tree: NarrativeBuildTree
        do { tree = try NarrativeBuildTree(root: root) }
        catch { throw NarrativeAdapterError.missingResource("\(spec.resourceRoot) notice bundle") }
        let entries = try tree.walk()
        let patch = try loadPatch(resources: resources, spec: spec)
        var expected: [String: (sha256: String, bytes: Int, artifact: String, role: NarrativeArtifactRole)] = [:]
        if let patch {
            let topLevelLicenses: Set<String> = ["LICENSE.tic80.txt", "LICENSE.wasm4.txt",
                                                  "LICENSE.sugarcube.txt"]
            for file in patch.addFiles {
                // The adapter already copies/hash-verifies the top-level engine
                // license; the augmentation patch mentions it for completeness.
                if topLevelLicenses.contains(file.to) { continue }
                expected[file.from] = (file.sha256, file.bytes, "licenses/" + file.to, .thirdPartyLicense)
            }
            if let offer = patch.sourceOffer {
                expected[offer.from] = (offer.sha256, offer.bytes, offer.artifactPath, .thirdPartySourceOffer)
            }
        }
        var result: [NarrativeLicenseFile] = []
        var total = 0

        func include(_ relative: String, artifact: String, role: NarrativeArtifactRole) throws {
            guard result.count < maximumFiles else {
                throw NarrativeAdapterError.invalidProject("too many third-party notices")
            }
            let entry = entries.first { !$0.directory && $0.regular && !$0.symlink && $0.path == relative }
            guard let entry else {
                throw NarrativeAdapterError.missingResource("\(spec.resourceRoot)/\(relative)")
            }
            guard entry.bytes <= maximumFileBytes else {
                throw NarrativeAdapterError.invalidProject("notice too large: " + relative)
            }
            total += entry.bytes
            guard total <= maximumTotalBytes else {
                throw NarrativeAdapterError.invalidProject("third-party notices exceed bounds")
            }
            let data = try tree.read(relative, maximum: maximumFileBytes)
            let key = spec.resourceRoot + "/" + relative
            let digest = GameDigest.sha256(data)
            if let frozen = frozenHashes[key] {
                guard digest == frozen else {
                    throw NarrativeAdapterError.resourceChanged(key)
                }
            } else if expected[relative] == nil {
                throw NarrativeAdapterError.invalidProject("unexpected notice file: " + key)
            }
            if let expectation = expected[relative] {
                guard data.count == expectation.bytes, digest == expectation.sha256 else {
                    throw NarrativeAdapterError.resourceChanged(key)
                }
                guard expectation.artifact == artifact else {
                    throw NarrativeAdapterError.invalidProject("notice patch path mismatch: " + relative)
                }
            }
            result.append(.init(resourcePath: "\(spec.resourceRoot)/\(relative)",
                                artifactPath: artifact, data: data, role: role,
                                license: licenseLabel(for: artifact), upstream: upstream))
            expected.removeValue(forKey: relative)
        }

        if let patch {
            let topLevelLicenses: Set<String> = ["LICENSE.tic80.txt", "LICENSE.wasm4.txt",
                                                  "LICENSE.sugarcube.txt"]
            for file in patch.addFiles.sorted(by: { $0.to < $1.to }) where !topLevelLicenses.contains(file.to) {
                try include(file.from, artifact: "licenses/" + file.to, role: .thirdPartyLicense)
            }
            if let offer = patch.sourceOffer {
                try include(offer.from, artifact: offer.artifactPath, role: .thirdPartySourceOffer)
            }
        } else {
            for name in spec.requiredTopLevel {
                try include(name, artifact: "licenses/" + name, role: .thirdPartyLicense)
            }
            for directory in spec.licenseDirectories {
                let prefix = directory + "/"
                for entry in entries where !entry.directory && entry.regular && !entry.symlink
                    && entry.path.hasPrefix(prefix) && !entry.path.dropFirst(prefix.count).contains("/") {
                    try include(entry.path, artifact: "licenses/" + entry.path, role: .thirdPartyLicense)
                }
            }
            if let offer = spec.sourceOffer {
                if entries.contains(where: { !$0.directory && $0.regular && !$0.symlink && $0.path == offer.resource }) {
                    try include(offer.resource, artifact: offer.artifact, role: .thirdPartySourceOffer)
                } else if entries.contains(where: { !$0.directory && $0.regular && !$0.symlink && $0.path == "source/SOURCE-OFFER.md" }) {
                    try include("source/SOURCE-OFFER.md", artifact: offer.artifact, role: .thirdPartySourceOffer)
                } else {
                    throw NarrativeAdapterError.missingResource("\(spec.resourceRoot)/\(offer.resource)")
                }
            }
        }
        guard expected.isEmpty else {
            throw NarrativeAdapterError.missingResource("third-party notice patch file: "
                                                          + (expected.keys.sorted().first ?? "unknown"))
        }
        return result.sorted { $0.artifactPath.utf8.lexicographicallyPrecedes($1.artifactPath.utf8) }
    }

    private struct PatchFile { let from: String; let to: String; let sha256: String; let bytes: Int }
    private struct PatchOffer { let from: String; let artifactPath: String; let sha256: String; let bytes: Int }
    private struct Patch { let addFiles: [PatchFile]; let sourceOffer: PatchOffer? }

    private static func loadPatch(resources: URL, spec: Spec) throws -> Patch? {
        let candidates = [
            resources.appendingPathComponent(spec.resourceRoot).appendingPathComponent("NOTICE-PATCH.json"),
            resources.appendingPathComponent("NOTICE-PATCH-" + spec.resourceRoot + ".json")
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        let data: Data
        do { data = try NarrativeBoundedFile.read(url, maximum: 512 * 1_024) ?? Data() }
        catch { throw NarrativeAdapterError.invalidProject("unreadable notice patch") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawFiles = object["addFiles"] as? [[String: Any]] else {
            throw NarrativeAdapterError.invalidProject("invalid notice patch")
        }
        var files: [PatchFile] = []
        for raw in rawFiles {
            guard let from = raw["from"] as? String, let to = raw["to"] as? String,
                  let sha = raw["sha256"] as? String, let bytes = raw["bytes"] as? NSNumber,
                  (raw["mode"] as? String) == "copy", bytes.intValue >= 0 else {
                throw NarrativeAdapterError.invalidProject("invalid notice patch file entry")
            }
            files.append(.init(from: from, to: to, sha256: sha, bytes: bytes.intValue))
        }
        var offer: PatchOffer?
        if let raw = object["sourceOffer"] as? [String: Any] {
            guard let from = raw["from"] as? String, let artifactPath = raw["artifactPath"] as? String,
                  let sha = raw["sha256"] as? String, let bytes = raw["bytes"] as? NSNumber,
                  bytes.intValue >= 0 else {
                throw NarrativeAdapterError.invalidProject("invalid notice patch source offer")
            }
            offer = .init(from: from, artifactPath: artifactPath, sha256: sha, bytes: bytes.intValue)
        }
        return Patch(addFiles: files, sourceOffer: offer)
    }

    private static func licenseLabel(for artifactPath: String) -> String {
        let name = artifactPath.lowercased()
        if name.contains("third-party-notices") { return "multiple selected third-party licenses (see notice)" }
        if name.contains("source-offer") { return "source/relink record with remaining conditions (see file)" }
        if name.contains("lgpl") { return "LGPL-2.1-or-later" }
        if name.contains("gpl-3") { return "GPL-3.0-or-later" }
        if name.contains("bsd-3") || name.contains("lit-") { return "BSD-3-Clause" }
        if name.contains("ofl") || name.contains("press-start") { return "OFL-1.1" }
        if name.contains("0bsd") { return "0BSD" }
        if name.contains("zlib") { return "Zlib" }
        if name.contains("libpng") { return "libpng-2.0" }
        if name.contains("miniaudio") { return "miniaudio MIT-0 or Unlicense" }
        if name.contains("miniscript") { return "MiniScript2 MIT" }
        if name.contains("gravity") { return "Gravity MIT" }
        if name.contains("unlicense") || name.contains("public-domain") { return "Unlicense / Public Domain" }
        if name.contains("apache") { return "Apache-2.0" }
        if name.contains("mit") || name.contains("jquery") || name.contains("filesaver")
            || name.contains("ev-emitter") || name.contains("imagesloaded")
            || name.contains("seedrandom") || name.contains("throttle")
            || name.contains("es5-shim") || name.contains("es6-shim")
            || name.contains("normalize") || name.contains("lz-string") { return "MIT" }
        return "see license file"
    }
}
