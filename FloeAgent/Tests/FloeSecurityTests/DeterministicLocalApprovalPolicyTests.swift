// FloeSecurityTests — deterministic local approval carve-outs.
//
// Covers the user policy implemented by `DeterministicLocalApprovalPolicy`:
// an ordinary document/media edit whose REAL mutable targets the typed
// mutable-target contract POSITIVELY resolved to files outside any Git
// worktree executes without a per-edit review — PDF (edit/fillForm/export/
// render), Office (updateText/create*/apply/export/propose/replaceImage), CAD
// (create/apply/save/import/propose/export), media.project
// (propose/apply/export) and the video/audio/image editors. Repository
// content, nested repositories, redirected/mixed extents, unresolved targets,
// destructive-overwrite flags, PDF consent operations, credentials, package
// acquisition, remote changes, unknown environments and mutating tools the
// contract does not type keep the existing policy. Routine commands are
// admitted only in a resolved local Linux guest (read-only anywhere;
// build/test forms only outside a repository workspace) and are explicitly
// neither a sandbox nor a disposability/ownership claim (shared/project
// guests included).

import Foundation
import Testing
@testable import FloeSecurity
@testable import FloeModels
@testable import FloeCore

@Suite("FloeSecurity.DeterministicLocalApproval")
struct DeterministicLocalApprovalPolicyTests {

    // MARK: - Harness

