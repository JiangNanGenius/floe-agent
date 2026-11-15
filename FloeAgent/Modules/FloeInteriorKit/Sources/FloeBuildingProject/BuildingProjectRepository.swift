import Foundation
import FloeBuildingRecords

/// An independent building project store shared by the native CAD adapter and
/// the workbench. One published generation binds a saved CAD directory, a
/// consistent records snapshot, fixed editor metadata and the original asset
/// resource package. Publication is compare-and-swap on the last manifest and
/// is protected by a cross-process file lock.
public final class BuildingProjectRepository: @unchecked Sendable {
    public let rootURL: URL
    public let configuration: BuildingProjectConfiguration
    private let processLock = NSLock()

    private init(rootURL: URL, configuration: BuildingProjectConfiguration) {
        self.rootURL = rootURL
        self.configuration = configuration
    }

    public var limits: BuildingProjectLimits { configuration.limits }

    // MARK: - Open and create

    public static func create(
        at rootURL: URL,
        configuration: BuildingProjectConfiguration = .default
    ) throws -> BuildingProjectRepository {
        try configuration.validate()
        guard rootURL.isFileURL else {
            throw BuildingProjectError.invalidRoot("the root is not a file URL")
        }
        let standardized = rootURL.standardizedFileURL
        let fileManager = FileManager.default
        switch BuildingProjectFileSystem.kind(of: standardized) {
        case .missing:
            try fileManager.createDirectory(at: standardized, withIntermediateDirectories: true)
        case .directory:
            let contents = try fileManager.contentsOfDirectory(atPath: standardized.path)
            guard contents.isEmpty else {
                throw BuildingProjectError.rootAlreadyExists
            }
        case .symbolicLink:
            throw BuildingProjectError.invalidRoot("the project root must not be a symbolic link")
        case .regular, .other:
            throw BuildingProjectError.invalidRoot("the project root is not a directory")
        }
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        let repository = BuildingProjectRepository(rootURL: resolved, configuration: configuration)
        try repository.ensureLayout()
        return repository
    }

    public static func open(
        at rootURL: URL,
        configuration: BuildingProjectConfiguration = .default
    ) throws -> BuildingProjectRepository {
        try configuration.validate()
        guard rootURL.isFileURL else {
            throw BuildingProjectError.invalidRoot("the root is not a file URL")
        }
        let standardized = rootURL.standardizedFileURL
        guard BuildingProjectFileSystem.kind(of: standardized) == .directory else {
            throw BuildingProjectError.projectNotFound
        }
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        let repository = BuildingProjectRepository(rootURL: resolved, configuration: configuration)
        try repository.ensureLayout()
        return repository
    }

    private func ensureLayout() throws {
        let fileManager = FileManager.default
        for name in [
            BuildingProjectPaths.generationsDirectoryName,
            BuildingProjectPaths.stagingDirectoryName,
            BuildingProjectPaths.journalDirectoryName,
            BuildingProjectPaths.workDirectoryName,
            BuildingProjectPaths.abandonedDirectoryName
        ] {
            let url = rootURL.appendingPathComponent(name, isDirectory: true)
            switch BuildingProjectFileSystem.kind(of: url) {
            case .missing:
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            case .directory:
                break
            case .symbolicLink:
                throw BuildingProjectError.symbolicLinkRejected(url.path)
            case .regular, .other:
                throw BuildingProjectError.invalidRoot("\(name) is not a directory")
            }
        }
    }

    // MARK: - Paths

    var manifestURL: URL {
        rootURL.appendingPathComponent(BuildingProjectPaths.manifestName, isDirectory: false)
    }

    var generationsRootURL: URL {
        rootURL.appendingPathComponent(BuildingProjectPaths.generationsDirectoryName, isDirectory: true)
    }

    var stagingRootURL: URL {
        rootURL.appendingPathComponent(BuildingProjectPaths.stagingDirectoryName, isDirectory: true)
    }

    var journalRootURL: URL {
        rootURL.appendingPathComponent(BuildingProjectPaths.journalDirectoryName, isDirectory: true)
    }

    var workRootURL: URL {
        rootURL.appendingPathComponent(BuildingProjectPaths.workDirectoryName, isDirectory: true)
    }

