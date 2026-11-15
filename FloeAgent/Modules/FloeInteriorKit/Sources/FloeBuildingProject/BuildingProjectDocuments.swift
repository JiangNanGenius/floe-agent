import CryptoKit
import Foundation
import FloeBuildingRecords

public enum BuildingFileSection: String, Codable, Sendable, CaseIterable, Hashable {
    case records
    case cad
    case editorState
    case assetResources
}

public struct BuildingFileRecord: Codable, Sendable, Hashable {
    public let section: BuildingFileSection
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String

    public init(section: BuildingFileSection, relativePath: String, byteCount: Int, sha256: String) {
        self.section = section
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    var digestValue: ProjectFileDigest {
        ProjectFileDigest(relativePath: relativePath, byteCount: byteCount, sha256: sha256)
    }
}

public struct BuildingGenerationRecord: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let generationID: String
    public let projectID: ProjectID
    public let identity: BuildingStoredIdentity
    public let commitID: BuildingCommitID
    public let createdAt: Date
    public let recordsTreeDigest: String
    public let cadTreeDigest: String
    public let editorStateSHA256: String
    public let editorStateByteCount: Int
    public let assetResourcesTreeDigest: String
    public let fileCount: Int
    public let totalByteCount: Int
    public let files: [BuildingFileRecord]

