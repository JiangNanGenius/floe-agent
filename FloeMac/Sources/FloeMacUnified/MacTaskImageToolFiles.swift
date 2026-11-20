// SPDX-License-Identifier: MPL-2.0
import Crypto
import Darwin
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools

/// A task-owned output directory. Reopen and verify its inode on each access,
/// including when the result arrives after an asynchronous provider request.
struct MacTaskMediaDirectory: Sendable {
    let relativeDirectory: String
    let wasCreated: Bool
    struct Identity: Codable, Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }
    var identity: Identity { Identity(device: device, inode: inode) }
    private let physical: String
    private let root: MacAgentWorkspaceRoot
    private let taskID: UUID
    private let device: dev_t
    private let inode: ino_t

    init(root: MacAgentWorkspaceRoot, relativeDirectory: String, context: ToolContext) throws {
        guard case .local = context.scope, !context.temporaryReadOnly, !context.publicWebOnly,
              let id = context.conversationID, let physical = root.physicalPath,
              let workspace = context.workspaceRootURL, MacAgentWorkspacePinSupport.physicalPath(workspace.path) == physical,
              try MacAgentWorkspacePinSupport.standardizedRelativePath(relativeDirectory) == relativeDirectory,
              relativeDirectory != "." else { throw CocoaError(.fileWriteNoPermission) }
        try context.authorizeWorkspacePath(relativeDirectory)
        var accumulated = ""
        var lastCreated = false
        var info = stat()
        for component in relativeDirectory.split(separator: "/") {
            try context.cancellation.throwIfCancelled()
            accumulated += (accumulated.isEmpty ? "" : "/") + component
            try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: accumulated, root: root) { pin in
                lastCreated = mkdirat(pin.parentFileDescriptor, pin.name, 0o700) == 0
                guard lastCreated || errno == EEXIST,
                      fstatat(pin.parentFileDescriptor, pin.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileWriteNoPermission) }
            }
        }
        self.physical = physical; self.root = root; self.taskID = id
        self.relativeDirectory = relativeDirectory; self.wasCreated = lastCreated
        device = info.st_dev; inode = info.st_ino
    }

    private func pinned<T>(name: String, context: ToolContext, _ body: (MacAgentWorkspacePinSupport.Pin) throws -> T) throws -> T {
        guard context.conversationID == taskID, !context.temporaryReadOnly, !context.publicWebOnly,
              case .local = context.scope, let workspace = context.workspaceRootURL,
              MacAgentWorkspacePinSupport.physicalPath(workspace.path) == physical, !name.contains("/"),
              try MacAgentWorkspacePinSupport.standardizedRelativePath(name) == name, name != "." else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let relative = relativeDirectory + "/" + name
        try context.authorizeWorkspacePath(relative)
        try context.cancellation.throwIfCancelled()
        return try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: relative, root: root) { pin in
            var parent = stat()
            guard fstat(pin.parentFileDescriptor, &parent) == 0, parent.st_dev == device, parent.st_ino == inode else {
                throw CocoaError(.fileWriteNoPermission)
            }
            return try body(pin)
        }
    }

    func read(name: String, maximumBytes: Int, context: ToolContext) throws -> Data {
        try pinned(name: name, context: context) { pin in
            let fd = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(pin, physicalRoot: physical, displayPath: name)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard maximumBytes >= 0, maximumBytes < Int.max, fstat(fd, &info) == 0, info.st_nlink == 1,
                  info.st_size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard bytes.count == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
            return bytes
        }
    }

    func commit(name: String, mimeType: String, data: Data, context: ToolContext) throws -> ToolArtifactReference {
        try publish(name: name, mimeType: mimeType, maximumBytes: data.count, context: context) { write in try write(data) }
    }

    func commit(name: String, mimeType: String, source: FileHandle, maximumBytes: Int, context: ToolContext) throws -> ToolArtifactReference {
        var info = stat()
        guard fstat(source.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        try source.seek(toOffset: 0)
        return try publish(name: name, mimeType: mimeType, maximumBytes: maximumBytes, context: context) { write in
            var bytes = 0
            while let block = try source.read(upToCount: 262_144), !block.isEmpty { try write(block); bytes += block.count }
            guard bytes == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    private func publish(name: String, mimeType: String, maximumBytes: Int, context: ToolContext,
                         copy: ((_ chunk: Data) throws -> Void) throws -> Void) throws -> ToolArtifactReference {
        try pinned(name: name, context: context) { pin in
            let parent = pin.parentFileDescriptor
            let stage = ".floe-media-" + UUID().uuidString
            let fd = openat(parent, stage, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { unlinkat(parent, stage, 0) }
            var digest = SHA256(), count = 0
            try copy { data in
                try context.cancellation.throwIfCancelled()
                try Task.checkCancellation()
                guard data.count <= maximumBytes - count else { throw CocoaError(.fileReadTooLarge) }
                try file.write(contentsOf: data)
                digest.update(data: data); count += data.count
            }
            guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
            try file.synchronize()
            try file.seek(toOffset: 0)
            var verification = SHA256()
            while let chunk = try file.read(upToCount: 262_144), !chunk.isEmpty {
                try context.cancellation.throwIfCancelled()
                verification.update(data: chunk)
            }
            let expected = digest.finalize()
            var held = stat(), named = stat()
            guard expected == verification.finalize(), fstat(fd, &held) == 0,
                  held.st_size == count, held.st_nlink == 1,
                  fstatat(parent, stage, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw CocoaError(.fileWriteUnknown) }
            try pinned(name: name, context: context) { fresh in
                try Task.checkCancellation()
                var result = renameatx_np(parent, stage, fresh.parentFileDescriptor, fresh.name, UInt32(RENAME_EXCL))
                if result != 0 && errno == ENOTSUP { result = linkat(parent, stage, fresh.parentFileDescriptor, fresh.name, 0) }
                guard result == 0 else { throw CocoaError(errno == EEXIST ? .fileWriteFileExists : .fileWriteUnknown) }
            }
            return ToolArtifactReference(id: UUID(), relativePath: relativeDirectory + "/" + name, mimeType: mimeType,
                byteCount: count, sha256: expected.map { String(format: "%02x", $0) }.joined())
        }
    }
}

struct MacTaskImageFiles {
    private struct Receipt: Codable {
        let approvedPayload: String
        let requestedCount: Int
        let artifacts: [ToolArtifactReference]
        let model: String
        let fallback: Bool
    }
    private let folder: MacTaskMediaDirectory
    private let digest: String
    private let requestedCount: Int
    var newRequest: Bool { folder.wasCreated }
    var relative: String { folder.relativeDirectory }

    init(root: MacAgentWorkspaceRoot, context: ToolContext, callID: String, count: Int) throws {
        guard let task = context.conversationID, let authority = context.runtimeAuthority else { throw CocoaError(.fileWriteNoPermission) }
        let key = context.toolIdempotencyKey.isEmpty ? callID : context.toolIdempotencyKey
        let request = FloeDigest.sha256Hex(Data((context.runID.uuidString + "/" + key).utf8))
        folder = try MacTaskMediaDirectory(root: root, relativeDirectory: "GeneratedImages/" + task.uuidString + "/" + request, context: context)
        digest = authority.payloadDigest
        requestedCount = count
    }

    func save(_ images: [Data], model: String, fallback: Bool, context: ToolContext) throws -> ToolExecutionOutput {
        guard !images.isEmpty, images.count <= requestedCount else { throw CocoaError(.fileReadCorruptFile) }
        let formats = try images.map { try MacImageGeneration.taskImageFormat($0) }
        var artifacts: [ToolArtifactReference] = []
        for (index, bytes) in images.enumerated() {
            let format = formats[index]
            let name = "Image-\(index + 1)." + format.fileExtension
            artifacts.append(try folder.commit(name: name, mimeType: format.mimeType, data: bytes, context: context))
        }
        let record = Receipt(approvedPayload: digest, requestedCount: requestedCount, artifacts: artifacts, model: String(model.prefix(256)), fallback: fallback)
        _ = try folder.commit(name: ".floe-images.json", mimeType: "application/json", data: JSONEncoder().encode(record), context: context)
        return output(record)
    }

    func replay(context: ToolContext) throws -> ToolExecutionOutput {
        do {
            let bytes = try folder.read(name: ".floe-images.json", maximumBytes: 16_384, context: context)
            let record = try JSONDecoder().decode(Receipt.self, from: bytes)
            guard record.approvedPayload == digest, record.requestedCount == requestedCount,
                  !record.artifacts.isEmpty, record.artifacts.count <= requestedCount else { throw CocoaError(.fileReadCorruptFile) }
            for (index, artifact) in record.artifacts.enumerated() {
                let name = (artifact.relativePath as NSString).lastPathComponent
                let bytes = try folder.read(name: name, maximumBytes: 32 * 1_048_576, context: context)
                let format = try MacImageGeneration.taskImageFormat(bytes)
                guard name == "Image-\(index + 1)." + format.fileExtension, artifact.relativePath == relative + "/" + name,
                      artifact.sha256 == FloeDigest.sha256Hex(bytes), artifact.byteCount == bytes.count,
                      artifact.mimeType == format.mimeType else { throw CocoaError(.fileReadCorruptFile) }
            }
            return output(record)
        } catch {
            try context.cancellation.throwIfCancelled()
            try Task.checkCancellation()
            return .init(digesting: MacImageWorkbenchText.t("此生图任务已经发起。请先查看 " + relative + " 中的结果，避免重复计费。", "This image request was already started. Check " + relative + " before starting another."),
                         exitStatus: 1, outcomeUnknown: true)
        }
    }

    private func output(_ record: Receipt) -> ToolExecutionOutput {
        let saved = record.artifacts.count
        let model = String(record.model.prefix(256))
        let role = record.fallback ? MacImageWorkbenchText.t("备用模型", "Fallback model") : MacImageWorkbenchText.t("模型", "Model")
        let summary = MacImageWorkbenchText.t("已保存 \(saved)/\(requestedCount) 张图像", "Saved \(saved) of \(requestedCount) requested images")
        let paths = record.artifacts.map(\.relativePath).joined(separator: "\n")
        return .init(digesting: summary + " · " + role + " " + model + "\n" + paths, artifacts: record.artifacts)
    }
}
