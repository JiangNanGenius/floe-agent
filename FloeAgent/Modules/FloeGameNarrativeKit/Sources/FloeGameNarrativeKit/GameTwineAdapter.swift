// SPDX-License-Identifier: MPL-2.0
// The newly authored embedded starter story is additionally MIT-licensed;
// generated projects carry the full notice.
import Foundation
import FloeGameCore

/// Real Twine 2 / SugarCube 2.37.3 adapter.
///
/// Projects keep the complete Twine story model as JSON (`story.twine.json`):
/// every passage (pid, name, tags, position, size, text) plus the original
/// `tw-storydata` attributes. Import parses a real Twine 2 HTML export; unknown
/// attributes and passages are preserved verbatim and re-emitted. The Web
/// artifact embeds the upstream SugarCube `format.js` (BSD-2-Clause), a genuine
/// `<tw-storydata>` document, and a typed bridge over `SugarCube.State` /
/// `SugarCube.Engine.play()`.
public enum GameTwineAdapter {
    public static let version = "2.37.3"
    static let formatName = "SugarCube"
    public static let formatSHA256 = "64ccdac806a162d250273aba3c39aee85765fedab4cf70e6176154a8c34b8820"
    public static let licenseSHA256 = "bb227ad97f6422347e1e64ad9211d40215e92edf47940c1382973c2a27eb8b27"

    public static let profile = NarrativeEngineProfile(
        engine: .twine,
        runtimeVersion: version,
        upstream: "https://github.com/tmedwards/sugarcube-2/releases/tag/v2.37.3",
        license: "BSD-2-Clause (top-level SugarCube)",
        licenseBundle: "jQuery 3.7.1, jQuery throttle/debounce, es5-shim, es6-shim, imagesLoaded, EvEmitter, seedrandom, normalize.css, lz-string, FileSaver.js and classList.js notices (MIT/Unlicense)",
        licenseBundleRequired: true,
        licenseURL: "https://github.com/tmedwards/sugarcube-2",
        entry: "index.html",
        supportsInput: false,
        supportsChoose: true,
        supportsPointer: true,
        supportsState: true,
        stateContract: "snapshot() = {passage, variables (SugarCube.State.variables), turns}; restore(state) rewrites State.variables in place and calls SugarCube.Engine.play(passage). Full history/temp variables are not part of the contract.",
        requiredCSPAdditions: [],
        requiredMIMETypes: [:]
    )

    // MARK: - Model

    public struct Story: Sendable {
        public var title: String
        public var format: String
        public var formatVersion: String
        public var startPID: String
        public var ifid: String
        /// Preserved `tw-storydata` attributes we do not interpret.
        public var storyAttributes: [String: String]
        public var passages: [Passage]
    }

    public struct Passage: Sendable {
        public var pid: String
        public var name: String
        public var tags: String
        public var position: String
        public var size: String
        public var text: String
        /// Preserved `tw-passagedata` attributes we do not interpret.
        public var attributes: [String: String]
    }

    // MARK: - Authoring

