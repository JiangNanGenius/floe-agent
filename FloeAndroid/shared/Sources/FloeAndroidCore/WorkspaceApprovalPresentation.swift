// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeAgentRuntime
import FloeModels
import FloeWorkspace
import FloeBrowser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

/// Retaining an open directory prevents a deleted inode from being reused as
/// a false match while this run is alive. This does not lock future writes.
final class WorkspaceApprovalRootHandle: @unchecked Sendable {
    private let fd: Int32
    private let device: UInt64
    private let inode: UInt64

    init?(root: URL) {
        let path = root.standardizedFileURL.path
        let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { return nil }
        var info = stat(), named = stat()
        guard fstat(opened, &info) == 0, lstat(path, &named) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (named.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_dev == named.st_dev, info.st_ino == named.st_ino else {
            close(opened); return nil
        }
        fd = opened
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
    }

    func matches(root: URL) -> Bool {
        var held = stat(), named = stat()
        return fstat(fd, &held) == 0 && lstat(root.standardizedFileURL.path, &named) == 0 &&
            (held.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) &&
            (named.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) &&
            UInt64(held.st_dev) == device && UInt64(held.st_ino) == inode &&
            UInt64(named.st_dev) == device && UInt64(named.st_ino) == inode
    }

    deinit { close(fd) }
}

/// Actor-owned, process-only capability records. Values contain no path,
/// arguments or content; no state here is written to a log or durable store.
struct WorkspaceApprovalReceiptStore {
    struct Binding: Equatable {
        let epoch: UInt64
        let taskID: UUID
        let runID: UUID
        let callID: String
        let generation: UUID
        let descriptorIdentity: String
        let workspaceProof: WorkspaceApprovalLaunchProof?
        let digest: String
        var shellTarget: C02ResolvedExecutionTarget? = nil
        var deviceTargetDigest: String? = nil
        var browserTabProof: BrowserTabApprovalProof? = nil
    }
    struct Claim {
        let binding: Binding
        let expiresAt: TimeInterval
    }
    private var entries: [String: Claim] = [:]
    private static let lifetime: TimeInterval = 600
    private static let maximumEntries = 128

    mutating func issue(_ binding: Binding, now: TimeInterval) -> String? {
        entries = entries.filter { $0.value.expiresAt > now &&
            !($0.value.binding.taskID == binding.taskID && $0.value.binding.runID == binding.runID &&
              $0.value.binding.callID == binding.callID) }
        guard entries.count < Self.maximumEntries else { return nil }
        let token = UUID().uuidString.lowercased()
        entries[token] = Claim(binding: binding, expiresAt: now + Self.lifetime)
        return token
    }

    /// Remove before any asynchronous revalidation, so concurrent taps cannot
    /// carry the same capability across an actor suspension.
    mutating func take(_ token: String, now: TimeInterval) -> Claim? {
        guard let receipt = entries.removeValue(forKey: token) else { return nil }
        return receipt.expiresAt > now ? receipt : nil
    }

    mutating func consume(_ token: String, matching binding: Binding, now: TimeInterval) -> Bool {
        take(token, now: now)?.binding == binding
    }

    mutating func retire(runID: UUID) {
        entries = entries.filter { $0.value.binding.runID != runID }
    }
}

/// Read-only display proof, never an authorization or file mutation.
enum WorkspaceApprovalPresentation {
    typealias Value = SettingsDomainV1.JSONValue
    static let toolNames: Set<String> = [
        "workspace.createFile", "workspace.writeFile", "workspace.applyPatch",
        "workspace.appendFile", "workspace.replaceText", "workspace.createDirectory",
        "workspace.moveFile", "workspace.copyFile", "workspace.deleteFile",
    ]

    /// Bind both the complete captured request and every visible detail. The
    /// digests stay in process memory and never authorize a model path.
    static func bindingDigest(waiting: AgentState.WaitingApproval, details: [String: Value]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let request = try? encoder.encode(waiting),
              let rendered = try? JSONSerialization.data(withJSONObject: FacadeRunDomain.unwrap(.object(details)),
                                                          options: [.sortedKeys]) else { return nil }
        let joined = RunWireDigest.sha256Hex(request) + ":" + RunWireDigest.sha256Hex(rendered)
        return RunWireDigest.sha256Hex(Data(joined.utf8))
    }