    init(
        schemaVersion: Int = 1,
        generationID: String,
        projectID: ProjectID,
        identity: BuildingStoredIdentity,
        commitID: BuildingCommitID,
        createdAt: Date,
        recordsTreeDigest: String,
        cadTreeDigest: String,
        editorStateSHA256: String,
        editorStateByteCount: Int,
        assetResourcesTreeDigest: String,
        fileCount: Int,
        totalByteCount: Int,
        files: [BuildingFileRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.generationID = generationID
        self.projectID = projectID
        self.identity = identity
        self.commitID = commitID
        self.createdAt = createdAt
        self.recordsTreeDigest = recordsTreeDigest
        self.cadTreeDigest = cadTreeDigest
        self.editorStateSHA256 = editorStateSHA256
        self.editorStateByteCount = editorStateByteCount
        self.assetResourcesTreeDigest = assetResourcesTreeDigest
        self.fileCount = fileCount
        self.totalByteCount = totalByteCount
        self.files = files
    }

    func validate(limits: BuildingProjectLimits) throws {
        guard schemaVersion == 1 else {
            throw BuildingProjectError.unsupportedSchema(schemaVersion)
        }
        try identity.validated()
        guard projectID == identity.recordsProjectID else {
            throw BuildingProjectError.invalidIdentity("the generation project identity does not match records")
        }
        guard BuildingStoredIdentity.isSHA256Hex(generationID) else {
            throw BuildingProjectError.generationCorrupted(
                generationID: generationID,
                reason: "the generation identifier is not a SHA-256 digest"
            )
        }
        guard BuildingStoredIdentity.isSHA256Hex(recordsTreeDigest),
              BuildingStoredIdentity.isSHA256Hex(cadTreeDigest),
              BuildingStoredIdentity.isSHA256Hex(editorStateSHA256),
              BuildingStoredIdentity.isSHA256Hex(assetResourcesTreeDigest) else {
            throw BuildingProjectError.generationCorrupted(
                generationID: generationID,
                reason: "a tree digest is not a SHA-256 digest"
            )
        }
        guard editorStateByteCount >= 0, editorStateByteCount <= limits.maxEditorStateBytes else {
            throw BuildingProjectError.budgetExceeded(
                "editor state is \(editorStateByteCount) bytes; the limit is \(limits.maxEditorStateBytes)"
            )
        }
        guard !files.isEmpty, files.count == fileCount else {
            throw BuildingProjectError.generationCorrupted(
                generationID: generationID,
                reason: "the file manifest does not match fileCount"
            )
        }
        var total = 0
        var seen: Set<String> = []
        var previousKey: String?
        for file in files {
            guard file.byteCount >= 0, file.byteCount <= limits.maxSingleFileBytes else {
                throw BuildingProjectError.budgetExceeded("a generation file has an invalid byte count")
            }
            guard BuildingStoredIdentity.isSHA256Hex(file.sha256) else {
                throw BuildingProjectError.generationCorrupted(
                    generationID: generationID,
                    reason: "a file hash is not a SHA-256 digest"
                )
            }
            try BuildingProjectPaths.validateRelativePath(
                file.relativePath,
                limits: limits,
                label: "generation file"
            )
            switch file.section {
            case .records:
                guard BuildingProjectPaths.isRecordsPath(file.relativePath) else {
                    throw BuildingProjectError.generationCorrupted(
                        generationID: generationID,
                        reason: "unexpected records path \(file.relativePath)"
                    )
                }
            case .cad:
                break
            case .editorState:
                guard file.relativePath == BuildingProjectPaths.editorStateRelativePath else {
                    throw BuildingProjectError.generationCorrupted(
                        generationID: generationID,
                        reason: "unexpected editor state path \(file.relativePath)"
                    )
                }
            case .assetResources:
                break
            }
            let key = "\(file.section.rawValue)/\(file.relativePath.lowercased())"
            guard seen.insert(key).inserted else {
                throw BuildingProjectError.duplicatePath(file.relativePath)
            }
            guard total <= limits.maxTotalBytes - file.byteCount else {
                throw BuildingProjectError.budgetExceeded(
                    "the generation exceeds maxTotalBytes \(limits.maxTotalBytes)"
                )
            }
            total += file.byteCount
            let orderKey = "\(file.section.rawValue)\u{0}\(file.relativePath)"
            if let previousKey, orderKey < previousKey {
                throw BuildingProjectError.generationCorrupted(
                    generationID: generationID,
                    reason: "the generation file list is not sorted"
                )
            }
            previousKey = orderKey
        }
        guard total == totalByteCount else {
            throw BuildingProjectError.generationCorrupted(
                generationID: generationID,
                reason: "the file manifest does not match totalByteCount"
            )
        }
        let records = files.filter { $0.section == .records }
        let cad = files.filter { $0.section == .cad }
        let editor = files.filter { $0.section == .editorState }
        guard records.contains(where: { $0.relativePath == BuildingProjectPaths.recordsDatabaseRelativePath }),
              ProjectFileTreeDigest.digest(records.map(\.digestValue)) == recordsTreeDigest else {
            throw BuildingProjectError.generationCorrupted(
                generationID: generationID,
                reason: "the records tree digest does not match its files"
            )
        }
        guard ProjectFileTreeDigest.digest(cad.map(\.digestValue)) == cadTreeDigest else {
            throw BuildingProjectError.generationCorrupted(
                generationID: generationID,
                reason: "the CAD tree digest does not match its files"
            )
        }
        let assetResources = files.filter { $0.section == .assetResources }
        guard ProjectFileTreeDigest.digest(assetResources.map(\.digestValue)) == assetResourcesTreeDigest else {
            throw BuildingProjectError.generationCorrupted(
                generationID: generationID,
                reason: "the asset resource tree digest does not match its files"
            )
        }
        guard editor.count == 1,
              editor[0].sha256 == editorStateSHA256,
              editor[0].byteCount == editorStateByteCount else {
            throw BuildingProjectError.generationCorrupted(
                generationID: generationID,
                reason: "the editor state does not match its manifest entry"
            )
        }
        let expectedID = Self.computeGenerationID(
            identity: identity,
            recordsTreeDigest: recordsTreeDigest,
            cadTreeDigest: cadTreeDigest,
            editorStateSHA256: editorStateSHA256,
            editorStateByteCount: editorStateByteCount,
            assetResourcesTreeDigest: assetResourcesTreeDigest,
            fileCount: fileCount,
            totalByteCount: totalByteCount
        )
        guard expectedID == generationID else {
            throw BuildingProjectError.generationCorrupted(
                generationID: generationID,
                reason: "the generation identifier does not match its contents"
            )
        }
    }

    static func computeGenerationID(
        identity: BuildingStoredIdentity,
        recordsTreeDigest: String,
        cadTreeDigest: String,
        editorStateSHA256: String,
        editorStateByteCount: Int,
        assetResourcesTreeDigest: String,
        fileCount: Int,
        totalByteCount: Int
    ) -> String {
        let canonical = """
        building-project-generation-v1
        \(identity.cadRevision)
        \(identity.cadContentSHA256)
        \(identity.cadModelSHA256)
        \(identity.recordsProjectID.description.lowercased())
        \(identity.recordsRevision)
        \(recordsTreeDigest)
        \(cadTreeDigest)
        \(editorStateSHA256)
        \(editorStateByteCount)
        \(assetResourcesTreeDigest)
        \(fileCount)
        \(totalByteCount)
        """
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct BuildingProjectManifest: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let projectID: ProjectID
    public let generationID: String
    public let sequence: Int
    public let previousGenerationID: String?
    public let publishedAt: Date
    public let commitID: BuildingCommitID
    public let identity: BuildingStoredIdentity
    public let recordsTreeDigest: String
    public let cadTreeDigest: String
    public let editorStateSHA256: String
    public let editorStateByteCount: Int
    public let assetResourcesTreeDigest: String

    init(
        schemaVersion: Int = 1,
        projectID: ProjectID,
        generationID: String,
        sequence: Int,
        previousGenerationID: String?,
        publishedAt: Date,
        commitID: BuildingCommitID,
        identity: BuildingStoredIdentity,
        recordsTreeDigest: String,
        cadTreeDigest: String,
        editorStateSHA256: String,
        editorStateByteCount: Int,
        assetResourcesTreeDigest: String
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.generationID = generationID
        self.sequence = sequence
        self.previousGenerationID = previousGenerationID
        self.publishedAt = publishedAt
        self.commitID = commitID
        self.identity = identity
        self.recordsTreeDigest = recordsTreeDigest
        self.cadTreeDigest = cadTreeDigest
        self.editorStateSHA256 = editorStateSHA256
        self.editorStateByteCount = editorStateByteCount
        self.assetResourcesTreeDigest = assetResourcesTreeDigest
    }

    func validate(limits: BuildingProjectLimits) throws {
        guard schemaVersion == 1 else {
            throw BuildingProjectError.unsupportedSchema(schemaVersion)
        }
        try identity.validated()
        guard projectID == identity.recordsProjectID else {
            throw BuildingProjectError.invalidIdentity("the manifest project identity does not match records")
        }
        guard BuildingStoredIdentity.isSHA256Hex(generationID),
              BuildingStoredIdentity.isSHA256Hex(recordsTreeDigest),
              BuildingStoredIdentity.isSHA256Hex(cadTreeDigest),
              BuildingStoredIdentity.isSHA256Hex(editorStateSHA256),
              BuildingStoredIdentity.isSHA256Hex(assetResourcesTreeDigest) else {
            throw BuildingProjectError.manifestCorrupted("a manifest digest is invalid")
        }
        guard sequence >= 1 else {
            throw BuildingProjectError.manifestCorrupted("the manifest sequence must be positive")
        }
        if sequence == 1 {
            guard previousGenerationID == nil else {
                throw BuildingProjectError.manifestCorrupted("the first generation must not have a previous generation")
            }
        } else {
            guard let previousGenerationID,
                  BuildingStoredIdentity.isSHA256Hex(previousGenerationID) else {
                throw BuildingProjectError.manifestCorrupted("a later generation must name its previous generation")
            }
        }
        guard editorStateByteCount >= 0, editorStateByteCount <= limits.maxEditorStateBytes else {
            throw BuildingProjectError.budgetExceeded("the manifest editor state is over budget")
        }
    }
}

public struct BuildingProjectJournal: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case staging
        case staged
        case completed
        case abandoned
        case conflict
        case failed
        case cancelled
    }