    public static func createProject(at target: URL, title: String) throws {
        guard target.isFileURL, NarrativeValidation.validIdentifier(title),
              !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let story = starterStory(title: title)
        let stage = target.deletingLastPathComponent().appendingPathComponent(".twine-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let files: [String: Data] = [
            "story.twine.json": try encode(story),
            "project.json": try projectJSON(title: title),
            NarrativeInputs.fileName: try NarrativeInputs.encodedDefault(for: .twine),
            "licenses/LICENSE.sugarcube.txt": try licenseNoticeData(),
            "licenses/FLOE-STARTER-MIT.txt": Data(NarrativeLicenses.starterMIT.utf8)
        ]
        for (path, data) in files {
            let output = stage.appendingPathComponent(path)
            try NarrativeWriter.directory(output.deletingLastPathComponent())
            try NarrativeWriter.atomicWrite(data, to: output)
        }
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    /// Full import of a standard Twine 2 HTML export (or a previously exported
    /// `story.twine.json`). Unknown attributes are preserved verbatim.
    public static func importProject(from source: URL, to target: URL, title: String) throws {
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let tree = try NarrativeProjectTree(root: source)
        let entries = try tree.walk()
        let story: Story
        if let json = entries.first(where: { $0.path == "story.twine.json" }) {
            story = try decode(try tree.read(json.path))
        } else if let html = entries.first(where: { !$0.directory && ($0.path.hasSuffix(".html") || $0.path.hasSuffix(".htm")) }) {
            story = try StoryParser.parse(html: String(decoding: try tree.read(html.path), as: UTF8.self))
        } else {
            throw NarrativeAdapterError.invalidProject("no Twine HTML or story.twine.json")
        }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".twine-import-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        // Preserve every original file byte-exact, then add the canonical model.
        for entry in entries {
            let output = stage.appendingPathComponent("original/" + entry.path)
            if entry.directory {
                try NarrativeWriter.directory(output)
            } else {
                try NarrativeWriter.directory(output.deletingLastPathComponent())
                try NarrativeWriter.atomicWrite(try tree.read(entry.path), to: output)
            }
        }
        try NarrativeWriter.atomicWrite(try encode(story), to: stage.appendingPathComponent("story.twine.json"))
        let metadata = try entries.contains(where: { $0.path == "project.json" && !$0.directory })
            ? tree.read("project.json") : projectJSON(title: title)
        let inputs = try entries.contains(where: { $0.path == NarrativeInputs.fileName && !$0.directory })
            ? tree.read(NarrativeInputs.fileName) : NarrativeInputs.encodedDefault(for: .twine)
        try NarrativeWriter.atomicWrite(metadata, to: stage.appendingPathComponent("project.json"))
        try NarrativeWriter.atomicWrite(inputs,
                                            to: stage.appendingPathComponent(NarrativeInputs.fileName))
        // Preserve original notices under original/ without assigning this
        // imported story the license of the separately authored Floe starter.
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    // MARK: - Artifact

    public static func buildArtifact(projectAt project: URL, to target: URL, resources: URL) throws {
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NarrativeAdapterError.destinationExists }
        let format = resources.appendingPathComponent("sugarcube/sugarcube-format.js")
        let license = resources.appendingPathComponent("sugarcube/LICENSE.sugarcube.txt")
        guard FileManager.default.fileExists(atPath: format.path), FileManager.default.fileExists(atPath: license.path) else {
            throw NarrativeAdapterError.missingResource("sugarcube resource pack")
        }
        let formatBytes = try Data(contentsOf: format)
        let licenseBytes = try Data(contentsOf: license)
        guard GameDigest.sha256(formatBytes) == formatSHA256 else { throw NarrativeAdapterError.resourceChanged("sugarcube/sugarcube-format.js") }
        guard GameDigest.sha256(licenseBytes) == licenseSHA256 else { throw NarrativeAdapterError.resourceChanged("sugarcube/LICENSE.sugarcube.txt") }
        let formatSource = try publishedSource(from: formatBytes)
        let storyData = try Data(contentsOf: project.appendingPathComponent("story.twine.json"))
        let story = try decode(storyData)
        guard story.startPID.utf8.count <= 64, !story.passages.isEmpty, story.passages.count <= 2_048 else {
            throw NarrativeAdapterError.invalidProject("invalid story model")
        }
        let page = try publishShell(formatSource: formatSource, story: story)
        let stage = target.deletingLastPathComponent().appendingPathComponent(".twine-artifact-" + UUID().uuidString)
        try NarrativeWriter.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }

        var artifact = NarrativeArtifactBuilder(engine: .twine)
        try artifact.add(path: "index.html", data: Data(page.utf8), role: .htmlShell,
                         license: "BSD-2-Clause upstream SugarCube page template; Floe substitutions under MPL-2.0")
        for file in ["floe-host.js", "twine-bootstrap.js", "twine-bridge.js"] {
            try artifact.add(path: "support/" + file,
                             data: try NarrativeSupportAssets.support(file),
                             role: .floeSupport, license: "MPL-2.0")
        }
        // Upstream SugarCube runtime pieces extracted byte-exact from the
        // pinned published-page source. The format package itself is retained
        // unchanged for source inspection; none of these are Floe files.
        let scriptBodies = try extractScriptElements(from: formatSource)
        // Twine publishes the format by substituting {{STORY_NAME}} in the
        // engine's own generated-name fallback too. Preserve that one documented
        // token substitution; every other engine byte is unchanged.
        let publishedEngine = String(decoding: scriptBodies.engine, as: UTF8.self)
            .replacingOccurrences(of: "{{STORY_NAME}}", with: HTML.escapeText(story.title))
        try artifact.add(path: "vendor/sugarcube-libraries.js", data: scriptBodies.libraries,
                         role: .thirdPartyRuntime, license: "BSD-2-Clause / MIT / Unlicense bundled components (see licenses/THIRD-PARTY-NOTICES.txt)", upstream: profile.upstream)
        try artifact.add(path: "vendor/sugarcube-engine.js", data: Data(publishedEngine.utf8),
                         role: .thirdPartyRuntime, license: "BSD-2-Clause", upstream: profile.upstream)
        try artifact.add(path: "vendor/sugarcube-format.js", data: formatBytes,
                         role: .thirdPartyRuntime, license: "BSD-2-Clause / MIT / Unlicense bundled components (see licenses/THIRD-PARTY-NOTICES.txt)", upstream: profile.upstream)
        try artifact.add(path: "licenses/LICENSE.sugarcube.txt", data: licenseBytes,
                         role: .thirdPartyLicense, license: "BSD-2-Clause", upstream: profile.upstream)
        for notice in try NarrativeLicenseAugmentation.load(for: .twine, resources: resources,
                                                           upstream: profile.upstream) {
            try artifact.add(path: notice.artifactPath, data: notice.data,
                             role: notice.role, license: notice.license, upstream: notice.upstream)
        }
        try artifact.add(path: "game/story.twine.json", data: storyData, role: .gameData,
                         license: "original project content (not relicensed)")
        try artifact.add(path: NarrativeInputs.fileName,
                         data: try NarrativeInputs.artifactFile(project: project, engine: .twine),
                         role: .inputDeclaration, license: "project input declaration (not relicensed)")
        let originalNotices = try NarrativeOriginalNotices.discover(projectAt: project)
        try NarrativeLicenses.addArtifactNotices(to: &artifact, engine: .twine, originals: originalNotices)
        try artifact.write(to: stage)
        try NarrativeWriter.publish(stage: stage, to: target)
    }

