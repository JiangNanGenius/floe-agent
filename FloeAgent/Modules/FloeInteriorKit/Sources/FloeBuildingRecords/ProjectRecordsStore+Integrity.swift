import Foundation
import GRDB

public struct ProjectIntegrityReport: Codable, Sendable, Hashable {
    public let projectID: ProjectID
    public let revision: Int
    public let databaseCheckPassed: Bool
    public let deepVerified: Bool
    public let roomCount: Int
    public let sourceCount: Int
    public let sourceVersionCount: Int
    public let observationCount: Int
    public let adoptedValueCount: Int
    public let bomTargetCount: Int
    public let bomDraftCount: Int
    public let bomItemCount: Int
    public let missingSourceVersionIDs: [SourceVersionID]
    public let corruptedSourceVersionIDs: [SourceVersionID]
    public let orphanStagingFiles: [String]
    public let orphanBlobCount: Int
}

extension ProjectRecordsStore {
    /// Check the database, source blob presence/size and (when requested) every
    /// blob digest. Missing or corrupt blobs are reported rather than silently
    /// repaired; original content is never rewritten by this diagnostic.
    public func integrityReport(deepVerify: Bool = false) throws -> ProjectIntegrityReport {
        let project = try currentProject()
        var databasePassed = false
        var missing: [SourceVersionID] = []
        var corrupted: [SourceVersionID] = []
        var orphanStaging: [String] = []
        var orphanBlobs = 0

        do {
            databasePassed = try database.read { db in
                let rows = try String.fetchAll(db, sql: "PRAGMA quick_check")
                return rows == ["ok"]
            }
            let versions = try database.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT v.id, v.sha256, v.byte_length
                        FROM source_version v
                        JOIN source s ON s.id = v.source_id
                        WHERE s.project_id = ?
                        ORDER BY v.source_id, v.version
                        """,
                    arguments: [projectID.databaseValue]
                )
            }
            var missingList: [SourceVersionID] = []
            var corruptedList: [SourceVersionID] = []
            for row in versions {
                let id: SourceVersionID = try row.recordID("id")
                let sha256: String = row["sha256"]
                let byteCount: Int = row["byte_length"]
                do {
                    let relative = try container.blobRelativePath(for: sha256)
                    let url = try container.existingRegularFileURL(relativePath: relative)
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
                    if size != byteCount || byteCount > limits.maxSourceBytes {
                        corruptedList.append(id)
                    } else if deepVerify {
                        _ = try container.readBlob(
                            sha256: sha256,
                            maxBytes: limits.maxSourceBytes
                        )
                    }
                } catch ProjectFileError.missing {
                    missingList.append(id)
                } catch ProjectFileError.corrupted {
                    corruptedList.append(id)
                } catch ProjectFileError.pathEscapesProject {
                    corruptedList.append(id)
                } catch BuildingRecordsError.contentTooLarge {
                    corruptedList.append(id)
                } catch BuildingRecordsError.invalidValue {
                    corruptedList.append(id)
                }
            }
            missing = missingList
            corrupted = corruptedList
            orphanStaging = try container.stagingFileNames()
            orphanBlobs = deepVerify ? try countOrphanBlobs() : 0
        }

        let counts = try database.read { db -> (Int, Int, Int, Int, Int, Int, Int, Int) in
            let roomCount = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM room WHERE project_id = ?",
                arguments: [projectID.databaseValue]
            ) ?? 0
            let sourceCount = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM source WHERE project_id = ?",
                arguments: [projectID.databaseValue]
            ) ?? 0
            let sourceVersionCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT count(*) FROM source_version v
                    JOIN source s ON s.id = v.source_id
                    WHERE s.project_id = ?
                    """,
                arguments: [projectID.databaseValue]
            ) ?? 0
            let observationCount = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM observation WHERE project_id = ?",
                arguments: [projectID.databaseValue]
            ) ?? 0
            let adoptedValueCount = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM adopted_value WHERE project_id = ?",
                arguments: [projectID.databaseValue]
            ) ?? 0
            let bomTargetCount = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM bom_target WHERE project_id = ?",
                arguments: [projectID.databaseValue]
            ) ?? 0
            let bomDraftCount = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM bom_draft WHERE project_id = ?",
                arguments: [projectID.databaseValue]
            ) ?? 0
            let bomItemCount = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM bom_item WHERE project_id = ?",
                arguments: [projectID.databaseValue]
            ) ?? 0
            return (
                roomCount,
                sourceCount,
                sourceVersionCount,
                observationCount,
                adoptedValueCount,
                bomTargetCount,
                bomDraftCount,
                bomItemCount
            )
        }

        return ProjectIntegrityReport(
            projectID: projectID,
            revision: project.revision,
            databaseCheckPassed: databasePassed,
            deepVerified: deepVerify,
            roomCount: counts.0,
            sourceCount: counts.1,
            sourceVersionCount: counts.2,
            observationCount: counts.3,
            adoptedValueCount: counts.4,
            bomTargetCount: counts.5,
            bomDraftCount: counts.6,
            bomItemCount: counts.7,
            missingSourceVersionIDs: missing,
            corruptedSourceVersionIDs: corrupted,
            orphanStagingFiles: orphanStaging,
            orphanBlobCount: orphanBlobs
        )
    }

    /// Remove leftover `.part` files left by an interrupted import. Only call
    /// while no other importer is using this container. Staging files never
    /// carry committed records.
    @discardableResult
    public func discardStagedImports() throws -> Int {
        do {
            return try container.discardStagingFiles()
        } catch ProjectFileError.pathEscapesProject {
            throw BuildingRecordsError.pathEscapesProject
        }
    }

    private func countOrphanBlobs() throws -> Int {
        let blobsURL = container.rootURL.appendingPathComponent(ProjectContainer.blobsDirectory, isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: blobsURL.path) else { return 0 }
        let resolved = blobsURL.resolvingSymlinksInPath().standardizedFileURL
        guard container.isContained(resolved) else { throw BuildingRecordsError.pathEscapesProject }
        let known = try database.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT relative_path FROM content_blob"
            ))
        }
        var orphanCount = 0
        let prefixes = try fileManager.contentsOfDirectory(atPath: resolved.path)
        for prefix in prefixes where !prefix.hasPrefix(".") {
            let directory = resolved.appendingPathComponent(prefix, isDirectory: true)
            guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else {
                continue
            }
            let files = try fileManager.contentsOfDirectory(atPath: directory.path)
            for file in files {
                let relative = "\(ProjectContainer.blobsDirectory)/\(prefix)/\(file)"
                if !known.contains(relative) {
                    orphanCount += 1
                }
            }
        }
        return orphanCount
    }
}