    public let schemaVersion: Int
    public let commitID: BuildingCommitID
    public let expectedGenerationID: String?
    public let stagingName: String
    public let identity: BuildingStoredIdentity
    public let createdAt: Date
    public private(set) var candidateGenerationID: String?
    public private(set) var state: State
    public private(set) var message: String
    public private(set) var updatedAt: Date

    init(
        schemaVersion: Int = 1,
        commitID: BuildingCommitID,
        expectedGenerationID: String?,
        stagingName: String,
        identity: BuildingStoredIdentity,
        createdAt: Date,
        candidateGenerationID: String?,
        state: State,
        message: String,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.commitID = commitID
        self.expectedGenerationID = expectedGenerationID
        self.stagingName = stagingName
        self.identity = identity
        self.createdAt = createdAt
        self.candidateGenerationID = candidateGenerationID
        self.state = state
        self.message = message
        self.updatedAt = updatedAt
    }

    mutating func update(
        state: State,
        candidateGenerationID: String? = nil,
        message: String = "",
        at date: Date = Date()
    ) {
        self.state = state
        if let candidateGenerationID {
            self.candidateGenerationID = candidateGenerationID
        }
        self.message = message
        self.updatedAt = date
    }

    func validate(limits: BuildingProjectLimits) throws {
        guard schemaVersion == 1 else {
            throw BuildingProjectError.unsupportedSchema(schemaVersion)
        }
        try identity.validated()
        guard stagingName == commitID.rawValue else {
            throw BuildingProjectError.journalUnreadable("the staging name does not match the commit identifier")
        }
        if let expectedGenerationID {
            guard BuildingStoredIdentity.isSHA256Hex(expectedGenerationID) else {
                throw BuildingProjectError.journalUnreadable("the expected generation is not a SHA-256 digest")
            }
        }
        if let candidateGenerationID {
            guard BuildingStoredIdentity.isSHA256Hex(candidateGenerationID) else {
                throw BuildingProjectError.journalUnreadable("the candidate generation is not a SHA-256 digest")
            }
        }
        guard message.utf8.count <= limits.maxJournalBytes else {
            throw BuildingProjectError.budgetExceeded("the journal message is over budget")
        }
    }
}

