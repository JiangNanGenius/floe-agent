// SPDX-License-Identifier: MPL-2.0
// The newly authored embedded starter story is additionally MIT-licensed;
// generated projects carry the full notice.
import Foundation
import FloeGameCore

/// Real ink/inkjs authoring + runtime adapter.
///
/// Projects are plain-text `.ink` stories (original ink syntax, importable from
/// any standard ink project). The Web artifact embeds the pinned inkjs 2.4.0
/// full distribution (engine + compiler), compiles the story with the real
/// `inkjs.Compiler` inside WebKit, plays it through `inkjs.Story`, and exposes
/// the typed FloeGame bridge backed by `story.state.toJson()/LoadJson()`.
public enum GameInkAdapter {
    public static let version = "2.4.0"
    public static let engineSHA256 = "23d707b76e9b759a25803c193da8e32e04f727dd13a54ed1df8a6a59dd909b9e"
    public static let licenseSHA256 = "040e957a77e3e19432e265cb549d5c3b4ca6f3551e24d22b81785ffd1bc2b67b"

    public static let profile = NarrativeEngineProfile(
        engine: .ink,
        runtimeVersion: version,
        upstream: "https://www.npmjs.com/package/inkjs/v/2.4.0",
        license: "MIT",
        licenseBundle: nil,
        licenseBundleRequired: false,
        licenseURL: "https://www.npmjs.com/package/inkjs",
        entry: "index.html",
        supportsInput: true,
        supportsChoose: true,
        supportsPointer: true,
        supportsState: true,
        stateContract: "snapshot() = {story: <inkjs Story.state.toJson()>, text, choices}; restore(state) replays LoadJson and re-renders. Variables ride inside the ink save-state JSON.",
        requiredCSPAdditions: [],
        requiredMIMETypes: [:]
    )

    // MARK: - Authoring

    /// Creates an original ink starter project (procedural/original text content).
    public static func createProject(at target: URL, title: String) throws {
        guard target.isFileURL, NarrativeValidation.validIdentifier(title),
              !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".ink-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let files: [String: Data] = [
            "story.ink": Data(starterStory.utf8),
            "project.json": try projectJSON(title: title, starter: true),
            NarrativeInputs.fileName: try NarrativeInputs.encodedDefault(for: .ink),
            "licenses/INKJS-MIT.txt": Data(inkLicenseNotice.utf8),
            "licenses/FLOE-STARTER-MIT.txt": Data(starterLicense.utf8)
        ]
        for (path, data) in files {
            let output = stage.appendingPathComponent(path)
            try NarrativeWriter.directory(output.deletingLastPathComponent())
            try NarrativeWriter.atomicWrite(data, to: output)
        }
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    /// Imports an original standard ink project folder byte-exact (full import),
    /// preserving unknown files and adding a component `project.json` when absent.
    public static func importProject(from source: URL, to target: URL, title: String) throws {
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let reader = try NarrativeProjectTree(root: source)
        let entries = try reader.walk()
        guard entries.contains(where: { !$0.directory && $0.path.hasSuffix(".ink") }) else {
            throw NarrativeAdapterError.invalidProject("no .ink source file")
        }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".ink-import-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        for entry in entries {
            let output = stage.appendingPathComponent(entry.path)
            if entry.directory {
                try NarrativeWriter.directory(output)
            } else {
                try NarrativeWriter.directory(output.deletingLastPathComponent())
                try NarrativeWriter.atomicWrite(try reader.read(entry.path), to: output)
            }
        }
        if !entries.contains(where: { $0.path == "project.json" }) {
            try NarrativeWriter.atomicWrite(try projectJSON(title: title, starter: false),
                                            to: stage.appendingPathComponent("project.json"))
        }
        if !entries.contains(where: { $0.path == NarrativeInputs.fileName }) {
            try NarrativeWriter.atomicWrite(try NarrativeInputs.encodedDefault(for: .ink),
                                            to: stage.appendingPathComponent(NarrativeInputs.fileName))
        }
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    // MARK: - Artifact

    /// Builds a self-contained Web artifact with the pinned inkjs runtime.
    ///
    /// The whole standard INCLUDE graph (entry + nested relative includes) is
    /// read once at build time into a bounded source map. The artifact compiles
    /// that map inside WebKit with the real `inkjs.Compiler` and its
    /// `fileHandler`; the compiler never touches the host filesystem or the
    /// network. `resources` is the prepared narrative resource pack (see
    /// Scripts/prepare_narrative.py).
    public static func buildArtifact(projectAt project: URL, to target: URL, resources: URL) throws {
        try buildArtifact(projectAt: project, to: target, resources: resources, entry: nil)
    }