    var abandonedRootURL: URL {
        rootURL.appendingPathComponent(BuildingProjectPaths.abandonedDirectoryName, isDirectory: true)
    }

    var lockURL: URL {
        rootURL.appendingPathComponent(BuildingProjectPaths.lockName, isDirectory: false)
    }

    func journalURL(for commitID: BuildingCommitID) -> URL {
        journalRootURL.appendingPathComponent("\(commitID.rawValue).json", isDirectory: false)
    }

    func stagingURL(for commitID: BuildingCommitID) -> URL {
        stagingRootURL.appendingPathComponent(commitID.rawValue, isDirectory: true)
    }

    // MARK: - Lock

    func withLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        let lock = try BuildingProjectFileLock.acquire(
            at: lockURL,
            exclusive: exclusive,
            timeout: configuration.lockTimeout
        )
        defer { lock.release() }
        return try body()
    }

    // MARK: - Manifest

    public func loadManifest() throws -> BuildingProjectManifest? {
        try configuration.validate()
        return try withLock(exclusive: false) {
            try readManifestUnderLock()
        }
    }

    func readManifestUnderLock() throws -> BuildingProjectManifest? {
        switch BuildingProjectFileSystem.kind(of: manifestURL) {
        case .missing:
            return nil
        case .regular:
            break
        case .symbolicLink:
            throw BuildingProjectError.manifestCorrupted("Manifest.json is a symbolic link")
        case .directory, .other:
            throw BuildingProjectError.manifestCorrupted("Manifest.json is not a regular file")
        }
        let data = try BuildingProjectFileSystem.readBounded(
            manifestURL,
            maxBytes: limits.maxManifestBytes
        )
        let manifest: BuildingProjectManifest
        do {
            manifest = try BuildingProjectJSON.decode(BuildingProjectManifest.self, from: data)
        } catch {
            throw BuildingProjectError.manifestCorrupted(String(describing: error))
        }
        try manifest.validate(limits: limits)
        return manifest
    }

    func writeManifestAndVerify(_ manifest: BuildingProjectManifest) throws {
        let data = try BuildingProjectJSON.encode(manifest)
        guard data.count <= limits.maxManifestBytes else {
            throw BuildingProjectError.budgetExceeded(
                "Manifest.json is \(data.count) bytes; the limit is \(limits.maxManifestBytes)"
            )
        }
        try BuildingProjectFileSystem.writeAtomically(data, to: manifestURL)
        guard let readback = try readManifestUnderLock(),
              manifestsEquivalent(readback, manifest) else {
            throw BuildingProjectError.manifestCorrupted("the manifest did not read back with the same state")
        }
    }

    func manifestsEquivalent(_ lhs: BuildingProjectManifest, _ rhs: BuildingProjectManifest) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.projectID == rhs.projectID
            && lhs.generationID == rhs.generationID
            && lhs.sequence == rhs.sequence
            && lhs.previousGenerationID == rhs.previousGenerationID
            && lhs.commitID == rhs.commitID
            && lhs.identity == rhs.identity
            && lhs.recordsTreeDigest == rhs.recordsTreeDigest
            && lhs.cadTreeDigest == rhs.cadTreeDigest
            && lhs.editorStateSHA256 == rhs.editorStateSHA256
            && lhs.editorStateByteCount == rhs.editorStateByteCount
            && lhs.assetResourcesTreeDigest == rhs.assetResourcesTreeDigest
            && abs(lhs.publishedAt.timeIntervalSince(rhs.publishedAt)) < 1.0
    }

    // MARK: - Generations

    public func currentGeneration(verify: Bool = true) throws -> BuildingProjectGeneration? {
        try configuration.validate()
        return try withLock(exclusive: false) {
            guard let manifest = try readManifestUnderLock() else { return nil }
            return try loadGeneration(
                manifest.generationID,
                manifest: manifest,
                verify: verify
            )
        }
    }

    public func generation(
        _ generationID: String,
        verify: Bool = true
    ) throws -> BuildingProjectGeneration {
        try configuration.validate()
        guard BuildingStoredIdentity.isSHA256Hex(generationID) else {
            throw BuildingProjectError.generationNotFound(generationID)
        }
        return try withLock(exclusive: false) {
            let manifest = try readManifestUnderLock()
            let matching = manifest?.generationID == generationID ? manifest : nil
            return try loadGeneration(generationID, manifest: matching, verify: verify)
        }
    }

    func loadGeneration(
        _ generationID: String,
        manifest: BuildingProjectManifest?,
        verify: Bool
    ) throws -> BuildingProjectGeneration {
        guard BuildingStoredIdentity.isSHA256Hex(generationID) else {
            throw BuildingProjectError.generationNotFound(generationID)
        }
        let directory = BuildingProjectPaths.generationDirectoryURL(
            root: rootURL,
            generationID: generationID
        )
        guard BuildingProjectFileSystem.kind(of: directory) == .directory else {
            throw BuildingProjectError.generationNotFound(generationID)
        }
        try BuildingProjectFileSystem.requireNoSymlinkComponents(root: rootURL, url: directory)
        let record = try readGenerationRecord(at: directory, expectedID: generationID)
        if let manifest {
            guard manifest.generationID == generationID,
                  manifest.projectID == record.projectID,
                  manifest.identity == record.identity,
                  manifest.recordsTreeDigest == record.recordsTreeDigest,
                  manifest.cadTreeDigest == record.cadTreeDigest,
                  manifest.editorStateSHA256 == record.editorStateSHA256,
                  manifest.editorStateByteCount == record.editorStateByteCount,
                  manifest.assetResourcesTreeDigest == record.assetResourcesTreeDigest else {
                throw BuildingProjectError.manifestCorrupted(
                    "Manifest.json does not match Generation.json for \(generationID)"
                )
            }
        }
        for section in BuildingFileSection.allCases {
            let root = BuildingProjectPaths.sectionRootURL(generationURL: directory, section: section)
            guard BuildingProjectFileSystem.kind(of: root) == .directory else {
                throw BuildingProjectError.generationCorrupted(
                    generationID: generationID,
                    reason: "the \(section.rawValue) directory is missing"
                )
            }
        }
        if verify {
            try verifyGenerationFiles(record, directory: directory)
        }
        return BuildingProjectGeneration(
            record: record,
            directoryURL: directory,
            recordsDirectoryURL: directory.appendingPathComponent(
                BuildingProjectPaths.recordsDirectoryName,
                isDirectory: true
            ),
            cadDirectoryURL: directory.appendingPathComponent(
                BuildingProjectPaths.cadDirectoryName,
                isDirectory: true
            ),
            editorStateURL: directory
                .appendingPathComponent(BuildingProjectPaths.editorStateDirectoryName, isDirectory: true)
                .appendingPathComponent(BuildingProjectPaths.editorStateRelativePath, isDirectory: false),
            assetResourcesDirectoryURL: directory.appendingPathComponent(
                BuildingProjectPaths.assetResourcesDirectoryName,
                isDirectory: true
            ),
            sequence: manifest?.sequence,
            publishedAt: manifest?.publishedAt
        )
    }

    func readGenerationRecord(at directory: URL) throws -> BuildingGenerationRecord {
        try BuildingProjectFileSystem.requireNoSymlinkComponents(root: rootURL, url: directory)
        let fileURL = directory.appendingPathComponent(
            BuildingProjectPaths.generationFileName,
            isDirectory: false
        )
        guard BuildingProjectFileSystem.kind(of: fileURL) == .regular else {
            throw BuildingProjectError.generationCorrupted(
                generationID: directory.lastPathComponent,
                reason: "Generation.json is missing or not a regular file"
            )
        }
        let data: Data
        do {
            data = try BuildingProjectFileSystem.readBounded(fileURL, maxBytes: limits.maxManifestBytes)
        } catch let error as BuildingProjectError {
            throw BuildingProjectError.generationCorrupted(
                generationID: directory.lastPathComponent,
                reason: error.errorDescription ?? "Generation.json is over budget"
            )
        } catch {
            throw BuildingProjectError.generationCorrupted(
                generationID: directory.lastPathComponent,
                reason: "Generation.json could not be read"
            )
        }
        let record: BuildingGenerationRecord
        do {
            record = try BuildingProjectJSON.decode(BuildingGenerationRecord.self, from: data)
        } catch {
            throw BuildingProjectError.generationCorrupted(
                generationID: directory.lastPathComponent,
                reason: "Generation.json is unreadable: \(error)"
            )
        }
        try record.validate(limits: limits)
        return record
    }

    func readGenerationRecord(
        at directory: URL,
        expectedID: String
    ) throws -> BuildingGenerationRecord {
        let record = try readGenerationRecord(at: directory)
        guard record.generationID == expectedID else {
            throw BuildingProjectError.generationCorrupted(
                generationID: expectedID,
                reason: "Generation.json names a different generation"
            )
        }
        return record
    }

    func verifyGenerationFiles(
        _ record: BuildingGenerationRecord,
        directory: URL
    ) throws {
        let allowed: Set<String> = [
            BuildingProjectPaths.generationFileName,
            BuildingProjectPaths.recordsDirectoryName,
            BuildingProjectPaths.cadDirectoryName,
            BuildingProjectPaths.editorStateDirectoryName,
            BuildingProjectPaths.assetResourcesDirectoryName
        ]
        let names = try BuildingProjectFileSystem.listDirectoryNames(directory)
        guard Set(names) == allowed else {
            throw BuildingProjectError.generationCorrupted(
                generationID: record.generationID,
                reason: "the generation directory contains unexpected entries"
            )
        }
        for section in BuildingFileSection.allCases {
            let root = BuildingProjectPaths.sectionRootURL(generationURL: directory, section: section)
            guard BuildingProjectFileSystem.kind(of: root) == .directory else {
                throw BuildingProjectError.generationCorrupted(
                    generationID: record.generationID,
                    reason: "the \(section.rawValue) directory is missing"
                )
            }
            try BuildingProjectFileSystem.requireNoSymlinkComponents(root: rootURL, url: root)
            let expected = record.files.filter { $0.section == section }
            let actual = try BuildingProjectFileSystem.hashTree(
                root: root,
                section: section,
                limits: limits,
                isCancelled: { false }
            )
            guard actual == expected else {
                throw BuildingProjectError.generationCorrupted(
                    generationID: record.generationID,
                    reason: "the \(section.rawValue) files do not match Generation.json"
                )
            }
        }
    }

    // MARK: - Working copies

    public func createWorkingCopy(
        initialProjectName: String? = nil,
        from generationID: String? = nil,
        initialEditorState: Data = Data("{}".utf8),
        cancellation: BuildingProjectCancellation? = nil
    ) throws -> BuildingProjectWorkingCopy {
        try configuration.validate()
        if let cancellation { try cancellation.check() }

        let base: BuildingProjectGeneration?
        if let generationID {
            base = try generation(generationID)
        } else {
            base = try currentGeneration()
        }
        if base == nil, initialProjectName == nil {
            throw BuildingProjectError.noPublishedGeneration
        }
        if base != nil, initialProjectName != nil {
            throw BuildingProjectError.invalidWorkingCopy(
                "initialProjectName is only valid when the repository has no published generation"
            )
        }

        let workingCopyID = UUID().uuidString.lowercased()
        let directory = workRootURL.appendingPathComponent(workingCopyID, isDirectory: true)
        guard BuildingProjectFileSystem.kind(of: directory) == .missing else {
            throw BuildingProjectError.ioFailure("the generated working copy directory already exists")
        }
        try BuildingProjectFileSystem.ensureDirectory(directory)
        var keep = false
        defer {
            if !keep {
                try? BuildingProjectFileSystem.removeTree(directory)
            }
        }

        let recordsDirectory = directory.appendingPathComponent(
            BuildingProjectPaths.recordsDirectoryName,
            isDirectory: true
        )
        let cadDirectory = directory.appendingPathComponent(
            BuildingProjectPaths.cadDirectoryName,
            isDirectory: true
        )
        let editorStateDirectory = directory.appendingPathComponent(
            BuildingProjectPaths.editorStateDirectoryName,
            isDirectory: true
        )
        let assetResourcesDirectory = directory.appendingPathComponent(
            BuildingProjectPaths.assetResourcesDirectoryName,
            isDirectory: true
        )

        let metadata: BuildingProjectWorkingCopyMetadata
        if let base {
            try copyVerifiedSection(
                from: base.recordsDirectoryURL,
                to: recordsDirectory,
                section: .records,
                expected: base.record.files.filter { $0.section == .records },
                cancellation: cancellation
            )
            try copyVerifiedSection(
                from: base.cadDirectoryURL,
                to: cadDirectory,
                section: .cad,
                expected: base.record.files.filter { $0.section == .cad },
                cancellation: cancellation
            )
            try copyVerifiedSection(
                from: base.directoryURL.appendingPathComponent(
                    BuildingProjectPaths.editorStateDirectoryName,
                    isDirectory: true
                ),
                to: editorStateDirectory,
                section: .editorState,
                expected: base.record.files.filter { $0.section == .editorState },
                cancellation: cancellation
            )
            try copyVerifiedSection(
                from: base.assetResourcesDirectoryURL,
                to: assetResourcesDirectory,
                section: .assetResources,
                expected: base.record.files.filter { $0.section == .assetResources },
                cancellation: cancellation
            )
            metadata = BuildingProjectWorkingCopyMetadata(
                workingCopyID: workingCopyID,
                baseGenerationID: base.generationID,
                baseProjectID: base.projectID,
                baseRecordsRevision: base.identity.recordsRevision,
                pendingCommitID: nil,
                lastAcknowledgedCommitID: nil,
                createdAt: normalizedNow(),
                updatedAt: normalizedNow()
            )
        } else {
            let name = initialProjectName ?? ""
            try BuildingProjectFileSystem.ensureDirectory(recordsDirectory)
            let store = try ProjectRecordsStore.createProject(at: recordsDirectory, name: name)
            let projectID = store.projectID
            try store.close()
            try BuildingProjectFileSystem.ensureDirectory(cadDirectory)
            try BuildingProjectFileSystem.ensureDirectory(editorStateDirectory)
            try BuildingProjectFileSystem.ensureDirectory(assetResourcesDirectory)
            try writeWorkingCopyEditorState(
                initialEditorState,
                to: editorStateDirectory.appendingPathComponent(
                    BuildingProjectPaths.editorStateRelativePath,
                    isDirectory: false
                )
            )
            metadata = BuildingProjectWorkingCopyMetadata(
                workingCopyID: workingCopyID,
                baseGenerationID: nil,
                baseProjectID: projectID,
                baseRecordsRevision: 0,
                pendingCommitID: nil,
                lastAcknowledgedCommitID: nil,
                createdAt: normalizedNow(),
                updatedAt: normalizedNow()
            )
        }

        let metadataURL = directory.appendingPathComponent(
            BuildingProjectPaths.workingCopyFileName,
            isDirectory: false
        )
        let metadataData = try BuildingProjectJSON.encode(metadata)
        guard metadataData.count <= limits.maxManifestBytes else {
            throw BuildingProjectError.budgetExceeded("WorkingCopy.json is over budget")
        }
        try BuildingProjectFileSystem.writeAtomically(metadataData, to: metadataURL)
        keep = true
        return BuildingProjectWorkingCopy(
            metadata: metadata,
            directoryURL: directory,
            recordsDirectoryURL: recordsDirectory,
            cadDirectoryURL: cadDirectory,
            editorStateURL: editorStateDirectory.appendingPathComponent(
                BuildingProjectPaths.editorStateRelativePath,
                isDirectory: false
            ),
            assetResourcesDirectoryURL: assetResourcesDirectory
        )
    }

    public func discardWorkingCopy(_ copy: BuildingProjectWorkingCopy) throws {
        try configuration.validate()
        try withLock(exclusive: true) {
            let (directory, metadata) = try readWorkingCopyMetadata(copy)
            if let pending = metadata.pendingCommitID {
                throw BuildingProjectError.workingCopySaveInProgress(pending)
            }
            try BuildingProjectFileSystem.removeTree(directory)
        }
    }

    func copyVerifiedSection(
        from sourceRoot: URL,
        to destinationRoot: URL,
        section: BuildingFileSection,
        expected: [BuildingFileRecord],
        cancellation: BuildingProjectCancellation?
    ) throws -> [BuildingFileRecord] {
        let isCancelled: @Sendable () -> Bool = { cancellation?.isCancelled ?? false }
        let inspected = try BuildingProjectFileSystem.inspectTree(
            root: sourceRoot,
            section: section,
            limits: limits,
            isCancelled: isCancelled
        )
        guard inspected.count == expected.count else {
            throw BuildingProjectError.generationCorrupted(
                generationID: "working-copy",
                reason: "the \(section.rawValue) source file count changed"
            )
        }
        let sortedExpected = expected.sorted { $0.relativePath < $1.relativePath }
        for (entry, record) in zip(inspected, sortedExpected) {
            guard entry.relativePath == record.relativePath,
                  entry.byteCount == record.byteCount else {
                throw BuildingProjectError.generationCorrupted(
                    generationID: "working-copy",
                    reason: "the \(section.rawValue) source metadata changed"
                )
            }
        }
        let copied = try BuildingProjectFileSystem.copyTree(
            from: sourceRoot,
            to: destinationRoot,
            section: section,
            inspected: inspected,
            limits: limits,
            isCancelled: isCancelled,
            progress: nil
        )
        guard copied == sortedExpected else {
            throw BuildingProjectError.generationCorrupted(
                generationID: "working-copy",
                reason: "the \(section.rawValue) files did not match the published generation"
            )
        }
        return copied
    }

    func validatedEditorState(_ data: Data) throws -> Data {
        guard data.count <= limits.maxEditorStateBytes else {
            throw BuildingProjectError.budgetExceeded(
                "editor state is \(data.count) bytes; the limit is \(limits.maxEditorStateBytes)"
            )
        }
        guard !data.isEmpty else {
            throw BuildingProjectError.editorStateInvalid("the editor state must not be empty")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard object is [String: Any] else {
                throw BuildingProjectError.editorStateInvalid("the editor state must be a JSON object")
            }
        } catch let error as BuildingProjectError {
            throw error
        } catch {
            throw BuildingProjectError.editorStateInvalid("the editor state is not valid JSON")
        }
        return data
    }

    func writeWorkingCopyEditorState(_ data: Data, to url: URL) throws {
        let validated = try validatedEditorState(data)
        try BuildingProjectFileSystem.writeAtomically(validated, to: url)
    }

    // MARK: - Input paths and shared helpers

    func canonicalInputDirectory(_ url: URL, label: String) throws -> URL {
        guard url.isFileURL else {
            throw BuildingProjectError.ioFailure("\(label) is not a file URL")
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard BuildingProjectFileSystem.kind(of: resolved) == .directory else {
            throw BuildingProjectError.ioFailure("\(label) is missing or not a directory")
        }
        if resolved == rootURL || BuildingProjectPaths.isSameOrAncestor(resolved, of: rootURL) {
            throw BuildingProjectError.pathEscapesRoot("\(label) must not contain the project root")
        }
        for internalRoot in [
            generationsRootURL,
            abandonedRootURL,
            stagingRootURL,
            journalRootURL
        ] {
            if BuildingProjectPaths.isSameOrAncestor(internalRoot, of: resolved) {
                throw BuildingProjectError.pathEscapesRoot(
                    "\(label) must not point inside a published or journal directory"
                )
            }
        }
        return resolved
    }

    func readJournal(at url: URL) throws -> BuildingProjectJournal {
        guard BuildingProjectFileSystem.kind(of: url) == .regular else {
            throw BuildingProjectError.journalUnreadable(url.lastPathComponent)
        }
        let data = try BuildingProjectFileSystem.readBounded(url, maxBytes: limits.maxJournalBytes)
        let journal: BuildingProjectJournal
        do {
            journal = try BuildingProjectJSON.decode(BuildingProjectJournal.self, from: data)
        } catch {
            throw BuildingProjectError.journalUnreadable(url.lastPathComponent)
        }
        try journal.validate(limits: limits)
        guard url.deletingPathExtension().lastPathComponent == journal.commitID.rawValue else {
            throw BuildingProjectError.journalUnreadable(url.lastPathComponent)
        }
        return journal
    }

    func writeJournal(_ journal: BuildingProjectJournal) throws {
        try journal.validate(limits: limits)
        let data = try BuildingProjectJSON.encode(journal)
        guard data.count <= limits.maxJournalBytes else {
            throw BuildingProjectError.budgetExceeded("the commit journal is over budget")
        }
        try BuildingProjectFileSystem.writeAtomically(data, to: journalURL(for: journal.commitID))
    }

    func journalURLs() throws -> [URL] {
        let names = try BuildingProjectFileSystem.listDirectoryNames(journalRootURL)
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .map { journalRootURL.appendingPathComponent($0, isDirectory: false) }
    }

    func pendingJournalCommitIDs(excluding commitID: BuildingCommitID?) throws -> [String] {
        var result: [String] = []
        let urls = try journalURLs()
        for url in urls {
            do {
                let journal = try readJournal(at: url)
                if journal.commitID != commitID,
                   journal.state == .staging || journal.state == .staged {
                    result.append(journal.commitID.rawValue)
                }
            } catch {
                result.append(url.deletingPathExtension().lastPathComponent)
            }
        }
        return result.sorted()
    }

    func normalizedNow() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    func makeManifest(
        record: BuildingGenerationRecord,
        sequence: Int,
        previousGenerationID: String?,
        commitID: BuildingCommitID,
        publishedAt: Date
    ) -> BuildingProjectManifest {
        BuildingProjectManifest(
            projectID: record.projectID,
            generationID: record.generationID,
            sequence: sequence,
            previousGenerationID: previousGenerationID,
            publishedAt: publishedAt,
            commitID: commitID,
            identity: record.identity,
            recordsTreeDigest: record.recordsTreeDigest,
            cadTreeDigest: record.cadTreeDigest,
            editorStateSHA256: record.editorStateSHA256,
            editorStateByteCount: record.editorStateByteCount,
            assetResourcesTreeDigest: record.assetResourcesTreeDigest
        )
    }

    func generationRecord(
        identity: BuildingStoredIdentity,
        commitID: BuildingCommitID,
        createdAt: Date,
        recordsTreeDigest: String,
        cadTreeDigest: String,
        editorStateSHA256: String,
        editorStateByteCount: Int,
        assetResourcesTreeDigest: String,
        files: [BuildingFileRecord]
    ) -> BuildingGenerationRecord {
        let sorted = files.sorted {
            let lhs = "\($0.section.rawValue)\u{0}\($0.relativePath)"
            let rhs = "\($1.section.rawValue)\u{0}\($1.relativePath)"
            return lhs < rhs
        }
        let total = sorted.reduce(0) { $0 + $1.byteCount }
        let generationID = BuildingGenerationRecord.computeGenerationID(
            identity: identity,
            recordsTreeDigest: recordsTreeDigest,
            cadTreeDigest: cadTreeDigest,
            editorStateSHA256: editorStateSHA256,
            editorStateByteCount: editorStateByteCount,
            assetResourcesTreeDigest: assetResourcesTreeDigest,
            fileCount: sorted.count,
            totalByteCount: total
        )
        return BuildingGenerationRecord(
            generationID: generationID,
            projectID: identity.recordsProjectID,
            identity: identity,
            commitID: commitID,
            createdAt: createdAt,
            recordsTreeDigest: recordsTreeDigest,
            cadTreeDigest: cadTreeDigest,
            editorStateSHA256: editorStateSHA256,
            editorStateByteCount: editorStateByteCount,
            assetResourcesTreeDigest: assetResourcesTreeDigest,
            fileCount: sorted.count,
            totalByteCount: total,
            files: sorted
        )
    }

    func recordMatchesContent(_ lhs: BuildingGenerationRecord, _ rhs: BuildingGenerationRecord) -> Bool {
        lhs.generationID == rhs.generationID
            && lhs.identity == rhs.identity
            && lhs.projectID == rhs.projectID
            && lhs.recordsTreeDigest == rhs.recordsTreeDigest
            && lhs.cadTreeDigest == rhs.cadTreeDigest
            && lhs.editorStateSHA256 == rhs.editorStateSHA256
            && lhs.editorStateByteCount == rhs.editorStateByteCount
            && lhs.assetResourcesTreeDigest == rhs.assetResourcesTreeDigest
            && lhs.fileCount == rhs.fileCount
            && lhs.totalByteCount == rhs.totalByteCount
            && lhs.files == rhs.files
    }
}