public struct BuildingProjectCommitRequest: Sendable {
    public let commitID: BuildingCommitID
    public let expectedGeneration: BuildingGenerationExpectation
    public let identity: BuildingStoredIdentity
    public let recordsSnapshot: ProjectRecordsSnapshot
    public let cadDirectoryURL: URL
    public let assetResourcesDirectoryURL: URL?
    public let editorState: Data
    public let note: String

    public init(
        commitID: BuildingCommitID = BuildingCommitID(),
        expectedGeneration: BuildingGenerationExpectation,
        identity: BuildingStoredIdentity,
        recordsSnapshot: ProjectRecordsSnapshot,
        cadDirectoryURL: URL,
        assetResourcesDirectoryURL: URL? = nil,
        editorState: Data = Data("{}".utf8),
        note: String = ""
    ) {
        self.commitID = commitID
        self.expectedGeneration = expectedGeneration
        self.identity = identity
        self.recordsSnapshot = recordsSnapshot
        self.cadDirectoryURL = cadDirectoryURL
        self.assetResourcesDirectoryURL = assetResourcesDirectoryURL
        self.editorState = editorState
        self.note = note
    }
}

public struct BuildingProjectCommitProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case inspecting
        case copyingCAD
        case copyingRecords
        case copyingAssetResources
        case copyingEditorState
        case verifying
        case publishing
    }

    public let phase: Phase
    public let completedFiles: Int
    public let totalFiles: Int

    public init(phase: Phase, completedFiles: Int, totalFiles: Int) {
        self.phase = phase
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
    }
}

public struct BuildingProjectGeneration: Sendable, Hashable {
    public let record: BuildingGenerationRecord
    public let directoryURL: URL
    public let recordsDirectoryURL: URL
    public let cadDirectoryURL: URL
    public let editorStateURL: URL
    public let assetResourcesDirectoryURL: URL
    public let sequence: Int?
    public let publishedAt: Date?

    init(
        record: BuildingGenerationRecord,
        directoryURL: URL,
        recordsDirectoryURL: URL,
        cadDirectoryURL: URL,
        editorStateURL: URL,
        assetResourcesDirectoryURL: URL,
        sequence: Int?,
        publishedAt: Date?
    ) {
        self.record = record
        self.directoryURL = directoryURL
        self.recordsDirectoryURL = recordsDirectoryURL
        self.cadDirectoryURL = cadDirectoryURL
        self.editorStateURL = editorStateURL
        self.assetResourcesDirectoryURL = assetResourcesDirectoryURL
        self.sequence = sequence
        self.publishedAt = publishedAt
    }

    public var generationID: String { record.generationID }
    public var projectID: ProjectID { record.projectID }
    public var identity: BuildingStoredIdentity { record.identity }
    public var fileCount: Int { record.fileCount }
    public var totalByteCount: Int { record.totalByteCount }
}

public struct BuildingProjectCommitResult: Sendable, Hashable {
    public let manifest: BuildingProjectManifest
    public let generation: BuildingProjectGeneration
    public let wasAlreadyPublished: Bool

    init(
        manifest: BuildingProjectManifest,
        generation: BuildingProjectGeneration,
        wasAlreadyPublished: Bool
    ) {
        self.manifest = manifest
        self.generation = generation
        self.wasAlreadyPublished = wasAlreadyPublished
    }
}