    /// Explicit-entry variant for projects with more than one possible root.
    /// `entry` is a project-relative `.ink` path; nil uses the deterministic
    /// default (`story.ink`, then `main.ink`, then a single unambiguous file).
    public static func buildArtifact(projectAt project: URL, to target: URL, resources: URL,
                                     entry: String?) throws {
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let engine = resources.appendingPathComponent("inkjs/inkjs.js")
        let license = resources.appendingPathComponent("inkjs/LICENSE.inkjs.txt")
        guard FileManager.default.fileExists(atPath: engine.path),
              FileManager.default.fileExists(atPath: license.path) else {
            throw NarrativeAdapterError.missingResource("inkjs resource pack")
        }
        let engineBytes = try Data(contentsOf: engine)
        let licenseBytes = try Data(contentsOf: license)
        guard GameDigest.sha256(engineBytes) == engineSHA256 else { throw NarrativeAdapterError.resourceChanged("inkjs/inkjs.js") }
        guard GameDigest.sha256(licenseBytes) == licenseSHA256 else { throw NarrativeAdapterError.resourceChanged("inkjs/LICENSE.inkjs.txt") }

        let graph = try InkSourceGraph.prepare(projectAt: project, entry: entry)
        let sourceDocument = try sourceDocumentJSON(graph)

        let stage = target.deletingLastPathComponent().appendingPathComponent(".ink-artifact-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }

        var artifact = NarrativeArtifactBuilder(engine: .ink)
        try artifact.add(path: "index.html", data: Data(try NarrativeSupportAssets.shell("ink.html").utf8),
                         role: .htmlShell, license: "MPL-2.0")
        for file in ["floe-host.js", "ink-bridge.js"] {
            try artifact.add(path: "support/" + file,
                             data: try NarrativeSupportAssets.support(file),
                             role: .floeSupport, license: "MPL-2.0")
        }
        try artifact.add(path: "support/ink.css", data: try NarrativeSupportAssets.support("ink.css"),
                         role: .floeStyle, license: "MPL-2.0")
        try artifact.add(path: "vendor/inkjs.js", data: engineBytes, role: .thirdPartyRuntime,
                         license: "MIT", upstream: profile.upstream)
        try artifact.add(path: "licenses/INKJS-MIT.txt", data: licenseBytes,
                         role: .thirdPartyLicense, license: "MIT", upstream: profile.upstream)

        // Original game source stays byte-exact in its own files. story.ink is
        // the historical entry alias used by existing packaging; game/source/
        // preserves every source path in the compiled INCLUDE graph.
        let tree = try NarrativeBuildTree(root: project)
        let entryBytes = try tree.read(graph.entry, maximum: 1 * 1_024 * 1_024)
        try artifact.add(path: "story.ink", data: entryBytes, role: .gameSource,
                         license: "original project content (not relicensed)")
        try artifact.add(path: "game/ink-sources.json", data: Data(sourceDocument.utf8),
                         role: .gameData, license: "original project content (not relicensed)")
        for path in graph.order {
            let bytes = try tree.read(path, maximum: 1 * 1_024 * 1_024)
            try artifact.add(path: "game/source/" + path, data: bytes, role: .gameSource,
                             license: "original project content (not relicensed)")
        }
        try artifact.add(path: NarrativeInputs.fileName,
                         data: try NarrativeInputs.artifactFile(project: project, engine: .ink),
                         role: .inputDeclaration, license: "project input declaration (not relicensed)")
        // Imported game license/NOTICE/COPYING files ride with the carried story
        // under licenses/original/; engine and bridge notices stay untouched.
        let originalNotices = try NarrativeOriginalNotices.discover(projectAt: project)
        try NarrativeLicenses.addArtifactNotices(to: &artifact, engine: .ink, originals: originalNotices)
        try artifact.write(to: stage)
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    /// Deterministic JSON source map written to game/ink-sources.json. All
    /// INCLUDE paths are already canonical project-relative paths.
    static func sourceDocumentJSON(_ graph: InkSourceGraph) throws -> String {
        let object: [String: Any] = [
            "format": "floe-ink-sources",
            "version": 1,
            "entry": graph.entry,
            "files": graph.sources
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Content

    private static func projectJSON(title: String, starter: Bool) throws -> Data {
        var object: [String: Any] = [
            "engine": "ink", "inkVersion": 21, "runtime": "inkjs \(version)",
            "engineLicense": "MIT", "title": title,
            "unknownFieldsExample": ["preserved": true]
        ]
        // Describe engine metadata only; a blanket license is never assigned to
        // imported user source. `template` marks only Floe-generated starters.
        if starter {
            object["template"] = NarrativeStarter.templateMarker
            object["starterLicense"] = "MIT"
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Original starter content (MIT, see licenses/FLOE-STARTER-MIT.txt)

    static let starterStory = """
    // 森林邮差 · The Forest Postie — original Floe starter (MIT).
    // Demonstrates passages, choices, variables and an ending; see README.
    VAR letters = 3
    VAR delivered = false

    -> forest_path

    === forest_path ===
    松林间的晨雾还没散。你的邮包里装着 {letters} 封没有地址的信。
    + [沿着溪流走] -> stream
    + [穿过老橡树林] -> oak_grove
    + [数一数邮包] -> count_bag

    === count_bag ===
    ~ letters = letters + 1
    你数了数信封：{letters} 封。总会有人认得收件人的。
    + [继续上路] -> forest_path

    === stream ===
    溪水把月光揉碎了。一只苍鹭歪着头看你。
    + [把信给苍鹭看] -> heron
    + [退回林间] -> forest_path

    === heron ===
    ~ delivered = true
    苍鹭叼起最旧的那封信，飞向山那边。信送到了。
    -> END

    === oak_grove ===
    老橡树的洞里飘出炊烟。有人在家。
    + [敲敲门] -> door
    + [离开] -> forest_path

    === door ===
    门开了一条缝。“这信是给我的吗？”
    ~ delivered = true
    ~ letters = 0
    你交出了所有信。
    -> END
    """

    static let inkLicenseNotice = """
    inkjs — MIT License

    Copyright (c) 2017 inkle Ltd.
    Copyright (c) 2017 inkjs contributors (see AUTHORS)

    The full upstream license text is distributed with the prepared resource
    pack as inkjs/LICENSE.inkjs.txt and is copied into every generated project.
    Source: https://www.npmjs.com/package/inkjs/v/2.4.0
    """

    static let starterLicense = NarrativeLicenses.starterMIT
}
