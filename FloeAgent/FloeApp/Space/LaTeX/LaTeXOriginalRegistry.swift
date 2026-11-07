// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import FloeLaTeXCore

struct LaTeXOriginal:Sendable {
    let id:UUID
    let owner:LaTeXOwner
    let root:URL
    let libraryRecord:PersonalContentRecord?
}

/// Native creation records for task/Notes originals. This private index is
/// never imported from a project, included in ZIP exports, or used as a grant.
/// Space originals remain inside their existing Library package and barrier.
actor LaTeXOriginalRegistry {
    nonisolated let root:URL
    private let pool:DatabasePool
    init(root:URL) throws {
        self.root=root.standardizedFileURL
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        pool=try DatabasePool(path:root.appendingPathComponent("originals.sqlite").path)
        try pool.write {db in
            try db.execute(sql:"""
                CREATE TABLE IF NOT EXISTS originals (
                    project_id TEXT PRIMARY KEY NOT NULL,
                    owner_kind TEXT NOT NULL,
                    owner_id TEXT NOT NULL
                )
                """)
        }
    }
    func original(_ id:UUID) throws -> LaTeXOriginal? {
        try pool.read {db in
            guard let row=try Row.fetchOne(db,sql:"SELECT owner_kind,owner_id FROM originals WHERE project_id=?",arguments:[id.uuidString]),
                  let kind=LaTeXOwner.Kind(rawValue:row["owner_kind"]),let ownerID=UUID(uuidString:row["owner_id"]),kind != .space else {return nil}
            return .init(id:id,owner:.init(kind:kind,id:ownerID),root:directory(id),libraryRecord:nil)
        }
    }
    func owned(by owner:LaTeXOwner) throws -> [LaTeXOriginal] {
        try pool.read {db in
            try String.fetchAll(db,sql:"SELECT project_id FROM originals WHERE owner_kind=? AND owner_id=? ORDER BY project_id LIMIT 200",
                arguments:[owner.kind.rawValue,owner.id.uuidString]).compactMap {raw in
                guard let id=UUID(uuidString:raw) else {return nil}
                return .init(id:id,owner:owner,root:directory(id),libraryRecord:nil)
            }
        }
    }
    private nonisolated func directory(_ id:UUID)->URL {
        root.appendingPathComponent("Originals",isDirectory:true).appendingPathComponent(id.uuidString.lowercased(),isDirectory:true)
    }
    func create(id:UUID,owner:LaTeXOwner,title:String,templateID:String) async throws -> LaTeXOriginal {
        guard owner.kind == .task || owner.kind == .note,
              let template=LaTeXTemplates.all.first(where:{$0.id==templateID}) else {throw LaTeXError.invalidProject}
        try await pool.write {db in
            if let row=try Row.fetchOne(db,sql:"SELECT owner_kind,owner_id FROM originals WHERE project_id=?",arguments:[id.uuidString]) {
                let kind:String=row["owner_kind"],raw:String=row["owner_id"]
                guard kind==owner.kind.rawValue,UUID(uuidString:raw)==owner.id else {throw LaTeXError.invalidProject}
            } else {
                try db.execute(sql:"INSERT INTO originals(project_id,owner_kind,owner_id) VALUES (?,?,?)",arguments:[id.uuidString,owner.kind.rawValue,owner.id.uuidString])
            }
        }
        // Reserve the native identity before filesystem work. A failed or
        // interrupted creation remains retryable without adopting another
        // document's directory or replacing completed source files.
        let target=directory(id)
        let store:LaTeXProjectStore
        if FileManager.default.fileExists(atPath:target.appendingPathComponent("LaTeXProject.json").path) {
            store=try LaTeXProjectStore(root:target)
        } else {
            store=try LaTeXProjectStore.create(root:target,id:id,owner:owner,title:title,
                files:template.files,mainFile:template.mainFile,engine:template.engine)
        }
        let manifest=try await store.manifest()
        guard manifest.id==id,manifest.owner==owner else {throw LaTeXError.invalidProject}
        return .init(id:id,owner:owner,root:target,libraryRecord:nil)
    }
}
#endif