public struct BuildingProjectWorkingCopyMetadata: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let workingCopyID: String
    public let baseGenerationID: String?
    public let baseProjectID: ProjectID?
    public let baseRecordsRevision: Int?
    public let pendingCommitID: BuildingCommitID?
    public let lastAcknowledgedCommitID: BuildingCommitID?
    public let createdAt: Date
    public let updatedAt: Date

    init(
        schemaVersion: Int = 1,
        workingCopyID: String,
        baseGenerationID: String?,
        baseProjectID: ProjectID?,
        baseRecordsRevision: Int?,
        pendingCommitID: BuildingCommitID?,
        lastAcknowledgedCommitID: BuildingCommitID?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.workingCopyID = workingCopyID
        self.baseGenerationID = baseGenerationID
        self.baseProjectID = baseProjectID
        self.baseRecordsRevision = baseRecordsRevision
        self.pendingCommitID = pendingCommitID
        self.lastAcknowledgedCommitID = lastAcknowledgedCommitID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BuildingProjectWorkingCopy: Sendable, Hashable {
    public let metadata: BuildingProjectWorkingCopyMetadata
    public let directoryURL: URL
    public let recordsDirectoryURL: URL
    public let cadDirectoryURL: URL
    public let editorStateURL: URL
    public let assetResourcesDirectoryURL: URL

    init(
        metadata: BuildingProjectWorkingCopyMetadata,
        directoryURL: URL,
        recordsDirectoryURL: URL,
        cadDirectoryURL: URL,
        editorStateURL: URL,
        assetResourcesDirectoryURL: URL
    ) {
        self.metadata = metadata
        self.directoryURL = directoryURL
        self.recordsDirectoryURL = recordsDirectoryURL
        self.cadDirectoryURL = cadDirectoryURL
        self.editorStateURL = editorStateURL
        self.assetResourcesDirectoryURL = assetResourcesDirectoryURL
    }

    public var workingCopyID: String { metadata.workingCopyID }
    public var baseGenerationID: String? { metadata.baseGenerationID }
    public var pendingCommitID: BuildingCommitID? { metadata.pendingCommitID }
    public var lastAcknowledgedCommitID: BuildingCommitID? { metadata.lastAcknowledgedCommitID }
}

public enum BuildingProjectRecoveryAction: String, Sendable {
    case reportOnly
    case resumeUnpublished
    case abandonUnpublished
}

public enum BuildingProjectRecoveryOutcome: String, Sendable, Hashable {
    case completedAfterManifest
    case readyToResume
    case resumed
    case abandoned
    case incomplete
    case conflict
    case corrupted
    case missing
    case orphanStaging
}

public struct BuildingProjectRecoveryEntry: Sendable, Hashable {
    public let commitID: BuildingCommitID?
    public let generationID: String?
    public let journalState: BuildingProjectJournal.State?
    public let outcome: BuildingProjectRecoveryOutcome
    public let message: String

    init(
        commitID: BuildingCommitID?,
        generationID: String?,
        journalState: BuildingProjectJournal.State?,
        outcome: BuildingProjectRecoveryOutcome,
        message: String
    ) {
        self.commitID = commitID
        self.generationID = generationID
        self.journalState = journalState
        self.outcome = outcome
        self.message = message
    }
}

public enum BuildingWorkingCopyReconciliationOutcome: String, Sendable, Hashable {
    case acknowledgedByManifest
    case acknowledgedByJournal
    case pending
    case invalidMetadata
    case orphanedBase
}

public struct BuildingWorkingCopyReconciliation: Sendable, Hashable {
    public let workingCopyID: String?
    public let pendingCommitID: BuildingCommitID?
    public let baseGenerationID: String?
    public let outcome: BuildingWorkingCopyReconciliationOutcome
    public let message: String

    init(
        workingCopyID: String?,
        pendingCommitID: BuildingCommitID?,
        baseGenerationID: String?,
        outcome: BuildingWorkingCopyReconciliationOutcome,
        message: String
    ) {
        self.workingCopyID = workingCopyID
        self.pendingCommitID = pendingCommitID
        self.baseGenerationID = baseGenerationID
        self.outcome = outcome
        self.message = message
    }
}

public struct BuildingProjectRecoveryReport: Sendable, Hashable {
    public let currentGenerationID: String?
    public let entries: [BuildingProjectRecoveryEntry]
    public let orphanStagingNames: [String]
    public let workingCopies: [BuildingWorkingCopyReconciliation]

    init(
        currentGenerationID: String?,
        entries: [BuildingProjectRecoveryEntry],
        orphanStagingNames: [String],
        workingCopies: [BuildingWorkingCopyReconciliation]
    ) {
        self.currentGenerationID = currentGenerationID
        self.entries = entries
        self.orphanStagingNames = orphanStagingNames
        self.workingCopies = workingCopies
    }
}