    static func details(
        waiting: AgentState.WaitingApproval,
        launch: WorkspaceApprovalLaunchProof?,
        current: (workspaceID: UUID, conversationID: UUID, rootURL: URL)?,
        conversationID: UUID
    ) -> [String: Value]? {
        guard case .local = waiting.toolCall.scope,
              let launch, launch.allowedPaths.isEmpty,
              let current, current.conversationID == conversationID,
              current.workspaceID == launch.workspaceID,
              current.rootURL.standardizedFileURL == launch.rootURL.standardizedFileURL,
              launch.rootHandle.matches(root: current.rootURL),
              let raw = try? JSONSerialization.jsonObject(with: waiting.toolCall.argumentsJSON) as? [String: Any]
        else { return nil }
        let guarder = WorkspacePathGuard(rootURL: launch.rootURL)
        func path(_ path: String) -> String? {
            // Only a complete, unambiguous local relative name is shown.
            guard !path.isEmpty, path.utf8.count <= 256,
                  path == path.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.hasPrefix("/"), !path.contains("\\"),
                  path.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.properties.generalCategory {
                      case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned:
                          return false
                      default: return true
                      }
                  }) else { return nil }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  components.first != "Network", components.first != "Mounts",
                  let resolved = try? guarder.resolve(path),
                  resolved.standardizedFileURL == guarder.rootURL.appendingPathComponent(path).standardizedFileURL
            else { return nil }
            return path
        }
        let environment = WorkspaceToolEnvironment(rootProvider: { nil })
        var result: [String: Value] = [
            "kind": .string("workspaceFile"),
            "workspaceID": .string(launch.workspaceID.uuidString.lowercased()),
        ]
        let decoder = JSONDecoder()
        switch waiting.toolCall.toolName {
        case "workspace.createFile":
            guard Set(raw.keys).isSubset(of: ["path", "content", "overwrite", "scope"]),
                  let args = try? decoder.decode(WorkspaceCreateFileTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  (args.scope == nil || args.scope == "local"),
                  (try? WorkspaceCreateFileTool(environment: environment).validate(args)) != nil,
                  let target = path(args.path) else { return nil }
            result.merge(["operation": .string("createFile"), "target": .string(target),
                          "source": .string("inline"), "overwrite": .string(args.overwrite == true ? "allowed" : "forbidden"),
                          "precondition": .string("none")]) { _, new in new }
        case "workspace.writeFile":
            guard Set(raw.keys).isSubset(of: ["path", "content", "expectedMtime", "expectedSHA256", "scope", "sourcePath", "expectedSourceSHA256"]),
                  let args = try? decoder.decode(WorkspaceWriteFileTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  (args.scope == nil || args.scope == "local"),
                  (try? WorkspaceWriteFileTool(environment: environment).validate(args)) != nil,
                  let target = path(args.path) else { return nil }
            let hasHash = args.expectedSHA256 != nil
            let hasTime = args.expectedMtime != nil
            let condition = hasHash && hasTime ? "sha256AndMtime" : hasHash ? "sha256" : hasTime ? "mtime" : "none"
            result.merge(["operation": .string("writeFile"), "target": .string(target),
                          "source": .string(args.sourcePath == nil ? "inline" : "workspaceFile"),
                          "overwrite": .string(args.sourcePath != nil && condition == "none" ? "forbidden" : condition == "none" ? "allowed" : "conditional"),
                          "precondition": .string(condition)]) { _, new in new }
            if let source = args.sourcePath {
                guard let safeSource = path(source), safeSource != target else { return nil }
                result["sourcePath"] = .string(safeSource)
                result["sourcePrecondition"] = .string("sha256")
            }
        case "workspace.applyPatch":
            guard Set(raw.keys).isSubset(of: ["path", "patch", "scope"]),
                  let args = try? decoder.decode(WorkspaceApplyPatchTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  (args.scope == nil || args.scope == "local"),
                  (try? WorkspaceApplyPatchTool(environment: environment).validate(args)) != nil,
                  let target = path(args.path) else { return nil }
            result.merge(["operation": .string("applyPatch"), "target": .string(target),
                          "source": .string("patch"), "overwrite": .string("conditional"),
                          "precondition": .string("patchContext")]) { _, new in new }
        case "workspace.appendFile":
            guard Set(raw.keys).isSubset(of: ["path", "content", "expectedSHA256"]),
                  let args = try? decoder.decode(WorkspaceAppendFileTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  (try? WorkspaceAppendFileTool(environment: environment).validate(args)) != nil,
                  let target = path(args.path) else { return nil }
            result.merge(["operation": .string("appendFile"), "target": .string(target),
                          "source": .string("inline"), "overwrite": .string("conditional"),
                          "precondition": .string(args.expectedSHA256 == nil ? "fileExists" : "fileExistsAndSha256")]) { _, new in new }
        case "workspace.replaceText":
            guard Set(raw.keys).isSubset(of: ["path", "oldText", "newText", "expectedOccurrences", "expectedSHA256"]),
                  let args = try? decoder.decode(WorkspaceReplaceTextTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  (try? WorkspaceReplaceTextTool(environment: environment).validate(args)) != nil,
                  let target = path(args.path), let occurrences = Int64(exactly: args.expectedOccurrences ?? 1) else { return nil }
            result.merge(["operation": .string("replaceText"), "target": .string(target),
                          "source": .string("inline"), "overwrite": .string("conditional"),
                          "precondition": .string(args.expectedSHA256 == nil ? "occurrences" : "occurrencesAndSha256"),
                          "expectedOccurrences": .integer(occurrences)]) { _, new in new }
        case "workspace.createDirectory":
            guard Set(raw.keys).isSubset(of: ["path", "scope"]),
                  let args = try? decoder.decode(WorkspaceCreateDirectoryTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  args.scope == nil || args.scope == "local",
                  (try? WorkspaceCreateDirectoryTool(environment: environment).validate(args)) != nil,
                  let target = path(args.path) else { return nil }
            result.merge(["operation": .string("createDirectory"), "target": .string(target),
                          "source": .string("none"), "overwrite": .string("forbidden"),
                          "precondition": .string("none")]) { _, new in new }
        case "workspace.moveFile", "workspace.copyFile":
            guard Set(raw.keys).isSubset(of: ["from", "to", "scope"]),
                  let args = try? decoder.decode(WorkspaceMoveFileTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  args.scope == nil || args.scope == "local",
                  (try? WorkspaceMoveFileTool(environment: environment).validate(args)) != nil,
                  let source = path(args.from), let target = path(args.to), source != target else { return nil }
            result.merge(["operation": .string(waiting.toolCall.toolName == "workspace.moveFile" ? "moveFile" : "copyFile"),
                          "target": .string(target), "source": .string("workspaceFile"),
                          "sourcePath": .string(source), "sourcePrecondition": .string("exists"),
                          "overwrite": .string("forbidden"), "precondition": .string("sourceExists")]) { _, new in new }
        case "workspace.deleteFile":
            guard Set(raw.keys).isSubset(of: ["path", "recursive", "scope"]),
                  let args = try? decoder.decode(WorkspaceDeleteFileTool.Arguments.self, from: waiting.toolCall.argumentsJSON),
                  args.scope == nil || args.scope == "local",
                  (try? WorkspaceDeleteFileTool(environment: environment).validate(args)) != nil,
                  let target = path(args.path) else { return nil }
            result.merge(["operation": .string("deleteFile"), "target": .string(target),
                          "source": .string("none"), "overwrite": .string("conditional"),
                          "precondition": .string("exists"), "recursive": .boolean(args.recursive ?? false)]) { _, new in new }
        default: return nil
        }
        return result
    }
}
