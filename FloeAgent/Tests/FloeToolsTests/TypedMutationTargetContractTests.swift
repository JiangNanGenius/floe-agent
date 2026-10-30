// FloeToolsTests — typed mutable-target contract and canonical resolver.
//
// Proves the SINGLE SOURCE OF TRUTH the approval policy, mutation
// coordination and the runtime-authority binding all consume:
//
// - every ordinary document/media family resolves its REAL mutable outputs
//   (and never lists read-only inputs);
// - an unpinnable required destination fails closed to the workspace wildcard;
// - the FIRST lease/authority key keeps each existing consumer mirror intact
//   (office/CAD `file:<path>`, media.project `workspace:<root>`) so the
//   runtime-minted canonical target still matches the tool-side binding;
// - the Canvas staged hook pins an authorized staged `cad.document` target to
//   the staged draft root (exact relative path or canonical absolute form),
//   and nothing else under the draft root;
// - derivations replicate the real tools' documented defaults.
//
// These are module tests over real FloeTools types; they are NOT an App
// build and prove nothing about the tools' execution (the runtime tests and
// the App-level fixtures cover that).

import Foundation
import Testing
@testable import FloeTools
@testable import FloeModels

@Suite("FloeTools.TypedMutationContract")
struct TypedMutationTargetContractTests {

    private func call(_ tool: String, _ json: String) throws -> ToolCall {
        try ToolCall(
            id: "call_1",
            toolName: tool,
            argumentsJSON: Data(json.utf8),
            scope: .local
        )
    }