    /// The genuine Twine 2 `<tw-storydata>` element, including preserved
    /// unknown attributes on the story and each passage.
    public static func storyDataElement(for story: Story) -> String {
        var attributes = story.storyAttributes
        attributes["name"] = story.title
        attributes["startnode"] = story.startPID
        attributes["format"] = attributes["format"] ?? story.format
        attributes["format-version"] = attributes["format-version"] ?? story.formatVersion
        attributes["ifid"] = story.ifid
        attributes["creator"] = attributes["creator"] ?? "Floe"
        attributes["creator-version"] = attributes["creator-version"] ?? "1.0"
        let attributeText = attributes.keys.sorted().map { key in
            "\(key)=\"\(HTML.escapeAttribute(attributes[key] ?? ""))\""
        }.joined(separator: " ")
        let passages = story.passages.map { passage -> String in
            var values = passage.attributes
            values["pid"] = passage.pid
            values["name"] = passage.name
            values["tags"] = passage.tags
            values["position"] = passage.position
            values["size"] = passage.size
            let text = values.keys.sorted().map { key in "\(key)=\"\(HTML.escapeAttribute(values[key] ?? ""))\"" }.joined(separator: " ")
            return "<tw-passagedata \(text)>\(HTML.escapeText(passage.text))</tw-passagedata>"
        }.joined(separator: "\n")
        return "<tw-storydata \(attributeText)>\n\(passages)\n</tw-storydata>"
    }