    /// Records whether a policy consulted the model reviewer. Locking stays
    /// inside synchronous helpers: `NSLock` is unavailable from async
    /// contexts on this SDK.
    final class RecordingBackend: ModelApprovalPolicy.DecisionBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ProposedAction] = []
        private let decision: ApprovalDecision

        init(decision: ApprovalDecision = .allow(
            scope: ApprovalScope(toolName: "reviewed"),
            expiresAt: nil
        )) {
            self.decision = decision
        }

        var actions: [ProposedAction] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        private func record(_ action: ProposedAction) {
            lock.lock()
            recorded.append(action)
            lock.unlock()
        }

        func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
            record(action)
            return decision
        }
    }

    private func action(
        _ tool: String,
        _ json: String,
        scope: ToolScope = .local,
        environment: ApprovalEnvironmentClass = .localNative,
        targets: [String] = [],
        unresolvedExtent: Bool = false,
        typedCovered: Bool = false,
        workspace: String? = nil
    ) throws -> ProposedAction {
        let call = try ToolCall(
            id: "call_1",
            toolName: tool,
            argumentsJSON: Data(json.utf8),
            scope: scope
        )
        return ProposedAction(
            toolCall: call,
            riskLabels: ["readsFiles", "writesFiles"],
            userGoal: "edit the document",
            hostAndPathScope: scope,
            trustedContext: TrustedExecutionContext(
                environmentClass: environment,
                mutableTargetPaths: targets,
                hasUnresolvedExtent: unresolvedExtent,
                typedContractCovered: typedCovered,
                workspaceRootPath: workspace
            )
        )
    }

    /// Temporary tree with optional `.git` directory / gitfile markers.
    private func makeTree(
        git: (kind: String, name: String)? = nil
    ) throws -> (root: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("k-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let git {
            switch git.kind {
            case "directory":
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(".git", isDirectory: true),
                    withIntermediateDirectories: true
                )
            case "gitfile":
                try "gitdir: /elsewhere/.git/worktrees/\(git.name)\n".write(
                    to: root.appendingPathComponent(".git"),
                    atomically: true,
                    encoding: .utf8
                )
            case "invalid-gitfile":
                try "not a git pointer\n".write(
                    to: root.appendingPathComponent(".git"),
                    atomically: true,
                    encoding: .utf8
                )
            default:
                break
            }
        }
        return (root, { try? FileManager.default.removeItem(at: root) })
    }

    private func nestedDirectories(under root: URL, depth: Int) throws -> URL {
        var url = root
        for index in 0..<depth {
            url.appendPathComponent("d\(index)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Repository boundary detection

    @Test("Repository ancestry proves .git directories and worktree gitfiles only")
    func repositoryBoundaryDetection() throws {
        let plain = try makeTree()
        defer { plain.cleanup() }
        #expect(
            RepositoryBoundaryDetector.classify(path: plain.root.appendingPathComponent("a.docx").path)
                == .outsideWorktree
        )

        let repo = try makeTree(git: ("directory", "repo"))
        defer { repo.cleanup() }
        try FileManager.default.createDirectory(
            at: repo.root.appendingPathComponent("docs", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(
            RepositoryBoundaryDetector.classify(path: repo.root.appendingPathComponent("docs/a.docx").path)
                == .insideWorktree(rootPath: repo.root.path)
        )

        let worktree = try makeTree(git: ("gitfile", "wt"))
        defer { worktree.cleanup() }
        #expect(
            RepositoryBoundaryDetector.classify(path: worktree.root.appendingPathComponent("part.floecad").path)
                == .insideWorktree(rootPath: worktree.root.path)
        )

        // Unreadable or non-gitfile `.git` metadata is never "outside".
        let invalid = try makeTree(git: ("invalid-gitfile", "x"))
        defer { invalid.cleanup() }
        #expect(
            RepositoryBoundaryDetector.classify(path: invalid.root.appendingPathComponent("a.docx").path)
                == .undetermined
        )

        let unreadable = try makeTree(git: ("gitfile", "perm"))
        defer { unreadable.cleanup() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: unreadable.root.appendingPathComponent(".git").path
        )
        #expect(
            RepositoryBoundaryDetector.classify(path: unreadable.root.appendingPathComponent("a.docx").path)
                == .undetermined
        )

        // A walk that hits the ancestor bound before proving anything is not
        // "outside".
        let deepRoot = try makeTree()
        defer { deepRoot.cleanup() }
        let deep = try nestedDirectories(under: deepRoot.root, depth: 70)
        #expect(RepositoryBoundaryDetector.classify(path: deep.appendingPathComponent("a.docx").path) == .undetermined)
        let shallow = try nestedDirectories(under: deepRoot.root, depth: 5)
        #expect(
            RepositoryBoundaryDetector.classify(path: shallow.appendingPathComponent("a.docx").path)
                == .outsideWorktree
        )
        #expect(RepositoryBoundaryDetector.classify(path: nil) == .undetermined)
    }

    @Test("A symlink into a repository is repository content")
    func symlinkTargetIsCanonicalized() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let repo = try makeTree(git: ("directory", "r"))
        defer { repo.cleanup() }
        let secret = repo.root.appendingPathComponent("inside.docx")
        try Data("x".utf8).write(to: secret)
        let link = tree.root.appendingPathComponent("link.docx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(
            RepositoryBoundaryDetector.classify(path: link.path)
                == .insideWorktree(rootPath: repo.root.path)
        )
    }

    // MARK: - Ordinary document edits

    @Test("Positively resolved document/media edits outside a repository run without any review")
    func ordinaryDocumentEditsAreDeterministicallyAllowed() async throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let dir = tree.root.path
        let projectID = UUID().uuidString.lowercased()

        // (tool, arguments, first mutable target relative to the tree)
        let cases: [(String, String, String)] = [
            // Office package-level and engine-level edits.
            ("document.office.updateText", #"{"path":"report.docx","updates":{"a":"b"},"expectedSHA256":"x"}"#, "report.docx"),
            ("document.createWord", #"{"path":"new.docx","title":"t","paragraphs":[]}"#, "new.docx"),
            ("document.createWorkbook", #"{"path":"new.xlsx","sheets":[]}"#, "new.xlsx"),
            ("document.presentation.createDeck", #"{"path":"new.pptx","title":"t","slides":[]}"#, "new.pptx"),
            ("document.office.edit", #"{"action":"replaceImage","path":"report.docx"}"#, "report.docx"),
            // Automatic copy: mutable target is the verified COPY, not the source.
            ("document.office.edit", #"{"action":"apply","path":"report.docx","proposal_id":"p","output":"out/edited.docx"}"#, "out/edited.docx"),
            ("document.office.edit", #"{"action":"export","path":"report.docx"}"#, "report.docx.export.docx"),
            ("document.office.edit", #"{"action":"propose","path":"report.docx","expected_sha256":"x"}"#, "report.docx"),
            // PDF family: the new copy is the mutable target; inputPath is a read.
            ("document.pdf.edit", #"{"inputPath":"a.pdf","outputPath":"b.pdf"}"#, "b.pdf"),
            ("document.pdf.fillForm", #"{"action":"fill","inputPath":"a.pdf"}"#, "a-filled.pdf"),
            ("document.pdf.fillForm", #"{"action":"fill","inputPath":"a.pdf","outputPath":"c.pdf"}"#, "c.pdf"),
            ("document.pdf.export", #"{"inputPath":"a.pdf","outputPath":"a.txt","format":"text"}"#, "a.txt"),
            ("document.pdf.render", #"{"path":"a.pdf","page":1,"outputPath":"page.jpeg"}"#, "page.jpeg"),
            // Media project: the service-owned record / export file.
            ("media.project", #"{"action":"propose","project_id":"\#(projectID)","summary":"s","commands":[{"type":"set_canvas"}]}"#, "media-project-\(projectID).json"),
            ("media.project", #"{"action":"apply","project_id":"\#(projectID)","proposal_id":"p"}"#, "media-project-\(projectID).json"),
            // The validated basename writes under the fixed export directory
            // (real consumer shape; `out.png` would be rejected by the schema).
            ("media.project", #"{"action":"export","project_id":"\#(projectID)","export":{"kind":"image","file_name":"out","format":"png"}}"#, "Workbench/Exports/out.png"),
            ("media.project", #"{"action":"export","project_id":"\#(projectID)","export":{"kind":"video","file_name":"clip","codec":"h264","frame_rate":30}}"#, "Workbench/Exports/clip.mp4"),
            // Video/audio/image editing outputs.
            ("video.edit", #"{"input":"in.mov","output":"out.mp4","operations":[],"exportSpec":{"container":"mp4"}}"#, "out.mp4"),
            ("video.transcode", #"{"input":"in.mov","output":"out.mp4","container":"mp4"}"#, "out.mp4"),
            ("video.interpolate", #"{"input":"in.mov","output":"out.mov","targetFPS":60,"mode":"quality"}"#, "out.mov"),
            ("audio.mix", #"{"input":"a.wav","mixPath":"b.wav","output":"mixed.wav"}"#, "mixed.wav"),
            ("video.extractFrames", #"{"path":"in.mov","outputDirectory":"frames","format":"png","maximumFrames":10}"#, "frames"),
            ("image.process", #"{"path":"photo.png","operation":"resize","width":10}"#, "photo-edited.png"),
            ("image.svgDocument", #"{"operation":"edit","path":"in.svg","outputPath":"out.svg"}"#, "out.svg"),
            ("image.qr.generate", #"{"content":"x","outputPath":"qr.png"}"#, "qr.png"),
            // CAD family: in-place edits, drafts, copies.
            ("cad.document", #"{"action":"apply","path":"part.dwg","proposal_id":"p"}"#, "part.dwg"),
            ("cad.document", #"{"action":"save","path":"part.dwg"}"#, "part.dwg"),
            ("cad.document", #"{"action":"three_d_apply","path":"part.floecad","proposal_id":"p"}"#, "part.floecad"),
            ("cad.document", #"{"action":"create","path":"new.floecad"}"#, "new.floecad"),
            ("cad.document", #"{"action":"import","path":"part.floecad","sourcePath":"s.step"}"#, "part.floecad"),
            ("cad.document", #"{"action":"export","path":"part.dwg"}"#, "part.export.dxf"),
            ("cad.document", #"{"action":"export","path":"part.floecad","output":"copy.step"}"#, "copy.step")
        ]

        for (tool, json, target) in cases {
            let resolved = tree.root.appendingPathComponent(target).path
            let proposed = try action(
                tool, json,
                environment: .localLinuxVM,
                targets: [resolved],
                typedCovered: true
            )
            #expect(
                DeterministicLocalApprovalPolicy.isExempt(proposed),
                "\(tool) \(json) must be exempt when its mutable target is resolved outside a repository"
            )
            let scope = try #require(DeterministicLocalApprovalPolicy.allowedScope(for: proposed))
            #expect(scope.singleUse, "\(tool) carve-out must stay single-use")
            #expect(scope.toolName == tool)

            // Ask mode: no human card.
            #expect(try await HumanApprovalPolicy().decide(proposed).permitsExecution)
            // Automatic mode: no model review.
            let backend = RecordingBackend()
            let automatic = AutomaticApprovalPolicy(backend: backend)
            #expect(!automatic.requiresModelReview(proposed))
            #expect(try await automatic.decide(proposed).permitsExecution)
            #expect(backend.actions.isEmpty, "\(tool) must not consume a model review")
        }
    }

    @Test("Read-only sources are never classified: repo source + outside copy is an ordinary save")
    func readOnlyRepositorySourceWithOutsideCopyIsAllowed() async throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let repo = try makeTree(git: ("directory", "r"))
        defer { repo.cleanup() }
        // The source lives in a repository, the resolved MUTABLE target (the
        // authorized copy) is a new file outside it.
        let copy = tree.root.appendingPathComponent("copy.docx").path
        let proposed = try action(
            "document.office.edit",
            #"{"action":"apply","path":"\#(repo.root.appendingPathComponent("report.docx").path)","proposal_id":"p","output":"\#(copy)"}"#,
            targets: [copy],
            typedCovered: true
        )
        #expect(DeterministicLocalApprovalPolicy.isExempt(proposed))
        #expect(try await HumanApprovalPolicy().decide(proposed).permitsExecution)

        // The same call whose COPY is inside the repository keeps the card.
        let insideCopy = try action(
            "document.office.edit",
            #"{"action":"apply","path":"report.docx","proposal_id":"p","output":"\#(repo.root.appendingPathComponent("copy.docx").path)"}"#,
            targets: [repo.root.appendingPathComponent("copy.docx").path],
            typedCovered: true
        )
        #expect(!DeterministicLocalApprovalPolicy.isExempt(insideCopy))
    }

    @Test("The typed contract must actually cover the action; legacy file keys do not")
    func typedContractCoverageIsRequired() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let doc = tree.root.appendingPathComponent("report.docx").path
        // Same resolved target and tool, but the runtime did not classify it
        // through the contract (legacy/unknown family): the carve-out must
        // not apply.
        let legacy = try action(
            "document.office.edit",
            #"{"action":"apply","path":"report.docx","proposal_id":"p"}"#,
            targets: [doc]
        )
        #expect(!DeterministicLocalApprovalPolicy.isExempt(legacy))
    }

    @Test("An explicit destructive-overwrite flag keeps the existing review")
    func destructiveOverwriteFlagsStayReviewed() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let cases: [(String, String)] = [
            ("document.pdf.export", #"{"inputPath":"a.pdf","outputPath":"a.txt","format":"text","overwrite":true}"#),
            ("video.interpolate", #"{"input":"in.mov","output":"out.mov","targetFPS":60,"mode":"quality","overwrite":true}"#),
            ("video.superResolution", #"{"input":"in.mov","output":"out.mov","scaleFactor":2,"mode":"quality","overwrite":true}"#)
        ]
        for (tool, json) in cases {
            let proposed = try action(
                tool, json,
                targets: [tree.root.appendingPathComponent("a.txt").path],
                typedCovered: true
            )
            #expect(
                !DeterministicLocalApprovalPolicy.isExempt(proposed),
                "\(tool) with overwrite=true must keep the existing policy"
            )
            // Without the flag the same call is an ordinary new-file save.
            let plain = try action(
                tool,
                json.replacingOccurrences(of: #","overwrite":true"#, with: ""),
                targets: [tree.root.appendingPathComponent("a.txt").path],
                typedCovered: true
            )
            #expect(DeterministicLocalApprovalPolicy.isExempt(plain), "\(tool) plain save must stay exempt")
        }
    }

    @Test("A redirected or mixed write extent keeps the existing policy")
    func redirectedAndMixedExtentsStayReviewed() async throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let repo = try makeTree(git: ("directory", "r"))
        defer { repo.cleanup() }
        let doc = tree.root.appendingPathComponent("report.docx").path
        let other = tree.root.appendingPathComponent("elsewhere.docx").path

        // A redirected output INSIDE a repository is a repository write.
        let redirected = try action(
            "document.office.edit",
            #"{"action":"apply","path":"report.docx","proposal_id":"p","output":"\#(repo.root.appendingPathComponent("out.docx").path)"}"#,
            targets: [repo.root.appendingPathComponent("out.docx").path],
            typedCovered: true
        )
        #expect(!DeterministicLocalApprovalPolicy.isExempt(redirected))

        // Any call whose extent is a workspace wildcard is not resolved, even
        // if it also names a file.
        let wildcard = try action(
            "document.office.edit",
            #"{"action":"apply","path":"report.docx","proposal_id":"p"}"#,
            targets: [doc], unresolvedExtent: true, typedCovered: true
        )
        #expect(!DeterministicLocalApprovalPolicy.isExempt(wildcard))

        // Mixed target sets are classified in full: one repository path fails
        // the whole call.
        let mixed = TrustedExecutionContext(
            mutableTargetPaths: [doc, repo.root.appendingPathComponent("x.docx").path],
            typedContractCovered: true
        )
        #expect(!mixed.targetsAllOutsideRepository)
        let allOutside = TrustedExecutionContext(
            mutableTargetPaths: [doc, other],
            typedContractCovered: true
        )
        #expect(allOutside.targetsAllOutsideRepository)
        let empty = TrustedExecutionContext(
            mutableTargetPaths: [],
            typedContractCovered: true
        )
        #expect(!empty.targetsAllOutsideRepository)
    }

    @Test("Repository content, nested repositories and unresolved targets keep the existing policy")
    func repositoryAndUnresolvedTargetsStayReviewed() async throws {
        let repo = try makeTree(git: ("directory", "repo"))
        defer { repo.cleanup() }
        let worktree = try makeTree(git: ("gitfile", "wt"))
        defer { worktree.cleanup() }
        let outer = try makeTree()
        defer { outer.cleanup() }
        // A repository nested INSIDE the workspace: the workspace root itself
        // is not repository content, the document is.
        let nestedRepo = outer.root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedRepo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        for target in [
            repo.root.appendingPathComponent("docs/a.docx").path,
            worktree.root.appendingPathComponent("part.floecad").path,
            nestedRepo.appendingPathComponent("a.docx").path
        ] {
            let proposed = try action(
                "document.office.edit", #"{"action":"apply","path":"a.docx","proposal_id":"p"}"#,
                targets: [target], typedCovered: true
            )
            #expect(!DeterministicLocalApprovalPolicy.isExempt(proposed))
            guard case .escalateToHuman = try await HumanApprovalPolicy().decide(proposed) else {
                Issue.record("Repository document edit must keep the human card")
                continue
            }
            let backend = RecordingBackend()
            let automatic = AutomaticApprovalPolicy(backend: backend)
            #expect(automatic.requiresModelReview(proposed))
            _ = try await automatic.decide(proposed)
            #expect(backend.actions.count == 1, "Repository document edit must stay model-reviewed")
        }

        // No resolved target at all (contract covered but nothing pinned).
        let unresolved = try action(
            "document.office.edit", #"{"action":"apply"}"#,
            unresolvedExtent: true, typedCovered: true
        )
        #expect(!DeterministicLocalApprovalPolicy.isExempt(unresolved))
        guard case .escalateToHuman = try await HumanApprovalPolicy().decide(unresolved) else {
            Issue.record("Unresolved target must keep the human card")
            return
        }
    }

    @Test("Mutating tools outside the ordinary families are not covered")
    func nonEditActionsAndUnrelatedToolsStayReviewed() throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let doc = tree.root.appendingPathComponent("a.docx").path

        // Tools/actions the typed contract does not declare AND the audited
        // read/draft profile does not classify: a pinned file target alone
        // must not grant the no-card path.
        for (tool, json) in [
            ("workspace.writeFile", #"{"path":"a.txt","content":"x"}"#),
            ("network.download", #"{"url":"https://example.com/a","path":"a.bin"}"#),
            ("git.commit", #"{"message":"x"}"#),
            ("video.inspect", #"{"path":"in.mov"}"#),
            ("image.ocr", #"{"path":"a.png"}"#),
            // Unlisted actions of the covered mixed tools keep the policy.
            ("document.office.edit", #"{"action":"replaceImage","path":"a.docx"}"#),
            ("cad.document", #"{"action":"cancel","path":"part.floecad","task_id":"t"}"#),
            ("cad.document", #"{"action":"three_d_assembly","path":"part.floecad"}"#),
            ("image.svgDocument", #"{"operation":"edit","path":"a.svg","outputPath":"b.svg"}"#),
            ("document.pdf.edit", #"{"inputPath":"a.pdf","outputPath":"b.pdf"}"#)
        ] {
            let proposed = try action(
                tool, json, targets: [doc], workspace: tree.root.path
            )
            #expect(
                !DeterministicLocalApprovalPolicy.isExempt(proposed),
                "\(tool) \(json) must not be covered"
            )
        }
        // Contract-covered actions whose required destination is missing are
        // unresolved (the runtime records the wildcard extent).
        for (tool, json) in [
            ("document.pdf.edit", #"{"inputPath":"a.pdf"}"#),
            ("video.edit", #"{"input":"in.mov","operations":[],"exportSpec":{"container":"mp4"}}"#),
            ("media.project", #"{"action":"apply","proposal_id":"p"}"#)
        ] {
            let proposed = try action(
                tool, json, targets: [], unresolvedExtent: true, typedCovered: true
            )
            #expect(
                !DeterministicLocalApprovalPolicy.isExempt(proposed),
                "\(tool) \(json) must stay reviewed while its destination is unresolved"
            )
        }
        // Host-scoped calls are never local document edits.
        #expect(!DeterministicLocalApprovalPolicy.isExempt(try action(
            "document.office.edit", #"{"action":"apply","path":"a.docx","proposal_id":"p"}"#,
            scope: .host(UUID()), targets: [doc], typedCovered: true
        )))
    }

    @Test("Audited read/draft actions of the ordinary families run without a card")
    func auditedReadAndDraftActionsAreExempt() async throws {
        let repo = try makeTree(git: ("directory", "repo"))
        defer { repo.cleanup() }
        let plain = try makeTree()
        defer { plain.cleanup() }
        let projectID = UUID()

        // Read-only actions write nothing, so they are exempt even when the
        // inspected document lives INSIDE a repository: inspecting repository
        // content is not a repository write (the commit still keeps its card).
        let reads: [(String, String)] = [
            ("document.office.edit", #"{"action":"capabilities"}"#),
            ("document.office.edit", #"{"action":"query","path":"a.docx"}"#),
            ("document.office.edit", #"{"action":"read","path":"docs/a.docx"}"#),
            ("document.office.edit", #"{"action":"errors","path":"a.xlsx"}"#),
            ("document.office.edit", #"{"action":"preview","proposal_id":"p"}"#),
            ("media.project", #"{"action":"capabilities","project_id":"\#(projectID.uuidString)"}"#),
            ("media.project", #"{"action":"read","project_id":"\#(projectID.uuidString)"}"#),
            ("cad.document", #"{"action":"read","path":"part.dwg"}"#),
            ("cad.document", #"{"action":"query","path":"part.dwg","kind":"bodies"}"#),
            ("cad.document", #"{"action":"measure","path":"part.floecad","op":"body"}"#),
            ("cad.document", #"{"action":"status","path":"part.floecad"}"#),
            ("cad.document", #"{"action":"three_d_snapshot","path":"part.floecad"}"#),
            ("cad.document", #"{"action":"preview","path":"part.floecad","proposal_id":"p"}"#),
            ("image.svgDocument", #"{"operation":"inspect","path":"a.svg"}"#)
        ]
        for (tool, json) in reads {
            let proposed = try action(
                tool, json,
                targets: [repo.root.appendingPathComponent("docs/a.docx").path],
                workspace: repo.root.path
            )
            #expect(
                DeterministicLocalApprovalPolicy.isExempt(proposed),
                "\(tool) \(json) is an audited read and needs no card"
            )
            guard case .allow = try await HumanApprovalPolicy().decide(proposed) else {
                Issue.record("\(tool) \(json) must not reach the human card")
                continue
            }
            let backend = RecordingBackend()
            let automatic = AutomaticApprovalPolicy(backend: backend)
            #expect(!automatic.requiresModelReview(proposed),
                    "\(tool) \(json) must not consume an approval-model call")
        }

        // Drafts write internal proposal state only: exempt with a resolved
        // document (repository originals included — the draft writes no
        // original bytes), but never with an unresolved extent.
        for (tool, json) in [
            ("document.office.edit", #"{"action":"propose","path":"docs/a.docx","expected_sha256":"x"}"#),
            ("cad.document", #"{"action":"propose","path":"parts/a.floecad"}"#),
            ("cad.document", #"{"action":"three_d_propose","path":"parts/a.floecad","op":"feature.extrude"}"#),
            ("media.project", #"{"action":"propose","project_id":"\#(projectID.uuidString)"}"#)
        ] {
            let proposed = try action(
                tool, json,
                targets: [repo.root.appendingPathComponent("docs/a.docx").path],
                typedCovered: true,
                workspace: repo.root.path
            )
            #expect(
                DeterministicLocalApprovalPolicy.isExempt(proposed),
                "\(tool) \(json) is a draft and needs no card"
            )
        }
        // A draft whose declared target the runtime could not pin keeps the
        // existing policy (fail closed — e.g. the media store root missing).
        for (tool, json) in [
            ("document.office.edit", #"{"action":"propose","path":"docs/a.docx"}"#),
            ("media.project", #"{"action":"propose","project_id":"\#(projectID.uuidString)"}"#)
        ] {
            let proposed = try action(
                tool, json, targets: [], unresolvedExtent: true, typedCovered: true,
                workspace: plain.root.path
            )
            #expect(
                !DeterministicLocalApprovalPolicy.isExempt(proposed),
                "\(tool) \(json) must stay reviewed while its target is unresolved"
            )
        }

        // The migration is not a blanket: an UNLISTED action stays on the
        // existing policy (cad cancel mutates task state), and a host-scoped
        // read is never a local read.
        // `cancel` is NOT in the typed contract's covered action list, so the
        // runtime never marks this call typed-covered: the fixture must carry
        // the accurate trusted context (false), or it would claim a resolution
        // the real resolver never produces.
        #expect(!DeterministicLocalApprovalPolicy.isExempt(try action(
            "cad.document", #"{"action":"cancel","path":"part.floecad","task_id":"t"}"#,
            targets: [plain.root.appendingPathComponent("part.floecad").path], typedCovered: false
        )))
        #expect(!DeterministicLocalApprovalPolicy.isExempt(try action(
            "document.office.edit", #"{"action":"read","path":"a.docx"}"#,
            scope: .host(UUID())
        )))
        // A repository commit keeps the human card (the draft above did not
        // consume or widen anything).
        let commit = try action(
            "document.office.edit", #"{"action":"apply","path":"docs/a.docx","proposal_id":"p"}"#,
            targets: [repo.root.appendingPathComponent("docs/a.docx").path], typedCovered: true
        )
        guard case .escalateToHuman = try await HumanApprovalPolicy().decide(commit) else {
            Issue.record("A repository commit must keep the human card")
            return
        }
    }

    @Test("PDF consent operations keep their review")
    func protectedPDFActionsStayReviewed() async throws {
        for json in [
            #"{"inputPath":"a.pdf","outputPath":"b.pdf","userPasswordRef":"k"}"#,
            #"{"inputPath":"a.pdf","outputPath":"b.pdf","ownerPasswordRef":"k"}"#,
            #"{"inputPath":"a.pdf","outputPath":"b.pdf","operations":[{"action":"rasterRedact","acceptRasterization":true}]}"#,
            #"{"inputPath":"a.pdf","outputPath":"b.pdf","operations":[{"action":"flattenAnnotations","acceptFlattening":true}]}"#,
            #"{"inputPath":"a.pdf","outputPath":"b.pdf","operations":[{"action":"searchableOCR","acceptRasterization":true}]}"#
        ] {
            // The call WOULD be covered (resolved output), but the consent
            // operation keeps the review regardless.
            let proposed = try action("document.pdf.edit", json, typedCovered: true)
            #expect(
                !DeterministicLocalApprovalPolicy.isExempt(proposed),
                "PDF \(json) must keep its review"
            )
            let backend = RecordingBackend()
            let automatic = AutomaticApprovalPolicy(backend: backend)
            #expect(automatic.requiresModelReview(proposed))
        }
    }

    @Test("A single-use document allow never widens the next call")
    func documentAllowDoesNotWidenLaterCalls() async throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let allowed = try action(
            "document.office.edit", #"{"action":"apply","path":"a.docx","proposal_id":"p"}"#,
            targets: [tree.root.appendingPathComponent("a.docx").path],
            typedCovered: true
        )
        #expect(DeterministicLocalApprovalPolicy.isExempt(allowed))
        guard case .allow(let scope, _) = DeterministicLocalApprovalPolicy.allowDecision(for: allowed)! else {
            Issue.record("Expected a single-use allow")
            return
        }
        #expect(scope.singleUse)
        // A different call is re-decided and not exempt: the earlier allow
        // never widens. The fixture carries the ACTUAL context of a PDF edit
        // with no resolvable destination (unresolved extent, no pinned
        // target), exactly what the runtime derives for this payload.
        let redirected = try action(
            "document.pdf.edit", #"{"inputPath":"a.pdf"}"#,
            targets: [],
            unresolvedExtent: true,
            typedCovered: true
        )
        #expect(!DeterministicLocalApprovalPolicy.isExempt(redirected))
    }

    // MARK: - Local Linux guest commands

    private func shell(
        _ command: String,
        environment: ApprovalEnvironmentClass,
        workspace: String?
    ) throws -> ProposedAction {
        let data = try JSONSerialization.data(withJSONObject: ["command": command])
        return try action(
            "exec.shell",
            String(decoding: data, as: UTF8.self),
            environment: environment,
            workspace: workspace
        )
    }

    @Test("Strictly read-only guest commands run without review; ambiguous verbs do not")
    func localGuestReadOnlyBoundaries() async throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let workspace = tree.root.path

        for command in [
            "ls -la", "pwd", "python3 --version", "git status && git diff --stat",
            "cat notes.txt", "grep -n todo notes.txt", "wc -l notes.txt",
            "date", "date +%s", "head -n 5 notes.txt",
            // Bare/query-only hostname is a diagnostic; ref queries that do
            // not rewrite HEAD and pattern searches without a pager stay
            // read-only.
            "hostname", "hostname -s", "hostname --short",
            "git symbolic-ref --short HEAD", "git symbolic-ref -q HEAD",
            "git grep -n todo notes.txt"
        ] {
            let proposed = try shell(command, environment: .localLinuxVM, workspace: workspace)
            #expect(
                DeterministicLocalApprovalPolicy.isExempt(proposed),
                "guest read-only command must be exempt: \(command)"
            )
        }
        // Verbs whose common flags write or execute are NOT read-only, and
        // ambiguous verbs were removed from the vocabulary entirely.
        for command in [
            "sed -n 'w out' input", "sort -o out input", "uniq input out",
            "diff --output=out a b", "rg --pre cmd pattern", "file -C -m magic",
            "tree -o out", "tee out", "column -t in",
            "python script.py --version",
            "python3 -m json.tool in.json out.json",
            "cat /etc/passwd", "cat ../outside", "find . -delete",
            "ls -o", "date -s 2020-01-01", "date --set=2020-01-01",
            // hostname with an operand/`-F`/`-b` SETS the host name; a
            // symbolic-ref with a second operand (or -d/-m) rewrites HEAD;
            // a pager flag EXECUTES a program.
            "hostname floe-renamed", "hostname -F etc-hosts", "hostname -b floe",
            "git symbolic-ref HEAD refs/heads/evil", "git symbolic-ref -d HEAD",
            "git symbolic-ref -m msg HEAD refs/heads/x",
            "git grep --open-files-in-pager=cat pattern",
            "git grep -Ocat pattern", "git grep -nOcat pattern"
        ] {
            let proposed = try shell(command, environment: .localLinuxVM, workspace: workspace)
            #expect(
                !DeterministicLocalApprovalPolicy.isExempt(proposed),
                "ambiguous or mutating guest command must keep the existing policy: \(command)"
            )
        }
        for command in [
            "rm -rf build", "mv a b", "echo hi > out.txt", "python3 -c 'print(1)'",
            "curl https://example.com", "sudo swift build", "npm install left-pad",
            "git commit -m x", "swift build && rm -rf out", "swift build || true"
        ] {
            let proposed = try shell(command, environment: .localLinuxVM, workspace: workspace)
            #expect(
                !DeterministicLocalApprovalPolicy.isExempt(proposed),
                "guest command must keep the existing policy: \(command)"
            )
        }
    }

    @Test("Routine build/test forms are exempt only for the guest and only outside a repository")
    func localGuestRoutineWorkspaceBoundary() async throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let repo = try makeTree(git: ("directory", "r"))
        defer { repo.cleanup() }

        // `node script.js` is a ROUTINE script run (code execution by
        // design), never a read-only diagnostic.
        for command in ["swift build -c release", "swift test --filter X", "pytest -q",
                        "python3 -m pytest", "make", "cargo test", "npm test",
                        "ruff check .", "black --check .", "gofmt -l .", "go vet ./...",
                        "node script.js --version"] {
            #expect(
                DeterministicLocalApprovalPolicy.isExempt(
                    try shell(command, environment: .localLinuxVM, workspace: tree.root.path)
                ),
                "routine command outside a repository must be exempt: \(command)"
            )
            #expect(
                !DeterministicLocalApprovalPolicy.isExempt(
                    try shell(command, environment: .localLinuxVM, workspace: repo.root.path)
                ),
                "routine command inside a repository must keep the existing policy: \(command)"
            )
        }
        // Write-flavoured variants keep the existing policy.
        for command in ["black .", "ruff format .", "gofmt -w f.go", "go fmt ./...",
                        "swift format -i f.swift", "rubocop -a", "prettier --write .",
                        "eslint --fix .", "make clean", "swift package reset"] {
            #expect(
                !DeterministicLocalApprovalPolicy.isExempt(
                    try shell(command, environment: .localLinuxVM, workspace: tree.root.path)
                ),
                "write-flavoured routine command must keep the existing policy: \(command)"
            )
        }
        // Read-only commands stay exempt even in a repository workspace.
        #expect(
            DeterministicLocalApprovalPolicy.isExempt(
                try shell("ls -la", environment: .localLinuxVM, workspace: repo.root.path)
            )
        )
    }

    @Test("Native, remote, unknown and unrelated environments keep the existing policy")
    func environmentScopeIsRequired() async throws {
        let tree = try makeTree()
        defer { tree.cleanup() }

        for environment in [ApprovalEnvironmentClass.localNative, .unknown, .remote] {
            let proposed = try shell("ls -la", environment: environment, workspace: tree.root.path)
            #expect(!DeterministicLocalApprovalPolicy.isExempt(proposed))
        }
        #expect(
            !DeterministicLocalApprovalPolicy.isExempt(
                try action(
                    "shell.exchange", #"{"sessionID":"s","input":"ls\n"}"#,
                    environment: .localLinuxVM, workspace: tree.root.path
                )
            )
        )
        #expect(
            !DeterministicLocalApprovalPolicy.isExempt(
                try action(
                    "shell.open", "{}",
                    environment: .localLinuxVM, workspace: tree.root.path
                )
            )
        )
        #expect(
            !DeterministicLocalApprovalPolicy.isExempt(
                try action(
                    "shell.open", #"{"command":"python3 script.py"}"#,
                    environment: .localLinuxVM, workspace: tree.root.path
                )
            )
        )
        #expect(
            DeterministicLocalApprovalPolicy.isExempt(
                try action(
                    "shell.open", #"{"command":"ls -la"}"#,
                    environment: .localLinuxVM, workspace: tree.root.path
                )
            )
        )
        #expect(
            !DeterministicLocalApprovalPolicy.isExempt(
                try action(
                    "exec.localPython", #"{"script":"print(1)"}"#,
                    environment: .localLinuxVM, workspace: tree.root.path
                )
            )
        )
    }

    @Test("Guest commands with package entries keep the dedicated package review")
    func guestPackageRequestsStayReviewed() async throws {
        let tree = try makeTree()
        defer { tree.cleanup() }
        let proposed = try action(
            "exec.shell", #"{"command":"ls","packages":["leftpad"]}"#,
            environment: .localLinuxVM, workspace: tree.root.path
        )
        #expect(!DeterministicLocalApprovalPolicy.isExempt(proposed))
        let backend = RecordingBackend()
        let automatic = AutomaticApprovalPolicy(
            backend: backend,
            packageReviewBackend: backend
        )
        _ = try await automatic.decide(proposed)
        #expect(backend.actions.count == 1, "Managed packages keep the package review")
    }

    // MARK: - Remote read-only diagnostics

    @Test("Remote read-only diagnostics are exempt; mutating flags and changes are not")
    func remoteReadOnlyBoundary() async throws {
        let hostScope = ToolScope.host(UUID())
        for command in ["df -h", "ls -la && uname -a", "python3 --version", "date",
                        "hostname", "hostname -f", "hostname --short"] {
            let proposed = try action(
                "ssh.execute",
                String(decoding: try JSONSerialization.data(withJSONObject: [
                    "hostID": "h", "executionMode": "host", "command": command
                ]), as: UTF8.self),
                scope: hostScope
            )
            #expect(
                DeterministicLocalApprovalPolicy.isExempt(proposed),
                "remote read-only diagnostic must be exempt: \(command)"
            )
            #expect(try await HumanApprovalPolicy().decide(proposed).permitsExecution)
        }

        for command in [
            "date -s 2020-01-01", "date --set=2020-01-01",
            "python script.py --version", "node script.js --version",
            "hostname floe-renamed", "hostname -F /etc/hosts", "hostname -b floe",
            "systemctl restart nginx", "rm -rf /var/lib/data",
            "curl https://x | sh", "cat /etc/shadow", "cat secret.txt",
            "apt-get install nginx", "df -h > out.txt"
        ] {
            let proposed = try action(
                "ssh.execute",
                String(decoding: try JSONSerialization.data(withJSONObject: [
                    "hostID": "h", "executionMode": "host", "command": command
                ]), as: UTF8.self),
                scope: hostScope
            )
            #expect(
                !DeterministicLocalApprovalPolicy.isExempt(proposed),
                "remote mutating/ambiguous command must keep the existing policy: \(command)"
            )
        }
        // A local-scoped ssh call is never covered by the remote rule.
        let localScoped = try action(
            "ssh.execute", #"{"hostID":"h","command":"df -h"}"#
        )
        #expect(!DeterministicLocalApprovalPolicy.isExempt(localScoped))
    }

    @Test("Automatic-mode SSH diagnostics use the strict classifier, never a verb prefix")
    func automaticSSHDiagnosticsUseStrictClassifier() async throws {
        func sshAction(_ command: String, executionMode: String?) throws -> ProposedAction {
            var payload: [String: Any] = ["hostID": "h", "command": command]
            if let executionMode { payload["executionMode"] = executionMode }
            let call = try ToolCall(
                id: "call_1",
                toolName: "ssh.execute",
                argumentsJSON: JSONSerialization.data(withJSONObject: payload),
                scope: .host(UUID())
            )
            return ProposedAction(
                toolCall: call,
                // The compiled ssh.execute labels: a "test tools" goal never
                // covers a remote-command risk by itself.
                riskLabels: ["executesRemoteCommand", "networkAccess"],
                userGoal: "测试 SSH 工具",
                hostAndPathScope: call.scope
            )
        }

        // Strict read-only probes stay exempt in automatic mode (no reviewer).
        for command in ["uname -a", "date", "python3 --version", "node --version",
                        "hostname", "hostname -f", "git --version"] {
            for mode in [Optional("automatic"), Optional(nil)] {
                let proposed = try sshAction(command, executionMode: mode)
                let backend = RecordingBackend()
                let automatic = AutomaticApprovalPolicy(backend: backend)
                #expect(!automatic.requiresModelReview(proposed),
                        "\(command) must not require review")
                let decision = try await automatic.decide(proposed)
                #expect(decision.permitsExecution, "\(command) must be allowed")
                #expect(backend.actions.isEmpty, "no reviewer call for \(command)")
            }
        }

        // Mutating / ambiguous look-alikes must consult the reviewer in
        // automatic mode: the old verb-prefix list exempted these.
        for command in ["date -s 2020-01-01", "date --set=2020-01-01",
                        "python script.py --version", "node script.js --version",
                        "hostname floe-renamed", "lssomething"] {
            let proposed = try sshAction(command, executionMode: "automatic")
            let backend = RecordingBackend(decision: .deny(reason: "mutating"))
            let automatic = AutomaticApprovalPolicy(backend: backend)
            #expect(automatic.requiresModelReview(proposed),
                    "\(command) must be reviewed in automatic mode")
            let decision = try await automatic.decide(proposed)
            #expect(!decision.permitsExecution, "\(command) must not pass")
            #expect(backend.actions.count == 1, "the reviewer must see \(command)")
        }

        // The default (no executionMode) path is the same automatic route.
        let defaulted = try sshAction("date -s 2020-01-01", executionMode: nil)
        let defaultBackend = RecordingBackend(decision: .deny(reason: "mutating"))
        #expect(AutomaticApprovalPolicy(backend: defaultBackend).requiresModelReview(defaulted))

        // An explicit container run is unchanged: the caller selected the
        // disposable environment, so the bounded command stays exempt.
        let container = try sshAction("date -s 2020-01-01", executionMode: "container")
        #expect(!AutomaticApprovalPolicy(backend: RecordingBackend()).requiresModelReview(container))
    }

    // MARK: - Regression: existing behavior preserved

    @Test("Existing automatic exemptions and PDF consent rules are unchanged")
    func existingExemptionsRemain() async throws {
        // workspace.writeFile keeps its existing automatic exemption (not a
        // new carve-out) and its ask-mode human card.
        let write = try action("workspace.writeFile", #"{"path":"a.txt","content":"x"}"#)
        #expect(!DeterministicLocalApprovalPolicy.isExempt(write))
        #expect(try await AutomaticApprovalPolicy().decide(write).permitsExecution)
        guard case .escalateToHuman = try await HumanApprovalPolicy().decide(write) else {
            Issue.record("ask mode must keep the human card for workspace.writeFile")
            return
        }
        // The PDF consent gate still escalates even under automatic mode.
        let redact = try action(
            "document.pdf.edit",
            #"{"inputPath":"a.pdf","outputPath":"b.pdf","operations":[{"action":"rasterRedact","acceptRasterization":true}]}"#
        )
        guard case .escalateToHuman = try await AutomaticApprovalPolicy().decide(redact) else {
            Issue.record("PDF rasterRedact must keep the consent review")
            return
        }
        // Historical exact Python audit data still decodes and matches here.
        // The runtime rejects its retired tool name; this is NOT a grant to exec.shell.
        let script = "print(1)"
        let preapproved = ProposedAction(
            toolCall: try ToolCall(
                id: "c9",
                toolName: "exec.localPython",
                argumentsJSON: Data(#"{"script":"print(1)"}"#.utf8),
                scope: .local
            ),
            riskLabels: ["executesLocalCode"],
            userGoal: "run the audited skill script",
            hostAndPathScope: .local,
            preapprovedPythonScriptSHA256: [FloeDigest.sha256Hex(Data(script.utf8))]
        )
        #expect(try await HumanApprovalPolicy().decide(preapproved).permitsExecution)
        var shell = preapproved
        shell.toolCall = try ToolCall(id: "shell-no-legacy-bypass", toolName: "exec.shell",
            argumentsJSON: Data(#"{"command":"python3 -c 'print(1)'"}"#.utf8), scope: .local)
        guard case .escalateToHuman = try await HumanApprovalPolicy().decide(shell) else {
            Issue.record("Legacy Python fingerprints must not authorize Linux Shell without trusted task context")
            return
        }
    }
}