    private func descriptor(_ name: String, mutating: Bool = true) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            riskLabels: [.readsFiles, .writesFiles],
            isSideEffecting: mutating,
            effect: mutating ? .mutating : .readOnly
        )
    }

    private func makeTree(git: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if git {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    private func resolve(
        _ tool: String,
        _ json: String,
        root: URL?,
        stores: [String: String] = [:],
        staged: CanvasStagedDocumentAccess? = nil
    ) throws -> MutationTargetResolution {
        MutationTargetResolver.resolve(
            for: try call(tool, json),
            descriptor: descriptor(tool),
            workspaceRootURL: root,
            serviceStorePaths: stores,
            stagedDocument: staged
        )
    }

    private func authorityTarget(
        _ tool: String,
        _ json: String,
        root: URL?,
        staged: CanvasStagedDocumentAccess? = nil
    ) throws -> String {
        RuntimeAuthorityDigest.canonicalTarget(
            for: try call(tool, json),
            descriptor: descriptor(tool),
            workspaceRootURL: root,
            stagedDocument: staged
        )
    }

    private func fileKey(_ path: String) -> MutationTargetKey { .file(path) }

    // MARK: - PDF family

    @Test("pdf.edit pins outputPath as the only mutable target; inputPath is a read")
    func pdfEditPinsOutput() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("b.pdf").path
        let resolution = try resolve(
            "document.pdf.edit",
            #"{"inputPath":"a.pdf","outputPath":"b.pdf"}"#,
            root: root
        )
        #expect(resolution.keys == [fileKey(out)])
        #expect(resolution.mutableTargets == [TypedMutableTarget(path: out, role: .outputWrite)])
        #expect(!resolution.hasUnresolvedExtent)
        #expect(resolution.contractCovered)
        #expect(!resolution.mutableTargets.contains { $0.path.hasSuffix("a.pdf") },
                "the read-only source must never be classified as a mutable target")
        #expect(try authorityTarget("document.pdf.edit", #"{"inputPath":"a.pdf","outputPath":"b.pdf"}"#, root: root)
            == "file:" + out)
    }

    @Test("A required destination missing makes the whole call unresolved")
    func missingRequiredOutputIsUnresolved() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = try resolve("document.pdf.edit", #"{"inputPath":"a.pdf"}"#, root: root)
        #expect(resolution.hasUnresolvedExtent)
        #expect(resolution.contractCovered, "the contract declares this action; the extent just could not be pinned")
        #expect(resolution.keys == [.workspace(root.resolvingSymlinksInPath().standardizedFileURL.path)])
        #expect(resolution.mutableTargets.isEmpty, "never a partial classification")
    }

    @Test("PDF fillForm derives the documented -filled.pdf sibling; render bounds PDFRenders")
    func pdfDefaultDerivations() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let filled = try resolve("document.pdf.fillForm", #"{"action":"fill","inputPath":"a.pdf"}"#, root: root)
        #expect(filled.mutableTargets.map(\.path) == [root.appendingPathComponent("a-filled.pdf").path])

        let renders = try resolve("document.pdf.render", #"{"path":"a.pdf","page":1}"#, root: root)
        #expect(renders.mutableTargets.map(\.path) == [root.appendingPathComponent("PDFRenders").path])

        let explicit = try resolve(
            "document.pdf.render",
            #"{"path":"a.pdf","page":1,"outputPath":"page.jpeg"}"#,
            root: root
        )
        #expect(explicit.mutableTargets.map(\.path) == [root.appendingPathComponent("page.jpeg").path])

        // list is a read.
        let list = try resolve("document.pdf.fillForm", #"{"action":"list","inputPath":"a.pdf"}"#, root: root)
        #expect(list.contractCovered == false)
        #expect(list.hasUnresolvedExtent)
    }

    // MARK: - Office family

    @Test("Office automatic copy pins ONLY the copy; the source stays a read")
    func officeAutomaticCopyPinsOutput() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.docx").path
        let output = root.appendingPathComponent("out/edited.docx").path
        let resolution = try resolve(
            "document.office.edit",
            #"{"action":"apply","path":"report.docx","proposal_id":"p","output":"out/edited.docx"}"#,
            root: root
        )
        #expect(resolution.mutableTargets == [TypedMutableTarget(path: output, role: .outputWrite)])
        // Lease/authority keys keep the mirror-preserved source key FIRST and
        // add the output.
        #expect(resolution.keys.first == fileKey(source))
        #expect(resolution.keys.contains(fileKey(output)))
        // The tool mirrors `RuntimeAuthorityDigest.canonicalTarget` as
        // "file:" + canonical(path): the minted authority target must agree.
        #expect(try authorityTarget(
            "document.office.edit",
            #"{"action":"apply","path":"report.docx","proposal_id":"p","output":"out/edited.docx"}"#,
            root: root
        ) == "file:" + source)
    }

    @Test("Office grant apply rewrites the source in place; defaults derive the documented copies")
    func officeGrantApplyAndDefaults() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.docx").path

        let granted = try resolve(
            "document.office.edit",
            #"{"action":"apply","path":"report.docx","proposal_id":"p","grant_id":"g"}"#,
            root: root
        )
        #expect(granted.mutableTargets == [TypedMutableTarget(path: source, role: .sourceWrite)])

        let automatic = try resolve(
            "document.office.edit",
            #"{"action":"apply","path":"report.docx","proposal_id":"p"}"#,
            root: root
        )
        #expect(automatic.mutableTargets.map(\.path)
            == [root.appendingPathComponent("report.edited.docx").path],
            "automatic apply publishes <name>.edited.<ext>")

        let exported = try resolve(
            "document.office.edit",
            #"{"action":"export","path":"report.docx"}"#,
            root: root
        )
        #expect(exported.mutableTargets.map(\.path)
            == [root.appendingPathComponent("report.docx.export.docx").path],
            "export appends .export.<ext> to the full source name")

        let proposed = try resolve(
            "document.office.edit",
            #"{"action":"propose","path":"report.docx","expected_sha256":"x"}"#,
            root: root
        )
        #expect(proposed.mutableTargets == [TypedMutableTarget(path: source, role: .draftTarget)])

        let replaced = try resolve(
            "document.office.edit",
            #"{"action":"replaceImage","path":"report.docx","imagePath":"i.png"}"#,
            root: root
        )
        #expect(replaced.mutableTargets == [TypedMutableTarget(path: source, role: .sourceWrite)])
        #expect(!replaced.mutableTargets.contains { $0.path.hasSuffix("i.png") })

        let updated = try resolve(
            "document.office.updateText",
            #"{"path":"report.docx","updates":{},"expectedSHA256":"x"}"#,
            root: root
        )
        #expect(updated.mutableTargets == [TypedMutableTarget(path: source, role: .sourceWrite)])

        // Apply with an `output` but no `path`: the tool mirror stays the
        // workspace root (the stored proposal's document is authoritative),
        // so the contract must fail closed instead of claiming a file target
        // the runtime-authority mirror does not carry.
        let noPath = try resolve(
            "document.office.edit",
            #"{"action":"apply","proposal_id":"p","output":"out/edited.docx"}"#,
            root: root
        )
        #expect(noPath.hasUnresolvedExtent)
        #expect(noPath.keys == [.workspace(root.resolvingSymlinksInPath().standardizedFileURL.path)])
        #expect(try authorityTarget(
            "document.office.edit",
            #"{"action":"apply","proposal_id":"p","output":"out/edited.docx"}"#,
            root: root
        ) == "workspace:" + root.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    // MARK: - media.project service store

    @Test("media.project pins the service-owned record; the mirror key stays workspace-root first")
    func mediaProjectStoreResolution() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeTree()
        defer { try? FileManager.default.removeItem(at: store) }
        let projectID = UUID()
        let record = store.appendingPathComponent("media-project-\(projectID.uuidString.lowercased()).json").path
        let stores = [TypedMutationContract.mediaProjectStoreKey: store.path]

        let applied = try resolve(
            "media.project",
            #"{"action":"apply","project_id":"\#(projectID.uuidString)","proposal_id":"p"}"#,
            root: root,
            stores: stores
        )
        #expect(applied.mutableTargets == [TypedMutableTarget(path: record, role: .sourceWrite)])
        // MediaProjectTool mirrors canonicalTarget as the workspace wildcard:
        // the FIRST key must stay exactly that or the automatic apply refuses.
        let workspaceKey = root.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(applied.keys.first == .workspace(workspaceKey))
        #expect(applied.keys.contains(fileKey(record)))
        #expect(try authorityTarget(
            "media.project",
            #"{"action":"apply","project_id":"\#(projectID.uuidString)","proposal_id":"p"}"#,
            root: root
        ) == "workspace:" + workspaceKey)
    }

    @Test("media.project fails closed without the store or a valid project id")
    func mediaProjectFailClosed() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID()

        let noStore = try resolve(
            "media.project",
            #"{"action":"apply","project_id":"\#(projectID.uuidString)","proposal_id":"p"}"#,
            root: root
        )
        #expect(noStore.hasUnresolvedExtent)
        #expect(noStore.contractCovered)
        #expect(noStore.mutableTargets.isEmpty)

        let store = try makeTree()
        defer { try? FileManager.default.removeItem(at: store) }
        let badID = try resolve(
            "media.project",
            #"{"action":"apply","project_id":"not-a-uuid","proposal_id":"p"}"#,
            root: root,
            stores: [TypedMutationContract.mediaProjectStoreKey: store.path]
        )
        #expect(badID.hasUnresolvedExtent)

        // An EXPORT's real consumer output is the validated basename inside
        // the fixed `Workbench/Exports` directory (the derivation shared with
        // `MediaProjectTool`), never a raw path at the workspace root.
        for (json, expected) in [
            (#"{"action":"export","project_id":"\#(projectID.uuidString)","export":{"kind":"image","file_name":"out","format":"png"}}"#,
             "Workbench/Exports/out.png"),
            (#"{"action":"export","project_id":"\#(projectID.uuidString)","export":{"kind":"image","file_name":"still","format":"jpeg"}}"#,
             "Workbench/Exports/still.jpeg"),
            (#"{"action":"export","project_id":"\#(projectID.uuidString)","export":{"kind":"video","file_name":"clip","codec":"h264","frame_rate":30}}"#,
             "Workbench/Exports/clip.mp4")
        ] {
            let exported = try resolve(
                "media.project", json, root: root,
                stores: [TypedMutationContract.mediaProjectStoreKey: store.path]
            )
            #expect(exported.mutableTargets.map(\.path)
                == [root.appendingPathComponent(expected).path],
                "media export must pin the real Workbench/Exports output: \(json)")
            #expect(!exported.hasUnresolvedExtent)
            // The media mirror key stays the workspace bound FIRST.
            #expect(exported.keys.first
                == .workspace(root.resolvingSymlinksInPath().standardizedFileURL.path))
        }
        // Invalid basename, unknown kind, unsupported/missing format and a
        // missing export object all fail closed: no path is claimed.
        for json in [
            #"{"action":"export","project_id":"\#(projectID.uuidString)","export":{"kind":"image","file_name":"out.png","format":"png"}}"#,
            #"{"action":"export","project_id":"\#(projectID.uuidString)","export":{"kind":"image","file_name":"out","format":"tiff"}}"#,
            #"{"action":"export","project_id":"\#(projectID.uuidString)","export":{"kind":"audio","file_name":"out"}}"#,
            #"{"action":"export","project_id":"\#(projectID.uuidString)","export":{"kind":"image","format":"png"}}"#,
            #"{"action":"export","project_id":"\#(projectID.uuidString)"}"#
        ] {
            let unresolved = try resolve(
                "media.project", json, root: root,
                stores: [TypedMutationContract.mediaProjectStoreKey: store.path]
            )
            #expect(unresolved.hasUnresolvedExtent,
                    "an invalid/unsupported media export must fail closed: \(json)")
            #expect(unresolved.mutableTargets.isEmpty)
        }
    }

    // MARK: - Video / audio / image families

    @Test("Video, audio and image tools pin their output argument")
    func mediaFamiliesPinOutputs() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        for (tool, json, expected) in [
            ("video.edit", #"{"input":"in.mov","output":"out.mp4","operations":[],"exportSpec":{"container":"mp4"}}"#, "out.mp4"),
            ("video.transcode", #"{"input":"in.mov","output":"out.mp4","container":"mp4"}"#, "out.mp4"),
            ("video.thumbnail", #"{"input":"in.mov","timeSeconds":1,"output":"t.png","maximumDimension":64}"#, "t.png"),
            ("video.remux", #"{"input":"in.mov","output":"out.mov"}"#, "out.mov"),
            ("video.proxy", #"{"input":"in.mov","output":"p.mov"}"#, "p.mov"),
            ("audio.edit", #"{"input":"in.wav","output":"out.wav"}"#, "out.wav"),
            ("audio.convert", #"{"input":"in.wav","output":"out.m4a","container":"m4a"}"#, "out.m4a"),
            ("audio.mix", #"{"input":"a.wav","mixPath":"b.wav","output":"m.wav"}"#, "m.wav"),
            ("video.interpolate", #"{"input":"in.mov","output":"out.mov","targetFPS":60,"mode":"quality"}"#, "out.mov"),
            ("video.superResolution", #"{"input":"in.mov","output":"out.mov","scaleFactor":2,"mode":"quality"}"#, "out.mov")
        ] {
            let resolution = try resolve(tool, json, root: root)
            #expect(
                resolution.mutableTargets.map(\.path) == [root.appendingPathComponent(expected).path],
                "\(tool) must pin \(expected)"
            )
            #expect(resolution.keys == [fileKey(root.appendingPathComponent(expected).path)],
                    "\(tool) keys are the narrow output file")
        }

        let frames = try resolve(
            "video.extractFrames",
            #"{"path":"in.mov","outputDirectory":"frames","format":"png","maximumFrames":10}"#,
            root: root
        )
        #expect(frames.mutableTargets.map(\.path) == [root.appendingPathComponent("frames").path])

        let processed = try resolve("image.process", #"{"path":"photo.png","operation":"resize","width":10}"#, root: root)
        #expect(processed.mutableTargets.map(\.path) == [root.appendingPathComponent("photo-edited.png").path])

        let converted = try resolve(
            "image.process",
            #"{"path":"photo.png","operation":"convert","format":"jpeg"}"#,
            root: root
        )
        #expect(converted.mutableTargets.map(\.path) == [root.appendingPathComponent("photo-edited.jpg").path])

        // SVG's schema key is `operation`, not `action`: a real edit must be
        // typed (and pin its output), while inspect stays read-only.
        let svg = try resolve("image.svgDocument", #"{"operation":"edit","path":"in.svg","outputPath":"out.svg"}"#, root: root)
        #expect(svg.mutableTargets.map(\.path) == [root.appendingPathComponent("out.svg").path])
        #expect(svg.contractCovered)
        #expect(!svg.hasUnresolvedExtent)
        let svgInspect = try resolve("image.svgDocument", #"{"operation":"inspect","path":"in.svg"}"#, root: root)
        #expect(svgInspect.mutableTargets.isEmpty, "inspect writes nothing")
        #expect(!svgInspect.contractCovered)

        let qr = try resolve("image.qr.generate", #"{"content":"x"}"#, root: root)
        #expect(qr.mutableTargets.map(\.path) == [root.appendingPathComponent("QRCode").path],
                "the random default name is bounded to its documented directory")
    }

    // MARK: - CAD family and the Canvas staged hook

    @Test("Native CAD parameter edits retain exact document ownership without an extra review target")
    func nativeCADParameterMutationsPinOnlyTheirDocument() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("part.floecad").path
        for operation in ["update", "updateSketchEntity", "setSketchDimension", "removeSketchDimension",
                          "feature.suppress", "feature.delete", "feature.move", "undo", "redo"] {
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["action": operation]),
                                 as: UTF8.self)
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: [
                "action": "parameters", "path": "part.floecad", "payload": payload
            ]), as: UTF8.self)
            let result = try resolve("cad.document", arguments, root: root)
            #expect(result.contractCovered)
            #expect(!result.hasUnresolvedExtent)
            #expect(result.mutableTargets == [TypedMutableTarget(path: target, role: .sourceWrite)])
            #expect(try authorityTarget("cad.document", arguments, root: root) == "file:" + target)
        }
    }

    @Test("cad.document types the package target, drafts and export copies")
    func cadFamilyTyping() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let drawing = root.appendingPathComponent("part.dwg").path

        let applied = try resolve(
            "cad.document", #"{"action":"apply","path":"part.dwg","proposal_id":"p"}"#, root: root
        )
        #expect(applied.keys == [fileKey(drawing)], "CAD apply keeps file:<path> as FIRST key (tool mirror)")
        #expect(applied.mutableTargets == [TypedMutableTarget(path: drawing, role: .sourceWrite)])

        let exportedDXF = try resolve("cad.document", #"{"action":"export","path":"part.dwg"}"#, root: root)
        #expect(exportedDXF.mutableTargets.map(\.path) == [root.appendingPathComponent("part.export.dxf").path])

        let native = root.appendingPathComponent("part.floecad").path
        let exportedSTEP = try resolve("cad.document", #"{"action":"export","path":"part.floecad"}"#, root: root)
        #expect(exportedSTEP.mutableTargets.map(\.path) == [root.appendingPathComponent("part.export.step").path])
        let explicit = try resolve(
            "cad.document", #"{"action":"export","path":"part.floecad","output":"copy.step"}"#, root: root
        )
        #expect(explicit.mutableTargets.map(\.path) == [root.appendingPathComponent("copy.step").path])

        let proposed = try resolve("cad.document", #"{"action":"propose","path":"part.dwg"}"#, root: root)
        #expect(proposed.mutableTargets == [TypedMutableTarget(path: drawing, role: .draftTarget)])

        let imported = try resolve(
            "cad.document", #"{"action":"import","path":"part.floecad","sourcePath":"s.step"}"#, root: root
        )
        #expect(imported.mutableTargets == [TypedMutableTarget(path: native, role: .sourceWrite)])
    }

    @Test("The Canvas staged hook pins ONLY the authorized staged document")
    func canvasStagedHook() throws {
        let taskRoot = try makeTree()
        defer { try? FileManager.default.removeItem(at: taskRoot) }
        let draftRoot = try makeTree()
        defer { try? FileManager.default.removeItem(at: draftRoot) }
        let staged = CanvasStagedDocumentAccess(
            canvasID: UUID(),
            draftRootPath: draftRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            stagedRelativePath: "docs/part.floecad"
        )
        let stagedCanonical = draftRoot.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("docs/part.floecad")
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        // Relative form: pinned to the staged draft root, not the task root.
        let relative = try resolve(
            "cad.document",
            #"{"action":"apply","path":"docs/part.floecad","proposal_id":"p"}"#,
            root: taskRoot,
            staged: staged
        )
        #expect(relative.keys == [fileKey(stagedCanonical)])
        #expect(relative.mutableTargets == [TypedMutableTarget(path: stagedCanonical, role: .sourceWrite)])

        // Canonical absolute form: same target.
        let absolute = try resolve(
            "cad.document",
            #"{"action":"apply","path":"\#(stagedCanonical)","proposal_id":"p"}"#,
            root: taskRoot,
            staged: staged
        )
        #expect(absolute.keys == [fileKey(stagedCanonical)])
        #expect(try authorityTarget(
            "cad.document",
            #"{"action":"apply","path":"\#(stagedCanonical)","proposal_id":"p"}"#,
            root: taskRoot,
            staged: staged
        ) == "file:" + stagedCanonical)

        // Any OTHER document under the draft root is never covered by the
        // staged binding; it resolves like an ordinary workspace path.
        let other = try resolve(
            "cad.document",
            #"{"action":"apply","path":"docs/other.floecad","proposal_id":"p"}"#,
            root: taskRoot,
            staged: staged
        )
        #expect(other.keys == [fileKey(taskRoot.appendingPathComponent("docs/other.floecad").path)])

        // Non-cad tools never consume the staged binding. The office apply
        // pins the task-root source AND its verified edited-copy destination
        // (the typed automatic copy `<name>.edited.<ext>`); neither key may
        // come from the draft root.
        let office = try resolve(
            "document.office.edit",
            #"{"action":"apply","path":"docs/part.floecad","proposal_id":"p"}"#,
            root: taskRoot,
            staged: staged
        )
        let officeSource = fileKey(taskRoot.appendingPathComponent("docs/part.floecad").path)
        let officeCopy = fileKey(taskRoot.appendingPathComponent("docs/part.edited.floecad").path)
        #expect(Set(office.keys) == Set([officeSource, officeCopy]),
                "office pins the source and its edited copy under the task root: \(office.keys)")
        #expect(!office.keys.contains(fileKey(stagedCanonical)),
                "no office key may consume the staged draft binding")
    }

    // MARK: - Boundaries preserved

    @Test("Legacy families and unknown tools keep their exact previous behavior")
    func legacyAndUnknownToolsUnchanged() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceKey = root.resolvingSymlinksInPath().standardizedFileURL.path

        let write = try resolve("workspace.writeFile", #"{"path":"a.txt","content":"x"}"#, root: root)
        #expect(write.keys == [fileKey(root.appendingPathComponent("a.txt").path)])
        #expect(write.mutableTargets == [TypedMutableTarget(path: root.appendingPathComponent("a.txt").path, role: .pinned)])
        #expect(write.contractCovered == false)

        let move = try resolve("workspace.moveFile", #"{"from":"a.txt","to":"b.txt"}"#, root: root)
        #expect(move.keys == [fileKey(root.appendingPathComponent("a.txt").path),
                              fileKey(root.appendingPathComponent("b.txt").path)])

        let shell = try resolve("exec.shell", #"{"command":"ls"}"#, root: root)
        #expect(shell.keys == [.workspace(workspaceKey)])
        #expect(shell.hasUnresolvedExtent)

        let unknown = try resolve("acme.custommutate", #"{"path":"a.txt"}"#, root: root)
        #expect(unknown.keys == [.workspace(workspaceKey)])
        #expect(unknown.mutableTargets.isEmpty)

        let download = try resolve("network.download", #"{"url":"https://e.com/a","path":"a.bin"}"#, root: root)
        #expect(download.keys == [.workspace(workspaceKey)])

        // Read-only descriptors resolve to nothing at all.
        let readOnly = MutationTargetResolver.resolve(
            for: try call("document.pdf.edit", #"{"inputPath":"a.pdf","outputPath":"b.pdf"}"#),
            descriptor: descriptor("document.pdf.edit", mutating: false),
            workspaceRootURL: root
        )
        #expect(readOnly.keys.isEmpty)
    }
}