    /// Publishes the unchanged upstream SugarCube page template with the story
    /// data and Floe bridge externalized. `{{STORY_DATA}}` becomes a mount point
    /// plus the bootstrap script; the two upstream inline script bodies are
    /// extracted byte-exact into separate runtime files. An empty
    /// `script#script-sugarcube` placeholder remains because the upstream engine
    /// inserts its UI relative to that element.
    public static func publishShell(formatSource: String, story: Story) throws -> String {
        let scripts = try extractScriptElements(from: formatSource)
        struct Replacement { let range: Range<String.Index>; let text: String }
        var replacements: [Replacement] = []
        var searchStart = formatSource.startIndex
        func tokenRange(_ token: String) throws -> Range<String.Index> {
            guard let range = formatSource.range(of: token, range: searchStart..<formatSource.endIndex) else {
                throw NarrativeAdapterError.invalidProject("story format token missing: " + token)
            }
            searchStart = range.upperBound
            return range
        }
        replacements.append(.init(range: try tokenRange("{{STORY_NAME}}"),
                                  text: HTML.escapeText(story.title)))
        replacements.append(.init(range: try tokenRange("{{STORY_DATA}}"),
                                  text: "<div id=\"floe-story-mount\"></div>\n" +
                                        "<script src=\"support/floe-host.js\"></script>\n" +
                                        "<script src=\"support/twine-bootstrap.js\"></script>"))
        replacements.append(.init(range: scripts.librariesRange,
                                  text: "<script id=\"script-libraries\" type=\"text/javascript\" " +
                                        "src=\"vendor/sugarcube-libraries.js\"></script>"))
        replacements.append(.init(range: scripts.engineRange,
                                  text: "<script id=\"script-sugarcube\" type=\"text/javascript\" " +
                                        "data-floe-source=\"vendor/sugarcube-engine.js\"></script>"))
        var page = formatSource
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            page.replaceSubrange(replacement.range, with: replacement.text)
        }
        guard !page.contains("{{STORY_NAME}}"), !page.contains("{{STORY_DATA}}") else {
            throw NarrativeAdapterError.invalidProject("story format tokens remain")
        }
        return page
    }

    struct ExtractedScripts {
        let libraries: Data
        let engine: Data
        let librariesRange: Range<String.Index>
        let engineRange: Range<String.Index>
    }

    /// Extracts the two genuine inline script bodies without rewriting them.
    static func extractScriptElements(from source: String) throws -> ExtractedScripts {
        func element(id: String) throws -> (body: Data, range: Range<String.Index>) {
            guard let open = source.range(of: "<script id=\"\(id)\"") else {
                throw NarrativeAdapterError.invalidProject("story format script missing: " + id)
            }
            guard let openEnd = source.range(of: ">", range: open.upperBound..<source.endIndex),
                  let close = source.range(of: "</script>", range: openEnd.upperBound..<source.endIndex) else {
                throw NarrativeAdapterError.invalidProject("unterminated story format script: " + id)
            }
            return (Data(source[openEnd.upperBound..<close.lowerBound].utf8),
                    open.lowerBound..<close.upperBound)
        }
        let libraries = try element(id: "script-libraries")
        let engine = try element(id: "script-sugarcube")
        guard !libraries.body.isEmpty, engine.body.count > 1_024 else {
            throw NarrativeAdapterError.invalidProject("empty story format script body")
        }
        return .init(libraries: libraries.body, engine: engine.body,
                     librariesRange: libraries.range, engineRange: engine.range)
    }

    /// Reads the story-format package (`window.storyFormat({...})`) and returns
    /// its full runtime HTML source. The package object is valid JSON.
    static func publishedSource(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8),
              let prefix = text.range(of: "window.storyFormat(") else {
            throw NarrativeAdapterError.invalidProject("not a Twine story format package")
        }
        let contentStart = prefix.upperBound
        guard let braceStart = text.range(of: "{", range: contentStart..<text.endIndex) else {
            throw NarrativeAdapterError.invalidProject("story format object missing")
        }
        var depth = 0
        var inString = false
        var escaped = false
        var endIndex: String.Index?
        var index = braceStart.lowerBound
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { endIndex = index; break }
            }
            index = text.index(after: index)
        }
        guard let endIndex else { throw NarrativeAdapterError.invalidProject("unterminated story format object") }
        let json = Data(text[braceStart.lowerBound...endIndex].utf8)
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              object["name"] as? String == formatName,
              object["version"] as? String == version,
              object["license"] as? String == "BSD-2-Clause",
              let source = object["source"] as? String,
              source.contains("{{STORY_DATA}}") else {
            throw NarrativeAdapterError.invalidProject("unexpected SugarCube format metadata")
        }
        return source
    }

    /// Typed FloeGame bridge for the published SugarCube page. It uses the real
    /// save-state marshal/unmarshal path (the same objects save files persist)
    /// and renders a restored passage once with `Engine.show()`.
    // MARK: - Encoding

    static func encode(_ story: Story) throws -> Data {
        var object: [String: Any] = [
            "format": story.format, "formatVersion": story.formatVersion,
            "start": story.startPID, "ifid": story.ifid, "title": story.title,
            "storyAttributes": story.storyAttributes,
            "passages": story.passages.map { passage -> [String: Any] in
                ["pid": passage.pid, "name": passage.name, "tags": passage.tags,
                 "position": passage.position, "size": passage.size,
                 "text": passage.text, "attributes": passage.attributes]
            }
        ]
        // Preserve any future top-level values shipping with the model.
        object["model"] = "floe-twine-1"
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) throws -> Story {
        guard data.count <= 16 * 1_024 * 1_024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let passagesRaw = object["passages"] as? [[String: Any]],
              let start = object["start"] as? String, !start.isEmpty else {
            throw NarrativeAdapterError.invalidProject("invalid story.twine.json")
        }
        let passages = try passagesRaw.map { raw -> Passage in
            guard let pid = raw["pid"] as? String, let name = raw["name"] as? String,
                  let text = raw["text"] as? String, !pid.isEmpty, !name.isEmpty else {
                throw NarrativeAdapterError.invalidProject("invalid passage entry")
            }
            return Passage(pid: pid, name: name,
                           tags: raw["tags"] as? String ?? "",
                           position: raw["position"] as? String ?? "100,100",
                           size: raw["size"] as? String ?? "100,100",
                           text: text,
                           attributes: raw["attributes"] as? [String: String] ?? [:])
        }
        guard passages.contains(where: { $0.pid == start }) else {
            throw NarrativeAdapterError.invalidProject("start passage pid missing")
        }
        return Story(title: object["title"] as? String ?? "Twine story",
                     format: object["format"] as? String ?? "SugarCube",
                     formatVersion: object["formatVersion"] as? String ?? version,
                     startPID: start,
                     ifid: object["ifid"] as? String ?? UUID().uuidString,
                     storyAttributes: object["storyAttributes"] as? [String: String] ?? [:],
                     passages: passages)
    }

    private static func projectJSON(title: String) throws -> Data {
        let object: [String: Any] = ["engine": "twine", "format": "SugarCube", "formatVersion": version,
                                     "title": title, "unknownFieldsExample": ["preserved": true]]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func licenseNoticeData() throws -> Data {
        Data(sugarcubeLicense.utf8)
    }

    /// Upstream SugarCube 2.37.3 license text (BSD-2-Clause), embedded verbatim so
    /// project creation is self-contained; the prepared resource pack remains the
    /// byte-verified authority for artifacts.
    static let sugarcubeLicense = """
    Copyright (c) 2013-2024, Thomas Michael Edwards <thomasmedwards@gmail.com>.
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this
       list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright notice,
       this list of conditions and the following disclaimer in the documentation
       and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
    ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
    ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
    (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
    ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """

    // MARK: - Starter

    static func starterStory(title: String) -> Story {
        Story(title: title, format: "SugarCube", formatVersion: version, startPID: "1",
              ifid: "FLOE-" + UUID().uuidString, storyAttributes: ["options": "", "creator": "Floe", "creator-version": "1.0"],
              passages: [
                Passage(pid: "1", name: "Start", tags: "", position: "100,100", size: "100,100",
                        text: """
                        森林邮差 · The Forest Postie<br><br>
                        <<set $letters = 3>>你背着邮包站在松林边，包里有 $letters 封没有地址的信。<br><br>
                        [[沿着溪流走|Stream]] · [[穿过橡树林|Grove]] · [[数一数邮包|Count]]
                        """, attributes: [:]),
                Passage(pid: "2", name: "Count", tags: "", position: "300,100", size: "100,100",
                        text: """
                        <<set $letters = $letters + 1>>你数了数信封：$letters 封。总会有人认得收件人的。<br><br>
                        [[回到林间|Start]]
                        """, attributes: [:]),
                Passage(pid: "3", name: "Stream", tags: "", position: "100,260", size: "100,100",
                        text: """
                        溪水把月光揉碎了。一只苍鹭歪着头看你。<br><br>
                        [[把信给苍鹭看|Heron]] · [[退回林间|Start]]
                        """, attributes: [:]),
                Passage(pid: "4", name: "Heron", tags: "", position: "300,260", size: "100,100",
                        text: """
                        <<set $delivered = true>>苍鹭叼起最旧的那封信，飞向山那边。信送到了。
                        """, attributes: [:]),
                Passage(pid: "5", name: "Grove", tags: "", position: "100,420", size: "100,100",
                        text: """
                        老橡树的洞里飘出炊烟。有人在家。<br><br>
                        [[敲敲门|Door]] · [[离开|Start]]
                        """, attributes: [:]),
                Passage(pid: "6", name: "Door", tags: "", position: "300,420", size: "100,100",
                        text: """
                        门开了一条缝。“这信是给我的吗？”<br><br>
                        <<set $delivered = true>><<set $letters = 0>>你交出了所有信。
                        """, attributes: [:])
              ])
    }
}

