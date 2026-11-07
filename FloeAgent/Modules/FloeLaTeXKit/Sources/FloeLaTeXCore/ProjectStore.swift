// SPDX-License-Identifier: MPL-2.0
import Foundation

public actor LaTeXProjectStore {
    public nonisolated let root: URL
    public let limits: LaTeXProjectLimits
    private let commitCheckpoint: (@Sendable (Int) throws -> Void)?
    private static let manifestName = "LaTeXProject.json"
    private struct Journal: Codable { var before: LaTeXProjectManifest; var after: LaTeXProjectManifest; var changed: [String]; var label: String; var origin: String; var digest: String }
    private struct Receipt: Codable { var digest: String; var revision: Int64; var changed: [String] }

    public init(root: URL, limits: LaTeXProjectLimits = .init()) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.limits = limits; commitCheckpoint = nil
        guard FileManager.default.fileExists(atPath: self.root.appendingPathComponent(Self.manifestName).path) else { throw LaTeXError.invalidProject }
    }
    init(root: URL, checkpoint: @escaping @Sendable (Int) throws -> Void) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); limits = .init(); commitCheckpoint = checkpoint
    }
    public static func create(root: URL, id: UUID = UUID(), owner: LaTeXOwner, title: String,
                              files: [String: Data], mainFile: String = "main.tex", engine: LaTeXEngine = .xeLaTeX) throws -> LaTeXProjectStore {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try LaTeXFileLock.run(root: root) {
            guard !manager.fileExists(atPath: root.appendingPathComponent(manifestName).path) else { throw LaTeXError.duplicatePath(title) }
            guard try manager.contentsOfDirectory(atPath:root.path).allSatisfy({$0 == ".latex.lock"}) else {throw LaTeXError.invalidOperation("Create a project in an empty directory.")}
            var manifest = LaTeXProjectManifest(id: id, owner: owner, title: title, mainFile: mainFile, engine: engine)
            guard files[mainFile] != nil else { throw LaTeXError.missingFile(mainFile) }
            // Validate the complete import before writing its first file. A
            // bad later entry must not strand a reserved project identity.
            var keys = Set<String>(); var total = 0
            let limits = LaTeXProjectLimits()
            for (path,data) in files {
                _=try LaTeXPath.validate(path)
                guard keys.insert(LaTeXPath.collisionKey(path)).inserted else {throw LaTeXError.duplicatePath(path)}
                total+=data.count
                guard files.count<=limits.maximumFiles,total<=limits.maximumProjectBytes,data.count<=limits.maximumFileBytes else {throw LaTeXError.limitExceeded(path)}
                if LaTeXFileKind.infer(path).isText && (data.count>limits.maximumTextBytes || String(data:data,encoding:.utf8)==nil) {throw LaTeXError.invalidText}
            }
            for key in keys {
                let parts=key.split(separator:"/")
                for depth in 1..<parts.count where keys.contains(parts.prefix(depth).joined(separator:"/")) {throw LaTeXError.invalidPath(key)}
            }
            let source = root.appendingPathComponent("Source", isDirectory: true)
            let blobs = root.appendingPathComponent("History/Blobs", isDirectory: true)
            try manager.createDirectory(at: source, withIntermediateDirectories: true)
            try manager.createDirectory(at: blobs, withIntermediateDirectories: true)
            for path in files.keys.sorted() {
                let data = files[path]!
                let entry = LaTeXFileEntry(path: path, data: data)
                try data.write(to: LaTeXPath.child(path, root: source, createParents: true), options: .atomic)
                try data.write(to: blobs.appendingPathComponent(entry.sha256), options: .atomic)
                manifest.files.append(entry)
            }
            try LaTeXDigest.encode(manifest).write(to: root.appendingPathComponent(manifestName), options: .atomic)
            let history = LaTeXHistoryEntry(manifest: manifest, label: "Created", origin: "user", mutationID: nil)
            try LaTeXDigest.encode(history).write(to: root.appendingPathComponent("History/0.json"), options: .atomic)
        }
        return try .init(root: root)
    }

    public func manifest() throws -> LaTeXProjectManifest {
        try LaTeXFileLock.run(root: root) { try recover(); return try loadManifest() }
    }
    public func read(_ path: String) throws -> Data {
        try LaTeXFileLock.run(root: root) {
            try recover(); let state = try loadManifest()
            guard let entry = state.files.first(where: { $0.path == path }) else { throw LaTeXError.missingFile(path) }
            return try verified(entry)
        }
    }
    public func text(_ path: String) throws -> String {
        guard let text = String(data: try read(path), encoding: .utf8) else { throw LaTeXError.invalidText }; return text
    }
    public func file(_ path:String) throws -> (manifest:LaTeXProjectManifest,data:Data) {
        try LaTeXFileLock.run(root:root) {
            try recover();let state=try loadManifest()
            guard let entry=state.files.first(where:{$0.path==path}) else {throw LaTeXError.missingFile(path)}
            return (state,try verified(entry))
        }
    }
    /// One coherent revision of textual inputs for search, citation and symbol
    /// indexing. Does not copy images/fonts into a temporary build snapshot.
    public func textFiles(maximumBytes:Int=64*1024*1024) throws -> (manifest:LaTeXProjectManifest,files:[String:String]) {
        try LaTeXFileLock.run(root:root) {
            try recover();let manifest=try loadManifest();var files=[String:String](),total=0
            for entry in manifest.files where entry.kind.isText {
                try Task.checkCancellation();total+=entry.byteCount
                guard total<=maximumBytes else {throw LaTeXError.limitExceeded("text index")}
                guard let text=String(data:try verified(entry),encoding:.utf8) else {throw LaTeXError.invalidText}
                files[entry.path]=text
            }
            return (manifest,files)
        }
    }

    @discardableResult public func apply(_ edits: [LaTeXEdit], expectedRevision: Int64, requestID: UUID = UUID(),
                                         label: String = "Edit", origin: String = "user") throws -> LaTeXMutationResult {
        try LaTeXFileLock.run(root: root) {
            try recover()
            let before = try loadManifest()
            let digest = LaTeXDigest.hash(try LaTeXDigest.encode(edits))
            let receiptURL = root.appendingPathComponent("Receipts/" + requestID.uuidString + ".json")
            if FileManager.default.fileExists(atPath: receiptURL.path) {
                let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
                guard receipt.digest == digest else { throw LaTeXError.invalidOperation("This request identity was already used for a different edit.") }
                return .init(revision: receipt.revision, currentRevision: before.revision, replayed: true, changedPaths: receipt.changed)
            }
            guard before.revision == expectedRevision else { throw LaTeXError.revisionConflict(expected: expectedRevision, actual: before.revision) }
            try Task.checkCancellation()
            var after = before
            var changed = [String: Data]()
            var removed = Set<String>()
            func dataFor(_ path: String) throws -> Data {
                _ = try LaTeXPath.validate(path)
                if let data = changed[path] { return data }
                guard !removed.contains(path), let entry = after.files.first(where: { $0.path == path }) else { throw LaTeXError.missingFile(path) }
                return try verified(entry)
            }
            func put(_ path: String, data: Data) throws {
                _ = try LaTeXPath.validate(path)
                if after.files.contains(where: { $0.path != path && LaTeXPath.collisionKey($0.path) == LaTeXPath.collisionKey(path) }) { throw LaTeXError.duplicatePath(path) }
                guard data.count <= limits.maximumFileBytes else { throw LaTeXError.limitExceeded(path) }
                if LaTeXFileKind.infer(path).isText && (data.count > limits.maximumTextBytes || String(data: data, encoding: .utf8) == nil) { throw LaTeXError.invalidText }
                after.files.removeAll { $0.path == path }; after.files.append(.init(path: path, data: data))
                changed[path] = data; removed.remove(path)
            }
            for edit in edits {
                switch edit {
                case .put(let path, let data): try put(path, data: data)
                case .replace(let path, let range, let replacement):
                    guard let text = String(data: try dataFor(path), encoding: .utf8) else { throw LaTeXError.invalidText }
                    try put(path, data: Data(try range.replacing(in: text, with: replacement).utf8))
                case .delete(let path):
                    _ = try dataFor(path); after.files.removeAll { $0.path == path }; changed.removeValue(forKey: path); removed.insert(path)
                case .rename(let from, let to):
                    guard !after.files.contains(where: { LaTeXPath.collisionKey($0.path) == LaTeXPath.collisionKey(to) && $0.path != from }) else { throw LaTeXError.duplicatePath(to) }
                    let data = try dataFor(from); after.files.removeAll { $0.path == from }; changed.removeValue(forKey: from); removed.insert(from)
                    try put(to, data: data); if after.mainFile == from { after.mainFile = to }
                case .title(let title): guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LaTeXError.invalidOperation("Enter a title.") }; after.title = title
                case .mainFile(let path): _ = try LaTeXPath.validate(path); after.mainFile = path
                case .engine(let engine): after.engine = engine
                case .resources(let resources): after.resources = resources
                }
            }
            after.files.sort { $0.path < $1.path }
            let fileKeys = Set(after.files.map { LaTeXPath.collisionKey($0.path) })
            for entry in after.files {
                let components = entry.path.split(separator: "/")
                if components.count > 1 {
                    for depth in 1..<components.count where fileKeys.contains(LaTeXPath.collisionKey(components.prefix(depth).joined(separator: "/"))) {
                        throw LaTeXError.duplicatePath(entry.path)
                    }
                }
            }
            guard after.files.contains(where: { $0.path == after.mainFile }) else { throw LaTeXError.missingFile(after.mainFile) }
            guard after.files.count <= limits.maximumFiles, after.files.reduce(0, { $0 + $1.byteCount }) <= limits.maximumProjectBytes else { throw LaTeXError.limitExceeded("project size") }
            // Detect external edits before publishing a multi-file transaction.
            for entry in before.files { _ = try verified(entry) }
            after.revision += 1; after.modifiedAt = Date(); after.lastMutationID = requestID
            let paths = Set(changed.keys).union(removed).sorted()
            for path in paths { _ = try LaTeXPath.child(path, root: root.appendingPathComponent("Source")) }
            for data in changed.values { try storeBlob(data) }
            let journal = Journal(before: before, after: after, changed: paths, label: label, origin: origin, digest: digest)
            try LaTeXDigest.encode(journal).write(to: root.appendingPathComponent("Transaction.json"), options: .atomic)
            do {
                try materialize(paths, manifest: after) { index in
                    try self.commitCheckpoint?(index)
                    try Task.checkCancellation()
                }
                try LaTeXDigest.encode(after).write(to: root.appendingPathComponent(Self.manifestName), options: .atomic)
                try finish(journal)
            } catch {
                // The journal is authoritative if rollback itself encounters an I/O error.
                try? recover()
                throw error
            }
            return .init(revision: after.revision, currentRevision: after.revision, replayed: false, changedPaths: paths)
        }
    }

    public func history() throws -> [LaTeXHistoryEntry] {
        try LaTeXFileLock.run(root: root) {
            try recover()
            return try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("History"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(LaTeXHistoryEntry.self, from: Data(contentsOf: $0)) }
                .sorted { $0.id > $1.id }
        }
    }
    public func text(_ path: String, at revision: Int64) throws -> String {
        try LaTeXFileLock.run(root: root) {
            try recover()
            let item = try JSONDecoder().decode(LaTeXHistoryEntry.self, from: Data(contentsOf: root.appendingPathComponent("History/\(revision).json")))
            guard let entry = item.manifest.files.first(where: { $0.path == path }) else { throw LaTeXError.missingFile(path) }
            guard let text = String(data: try blob(entry.sha256), encoding: .utf8) else { throw LaTeXError.invalidText }; return text
        }
    }
    @discardableResult public func restore(revision: Int64, expectedRevision: Int64, requestID: UUID = UUID()) throws -> LaTeXMutationResult {
        let item = try JSONDecoder().decode(LaTeXHistoryEntry.self, from: Data(contentsOf: root.appendingPathComponent("History/\(revision).json")))
        let current = try manifest()
        var edits = try item.manifest.files.map { LaTeXEdit.put(path: $0.path, data: try blob($0.sha256)) }
        edits += current.files.filter { entry in !item.manifest.files.contains(where: { $0.path == entry.path }) }.map { .delete(path: $0.path) }
        edits += [.title(item.manifest.title), .mainFile(item.manifest.mainFile), .engine(item.manifest.engine), .resources(item.manifest.resources)]
        return try apply(edits, expectedRevision: expectedRevision, requestID: requestID, label: "Restore revision \(revision)")
    }
    public func snapshot(id: UUID = UUID(),expectedRevision:Int64?=nil) throws -> LaTeXProjectSnapshot {
        try LaTeXFileLock.run(root: root) {
            try recover(); let manifest = try loadManifest()
            if let expectedRevision,expectedRevision != manifest.revision {throw LaTeXError.revisionConflict(expected:expectedRevision,actual:manifest.revision)}
            let target = try LaTeXPath.child("Snapshots/"+id.uuidString,root:root,createParents:true)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw LaTeXError.duplicatePath(id.uuidString) }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            do {
                for entry in manifest.files {
                    let data = try verified(entry)
                    try data.write(to: LaTeXPath.child(entry.path, root: target, createParents: true), options: .atomic)
                }
            } catch { try? FileManager.default.removeItem(at: target); throw error }
            return .init(id: id, manifest: manifest, sourceRoot: target, fingerprint: LaTeXDigest.hash(try LaTeXDigest.encode(manifest)))
        }
    }
    public func releaseSnapshot(_ snapshot: LaTeXProjectSnapshot) throws {
        let expected = try LaTeXPath.child("Snapshots/"+snapshot.id.uuidString,root:root).standardizedFileURL
        guard expected == snapshot.sourceRoot.standardizedFileURL else { throw LaTeXError.invalidProject }
        if FileManager.default.fileExists(atPath: expected.path) { try FileManager.default.removeItem(at: expected) }
    }

    private func loadManifest() throws -> LaTeXProjectManifest {
        let url=root.appendingPathComponent(Self.manifestName)
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=16*1024*1024 else {throw LaTeXError.limitExceeded("project manifest")}
        let state = try JSONDecoder().decode(LaTeXProjectManifest.self, from: Data(contentsOf:url))
        guard state.schemaVersion == 1,state.revision>=0,state.files.count<=limits.maximumFiles,state.files.contains(where:{$0.path==state.mainFile}) else { throw LaTeXError.invalidProject }
        var total=0,keys=Set<String>()
        for entry in state.files {
            _=try LaTeXPath.validate(entry.path)
            guard entry.byteCount>=0,entry.byteCount<=limits.maximumFileBytes,entry.sha256.count==64,entry.sha256.allSatisfy(\.isHexDigit),entry.kind==LaTeXFileKind.infer(entry.path),keys.insert(LaTeXPath.collisionKey(entry.path)).inserted else {throw LaTeXError.invalidProject}
            total+=entry.byteCount;guard total<=limits.maximumProjectBytes else {throw LaTeXError.limitExceeded("project size")}
        }
        return state
    }
    private func verified(_ entry: LaTeXFileEntry) throws -> Data {
        let url = try LaTeXPath.child(entry.path, root: root.appendingPathComponent("Source"))
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size == entry.byteCount, size <= limits.maximumFileBytes else { throw LaTeXError.changedFile(entry.path) }
        let data = try Data(contentsOf: url)
        guard LaTeXDigest.hash(data) == entry.sha256 else { throw LaTeXError.changedFile(entry.path) }; return data
    }
    private func storeBlob(_ data: Data) throws {
        let directory = root.appendingPathComponent("History/Blobs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(LaTeXDigest.hash(data))
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
    }
    private func blob(_ hash: String) throws -> Data {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw LaTeXError.invalidProject }
        let data = try Data(contentsOf: root.appendingPathComponent("History/Blobs/" + hash))
        guard LaTeXDigest.hash(data) == hash else { throw LaTeXError.invalidProject }; return data
    }
    private func install(_ path: String, manifest: LaTeXProjectManifest) throws {
        let target = try LaTeXPath.child(path, root: root.appendingPathComponent("Source"), createParents: true)
        if let entry = manifest.files.first(where: { $0.path == path }) {
            if (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty else { throw LaTeXError.invalidOperation("The destination folder contains files.") }
                try FileManager.default.removeItem(at: target)
            }
            try blob(entry.sha256).write(to: target, options: .atomic)
        }
        else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
    private func materialize(_ paths: [String], manifest: LaTeXProjectManifest, checkpoint: ((Int) throws -> Void)? = nil) throws {
        let retained = Set(manifest.files.map(\.path))
        let deletions = paths.filter { !retained.contains($0) }.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        let writes = paths.filter { retained.contains($0) }.sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }
        for (index, path) in (deletions + writes).enumerated() { try install(path, manifest: manifest); try checkpoint?(index) }
    }
    private func finish(_ journal: Journal) throws {
        guard let mutationID = journal.after.lastMutationID else { throw LaTeXError.invalidProject }
        let entry = LaTeXHistoryEntry(manifest: journal.after, label: journal.label, origin: journal.origin, mutationID: journal.after.lastMutationID)
        try LaTeXDigest.encode(entry).write(to: root.appendingPathComponent("History/\(journal.after.revision).json"), options: .atomic)
        let receipts = root.appendingPathComponent("Receipts")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        let receipt = Receipt(digest: journal.digest, revision: journal.after.revision, changed: journal.changed)
        try LaTeXDigest.encode(receipt).write(to: receipts.appendingPathComponent(mutationID.uuidString + ".json"), options: .atomic)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Transaction.json"))
    }
    private func recover() throws {
        let url = root.appendingPathComponent("Transaction.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
        let current = try loadManifest()
        if current.revision == journal.after.revision && current.lastMutationID == journal.after.lastMutationID {
            try materialize(journal.changed, manifest: journal.after); try finish(journal)
        } else {
            try materialize(journal.changed, manifest: journal.before)
            try LaTeXDigest.encode(journal.before).write(to: root.appendingPathComponent(Self.manifestName), options: .atomic)
            try FileManager.default.removeItem(at: url)
        }
    }
}
