// FloeToolsTests — fast conversation (.chat) capability ceiling.
//
// `ChatToolPolicy` admits exactly two families for ORDINARY fast chat runs:
// the audited public web trio (shared names + argument checks with the
// temporary ceiling) and reads of THIS conversation's attached files at the
// exact frozen workspace-relative paths. Everything else fails closed, and
// descriptor metadata is revalidated at every decision so a dynamic, stale
// or forged descriptor reusing an allowed name cannot enter. The temporary
// public-web-only ceiling is a separate, stricter policy and untouched here.

import Foundation
import Testing
@testable import FloeTools

@Suite("FloeTools.ChatToolPolicy")
struct ChatToolPolicyTests {

    // MARK: - Fixtures

    private func descriptor(
        _ name: String,
        riskLabels: Set<RiskLabel>,
        isSideEffecting: Bool = false,
        effect: ToolEffect? = nil,
        requiresHostScope: Bool = false,
        executionBoundary: ToolExecutionBoundary = .any
    ) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            riskLabels: riskLabels,
            isSideEffecting: isSideEffecting,
            effect: effect,
            requiresHostScope: requiresHostScope,
            executionBoundary: executionBoundary
        )
    }

    private func web(_ name: String, mutating: Bool = false) -> ToolCatalog.Descriptor {
        descriptor(name,
                   riskLabels: mutating ? [.networkAccess, .writesFiles] : [.networkAccess],
                   isSideEffecting: mutating)
    }

    private func fileRead(_ name: String, extra: Set<RiskLabel> = []) -> ToolCatalog.Descriptor {
        descriptor(name, riskLabels: Set<RiskLabel>([.readsFiles]).union(extra), isSideEffecting: !extra.isEmpty)
    }

    private let conversationID = UUID()
    private let boundID = UUID()
    private var boundPath: String { "Attachments/\(boundID.uuidString)/notes.txt" }

    private func context(paths: [String]) -> ChatToolPolicy.ResourceContext {
        ChatToolPolicy.ResourceContext(conversationID: conversationID, boundRelativePaths: paths)
    }

    private var boundContext: ChatToolPolicy.ResourceContext { context(paths: [boundPath]) }

    private func arguments(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Public web family

    @Test("the three public web tools pass with plain arguments")
    func publicWebToolsAllowed() {
        for name in ["web.search", "web.searchAI", "web.fetch"] {
            #expect(ChatToolPolicy.denialReason(
                descriptor: web(name), arguments: arguments(#"{"query":"x"}"#),
                resourceContext: boundContext) == nil, Comment(rawValue: name))
            #expect(ChatToolPolicy.isPublicWebTool(name))
            #expect(ChatToolPolicy.isAllowedName(name))
        }
        // No attachments at all still leaves the web family.
        #expect(ChatToolPolicy.denialReason(
            descriptor: web("web.fetch"), arguments: arguments(#"{"url":"https://example.com"}"#),
            resourceContext: nil) == nil)
    }

    @Test("web.fetch LAN/diagnostic opt-in is refused")
    func webFetchLocalNetworkDenied() {
        let reason = ChatToolPolicy.denialReason(
            descriptor: web("web.fetch"),
            arguments: arguments(#"{"url":"http://192.168.1.1","localNetwork":true}"#),
            resourceContext: nil)
        #expect(reason?.contains("local-network") == true, Comment(rawValue: reason ?? "nil"))
    }

    @Test("a forged web descriptor (write metadata under a web name) fails closed")
    func webDescriptorForgeFails() {
        let forged = web("web.fetch", mutating: true)
        #expect(ChatToolPolicy.isSafeWebDescriptor(forged) == false)
        let reason = ChatToolPolicy.denialReason(
            descriptor: forged, arguments: arguments(#"{"url":"https://example.com"}"#),
            resourceContext: nil)
        #expect(reason?.contains("not a public read-only web tool") == true, Comment(rawValue: reason ?? "nil"))
    }

    @Test("a non-JSON-object web call fails closed")
    func webBadArgumentsDenied() {
        let reason = ChatToolPolicy.denialReason(
            descriptor: web("web.search"), arguments: arguments("[1,2]"),
            resourceContext: nil)
        #expect(reason?.contains("JSON object") == true, Comment(rawValue: reason ?? "nil"))
    }

    // MARK: - Bound file-read family

    @Test("reads of a bound attachment path pass")
    func boundFileReadAllowed() {
        for name in ChatToolPolicy.boundFileReadToolNames {
            let reason = ChatToolPolicy.denialReason(
                descriptor: fileRead(name),
                arguments: arguments(#"{"path":"\#(boundPath)"}"#),
                resourceContext: boundContext)
            #expect(reason == nil, Comment(rawValue: name))
        }
    }

    @Test("image.ocr may run on inline base64 instead of a path")
    func inlineOcrAllowed() {
        #expect(ChatToolPolicy.denialReason(
            descriptor: fileRead("image.ocr"),
            arguments: arguments(#"{"imageBase64":"aGVsbG8="}"#),
            resourceContext: boundContext) == nil)
        // Empty inline data is not evidence: it still needs a bound path.
        #expect(ChatToolPolicy.denialReason(
            descriptor: fileRead("image.ocr"),
            arguments: arguments(#"{"imageBase64":""}"#),
            resourceContext: boundContext) != nil)
    }

    @Test("file reads without any frozen resource context fail closed")
    func noContextFailsClosed() {
        for resourceContext in [nil, context(paths: [])] {
            let reason = ChatToolPolicy.denialReason(
                descriptor: fileRead("workspace.readFile"),
                arguments: arguments(#"{"path":"\#(boundPath)"}"#),
                resourceContext: resourceContext)
            #expect(reason?.contains("no attached files") == true, "\(reason ?? "nil")")
        }
        // Inline OCR is still a file-family call: no context, no admission.
        #expect(ChatToolPolicy.denialReason(
            descriptor: fileRead("image.ocr"),
            arguments: arguments(#"{"imageBase64":"aGk="}"#),
            resourceContext: nil) != nil)
    }

    @Test("unbound, traversal, absolute and tilde paths are refused, not normalized into access")
    func pathAttacksDenied() {
        let other = UUID()
        for bad in [
            "workspace/secret.txt",                                 // unbound
            "Attachments/\(other.uuidString)/notes.txt",             // other conversation
            "Attachments/\(boundID.uuidString)/../other.txt",        // traversal
            "../../etc/passwd",
            "/etc/passwd",
            "~/notes.txt",
            "",
            "Attachments/\(boundID.uuidString)",                     // directory, not file
        ] {
            let reason = ChatToolPolicy.denialReason(
                descriptor: fileRead("workspace.readFile"),
                arguments: arguments(#"{"path":"\#(bad)"}"#),
                resourceContext: boundContext)
            #expect(reason != nil, "must deny: '\(bad)'")
        }
    }

    @Test("host-scoped and non-read file calls are refused")
    func scopeAndActionDenied() {
        let hostID = UUID().uuidString
        let scoped = ChatToolPolicy.denialReason(
            descriptor: fileRead("workspace.readFile"),
            arguments: arguments(#"{"path":"\#(boundPath)","scope":{"hostID":"\#(hostID)"}}"#),
            resourceContext: boundContext)
        #expect(scoped?.contains("host scope") == true, Comment(rawValue: scoped ?? "nil"))

        // Multi-action calls fail closed: the current allow map has NO entry,
        // so any `action` argument — even one naming an ordinary read — is
        // refused until the policy explicitly declares that read action.
        let actioned = ChatToolPolicy.denialReason(
            descriptor: fileRead("workspace.readFile"),
            arguments: arguments(#"{"action":"read","path":"\#(boundPath)"}"#),
            resourceContext: boundContext)
        #expect(actioned?.contains("read action") == true, Comment(rawValue: actioned ?? "nil"))
        // A non-string action fails closed too (never coerced).
        #expect(ChatToolPolicy.denialReason(
            descriptor: fileRead("workspace.readFile"),
            arguments: arguments(#"{"action":3,"path":"\#(boundPath)"}"#),
            resourceContext: boundContext) != nil)
    }

    @Test("a file read name with forged broad metadata fails closed")
    func fileDescriptorForgeFails() {
        // Extra risk label + side effect under a genuine read-tool name.
        let forged = fileRead("workspace.readFile", extra: [.writesFiles])
        #expect(ChatToolPolicy.isSafeBoundFileReadDescriptor(forged) == false)
        #expect(ChatToolPolicy.denialReason(
            descriptor: forged,
            arguments: arguments(#"{"path":"\#(boundPath)"}"#),
            resourceContext: boundContext)?.contains("not a pure local read") == true)
        // Child-only boundary under an allowed name never enters.
        let childOnly = descriptor("workspace.readFile", riskLabels: [.readsFiles],
                                   executionBoundary: .childOnly)
        #expect(ChatToolPolicy.isSafeBoundFileReadDescriptor(childOnly) == false)
        // Host-scoped variant is refused.
        let hostScoped = descriptor("image.ocr", riskLabels: [.readsFiles], requiresHostScope: true)
        #expect(ChatToolPolicy.isSafeBoundFileReadDescriptor(hostScoped) == false)
    }

    // MARK: - Everything else

    @Test("execution, mutation, discovery, personal data and delegation names are outside the ceiling")
    func nonCeilingNamesDenied() {
        let deniedCatalog: [(String, Set<RiskLabel>, Bool)] = [
            ("exec.shell", Set<RiskLabel>([.executesLocalCode]), true),
            ("workspace.writeFile", Set<RiskLabel>([.writesFiles]), true),
            ("workspace.listDirectory", Set<RiskLabel>([.readsFiles]), false),
            ("workspace.searchFiles", Set<RiskLabel>([.readsFiles]), false),
            ("tools.search", Set<RiskLabel>(), false),
            ("tools.list", Set<RiskLabel>(), false),
            ("skill.read", Set<RiskLabel>(), false),
            ("memory.search", Set<RiskLabel>([.persistsPersonalData]), false),
            ("notes.read", Set<RiskLabel>([.readsFiles]), false),
            ("apple.contacts.read", Set<RiskLabel>(), false),
            ("conversation.history", Set<RiskLabel>(), false),
            ("browser.open", Set<RiskLabel>([.networkAccess, .controlsGUI]), true),
            ("delegate.task", Set<RiskLabel>(), true),
            ("job.create", Set<RiskLabel>(), true),
            ("task.schedule", Set<RiskLabel>(), true),
            ("credential.read", Set<RiskLabel>([.accessesCredentials]), false),
            ("ssh.exec", Set<RiskLabel>([.executesRemoteCommand]), true),
            ("http.get", Set<RiskLabel>([.networkAccess]), false),
            ("media.generate", Set<RiskLabel>([.networkAccess]), true),
            ("cad.document.edit", Set<RiskLabel>([.writesFiles]), true),
        ]
        for (name, labels, sideEffecting) in deniedCatalog {
            let d = descriptor(name, riskLabels: labels, isSideEffecting: sideEffecting)
            #expect(ChatToolPolicy.isAllowedName(name) == false, Comment(rawValue: name))
            #expect(ChatToolPolicy.isSafeDescriptor(d) == false, Comment(rawValue: name))
            let reason = ChatToolPolicy.denialReason(
                descriptor: d, arguments: arguments(#"{"path":"\#(boundPath)"}"#),
                resourceContext: boundContext)
            #expect(reason?.contains("outside the fast chat") == true, "\(name): \(reason ?? "nil")")
        }
    }

    @Test("retired/alias names cannot re-widen: admission is the exact name set")
    func aliasNamesDenied() {
        for alias in ["web.fetchAll", "websearch", "workspace.read", "readFile", "web.fetch2"] {
            #expect(ChatToolPolicy.isAllowedName(alias) == false, Comment(rawValue: alias))
            #expect(ChatToolPolicy.denialReason(
                descriptor: descriptor(alias, riskLabels: [.networkAccess]),
                arguments: arguments("{}"), resourceContext: boundContext) != nil)
        }
    }

    // MARK: - ResourceContext normalization

    @Test("normalization matches dot segments but rejects absolute, tilde and traversal paths")
    func resourceContextNormalization() {
        #expect(ChatToolPolicy.ResourceContext.normalize(boundPath) == boundPath)
        #expect(ChatToolPolicy.ResourceContext.normalize("./Attachments//\(boundID.uuidString)/notes.txt")
                == boundPath)
        #expect(ChatToolPolicy.ResourceContext.normalize("/etc/passwd") == nil)
        #expect(ChatToolPolicy.ResourceContext.normalize("~/x") == nil)
        #expect(ChatToolPolicy.ResourceContext.normalize("a/../../b") == nil)
        #expect(ChatToolPolicy.ResourceContext.normalize("   ") == nil)
        #expect(ChatToolPolicy.ResourceContext.normalize("a/../..") == nil)
        let bound = boundContext
        #expect(bound.contains(boundPath))
        #expect(bound.contains("./\(boundPath)"))
        // Duplicate separators and `.` segments collapse to the same bound file.
        #expect(bound.contains("Attachments/\(boundID.uuidString)//notes.txt"))
        // A `..` component is a traversal, not a matchable alias: the
        // documented normalization rejects any parent reference outright
        // instead of folding it into a containment match
        // (`ChatToolPolicy.ResourceContext.normalize`).
        #expect(bound.contains("Attachments/\(boundID.uuidString)/sub/../notes.txt") == false)
        #expect(bound.contains(boundPath + ".bak") == false)
        // Construction rejects garbage but keeps the valid members.
        let mixed = context(paths: [boundPath, "/tmp/x", "..", "~/y"])
        #expect(mixed.boundRelativePaths == [boundPath])
        #expect(context(paths: ["", "/"]).isEmpty)
    }

    // MARK: - Offered projection

    @Test("the offered projection hides file reads when the chat has no attachments")
    func offeredProjectionHidesFileReadsWithoutResources() {
        for name in ChatToolPolicy.boundFileReadToolNames {
            #expect(ChatToolPolicy.offeredDescriptor(fileRead(name), hasResourceContext: false) == nil, Comment(rawValue: name))
            #expect(ChatToolPolicy.offeredDescriptor(fileRead(name), hasResourceContext: true) != nil, Comment(rawValue: name))
        }
        #expect(ChatToolPolicy.offeredDescriptor(web("web.fetch"), hasResourceContext: false) != nil)
        #expect(ChatToolPolicy.offeredDescriptor(web("web.fetch", mutating: true), hasResourceContext: true) == nil)
        #expect(ChatToolPolicy.offeredDescriptor(descriptor("exec.shell", riskLabels: [.executesLocalCode],
                                                          isSideEffecting: true),
                                                 hasResourceContext: true) == nil)
    }

    @Test("derived name ceiling is exactly web (no resources) or web+bound reads (with resources)")
    func derivedNameCeiling() {
        let catalog = [
            web("web.search"), web("web.searchAI"), web("web.fetch"),
            fileRead("workspace.readFile"), fileRead("image.ocr"),
            fileRead("workspace.readFile", extra: [.writesFiles]),  // forged
            descriptor("workspace.writeFile", riskLabels: [.writesFiles], isSideEffecting: true),
            descriptor("exec.shell", riskLabels: [.executesLocalCode], isSideEffecting: true),
            descriptor("workspace.searchFiles", riskLabels: [.readsFiles]),
        ]
        #expect(ChatToolPolicy.allowedToolNames(from: catalog, hasResourceContext: false)
                == ["web.search", "web.searchAI", "web.fetch"])
        #expect(ChatToolPolicy.allowedToolNames(from: catalog, hasResourceContext: true)
                == ["web.search", "web.searchAI", "web.fetch", "workspace.readFile", "image.ocr"])
        // The shared public-web name set is literally the temporary one.
        #expect(ChatToolPolicy.publicWebToolNames == TemporaryChatToolPolicy.publicWebToolNames)
    }

    @Test("Fast chat denies professional source without changing public web calls")
    func professionalSourceDenied() {
        let reason = ChatToolPolicy.denialReason(
            descriptor: web("web.search"),
            arguments: arguments(#"{"query":"学术文献","source":"professional"}"#),
            resourceContext: nil)
        #expect(reason?.contains("public web search only") == true)
        for json in [#"{"query":"weather"}"#, #"{"query":"weather","source":"web"}"#] {
            #expect(ChatToolPolicy.denialReason(
                descriptor: web("web.search"), arguments: arguments(json),
                resourceContext: nil) == nil)
        }
    }

    @Test("denial copy is actionable and never grants anything")
    func denialCopyIsActionable() {
        let reason = ChatToolPolicy.denialReason(
            descriptor: fileRead("workspace.readFile"),
            arguments: arguments(#"{"path":"elsewhere.txt"}"#),
            resourceContext: boundContext) ?? ""
        #expect(reason.contains("not attached to this conversation"))
        #expect(reason.contains("task mode"))
        let hint = ChatToolPolicy.denialReason(
            descriptor: descriptor("exec.shell", riskLabels: [.executesLocalCode], isSideEffecting: true),
            arguments: arguments("{}"), resourceContext: nil) ?? ""
        #expect(hint.contains("Allowed here:") && hint.contains("web.fetch"))
    }
}