// MARK: - Twine 2 HTML parsing

enum StoryParser {
    static func parse(html: String) throws -> GameTwineAdapter.Story {
        guard let openRange = html.range(of: "<tw-storydata"),
              let openEnd = html.range(of: ">", range: openRange.upperBound..<html.endIndex) else {
            throw NarrativeAdapterError.invalidProject("no tw-storydata element")
        }
        let openTag = String(html[openRange.lowerBound..<openEnd.lowerBound])
        let storyAttributes = try HTML.attributes(in: openTag)
        guard let start = storyAttributes["startnode"], let bodyEnd = html.range(of: "</tw-storydata>", range: openEnd.upperBound..<html.endIndex) else {
            throw NarrativeAdapterError.invalidProject("missing startnode")
        }
        let body = String(html[openEnd.upperBound..<bodyEnd.lowerBound])
        var passages: [GameTwineAdapter.Passage] = []
        var cursor = body.startIndex
        while let open = body.range(of: "<tw-passagedata", range: cursor..<body.endIndex) {
            guard let tagEnd = body.range(of: ">", range: open.upperBound..<body.endIndex) else { break }
            let tag = String(body[open.lowerBound..<tagEnd.lowerBound])
            guard let close = body.range(of: "</tw-passagedata>", range: tagEnd.upperBound..<body.endIndex) else { break }
            var attributes = try HTML.attributes(in: tag)
            let text = HTML.unescapeText(String(body[tagEnd.upperBound..<close.lowerBound]))
            guard let pid = attributes.removeValue(forKey: "pid"), let name = attributes.removeValue(forKey: "name") else {
                throw NarrativeAdapterError.invalidProject("passage missing pid/name")
            }
            passages.append(.init(pid: pid, name: name,
                                  tags: attributes.removeValue(forKey: "tags") ?? "",
                                  position: attributes.removeValue(forKey: "position") ?? "100,100",
                                  size: attributes.removeValue(forKey: "size") ?? "100,100",
                                  text: text, attributes: attributes))
            cursor = close.upperBound
        }
        guard passages.contains(where: { $0.pid == start }) else {
            throw NarrativeAdapterError.invalidProject("startnode does not match a passage pid")
        }
        var preserved = storyAttributes
        let known = ["name", "startnode", "creator", "creator-version", "ifid", "format", "format-version", "options", "hidden", "tags"]
        for key in known { preserved.removeValue(forKey: key) }
        return .init(title: storyAttributes["name"] ?? "Twine story",
                     format: storyAttributes["format"] ?? "SugarCube",
                     formatVersion: storyAttributes["format-version"] ?? GameTwineAdapter.version,
                     startPID: start,
                     ifid: storyAttributes["ifid"] ?? UUID().uuidString,
                     storyAttributes: preserved,
                     passages: passages)
    }
}

enum HTML {
    static func escapeText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ value: String) -> String {
        escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescapeText(_ value: String) -> String {
        var result = value
        let map = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&amp;": "&"]
        // Ampersand last to avoid double-decoding.
        for key in ["&lt;", "&gt;", "&quot;", "&#39;", "&apos;", "&amp;"] { result = result.replacingOccurrences(of: key, with: map[key]!) }
        return result
    }

    /// Parses attributes of a single opening tag (content after the tag name).
    static func attributes(in tag: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = tag.startIndex
        func skipWhitespace() { while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) } }
        // Skip tag name.
        skipWhitespace()
        while index < tag.endIndex, !tag[index].isWhitespace, tag[index] != ">" { index = tag.index(after: index) }
        while index < tag.endIndex {
            skipWhitespace()
            guard index < tag.endIndex, tag[index] != ">", tag[index] != "/" else { break }
            let nameStart = index
            while index < tag.endIndex, !tag[index].isWhitespace, tag[index] != "=", tag[index] != ">" { index = tag.index(after: index) }
            let name = String(tag[nameStart..<index])
            skipWhitespace()
            guard index < tag.endIndex, tag[index] == "=" else {
                if !name.isEmpty { result[name] = "" }
                continue
            }
            index = tag.index(after: index)
            skipWhitespace()
            guard index < tag.endIndex else { throw NarrativeAdapterError.invalidProject("unterminated attribute") }
            let quote = tag[index]
            if quote == "\"" || quote == "'" {
                index = tag.index(after: index)
                let start = index
                while index < tag.endIndex, tag[index] != quote { index = tag.index(after: index) }
                guard index < tag.endIndex else { throw NarrativeAdapterError.invalidProject("unterminated attribute value") }
                result[name] = unescapeText(String(tag[start..<index]))
                index = tag.index(after: index)
            } else {
                let start = index
                while index < tag.endIndex, !tag[index].isWhitespace, tag[index] != ">" { index = tag.index(after: index) }
                result[name] = unescapeText(String(tag[start..<index]))
            }
            guard result.count <= 64 else { throw NarrativeAdapterError.invalidProject("too many attributes") }
        }
        return result
    }
}
