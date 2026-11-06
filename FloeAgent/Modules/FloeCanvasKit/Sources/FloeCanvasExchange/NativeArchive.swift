// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore
import FloeCanvasIntegration
import ZIPFoundation

/// Complete native laboratory archive (`.floecanvaslab`). This is the
/// recovery authority for canvas content: every page, group, region, scene,
/// flow graph, source reference, annotation, structured/rich/shape content,
/// stroke and PencilKit payload round-trips losslessly, plus the exact bytes
/// of every referenced asset, every opaque original import and every
/// archived child project. Layout:
///
///     manifest.json          versioned manifest with sha256 of every entry
///     document.json          the whole CanvasSnapshot (Codable, sorted keys)
///     assets/<assetID>       one entry per referenced asset (bytes + license)
///     sources/<id>.bin       opaque original import bytes (legacy raw,
///                            JSON Canvas / Excalidraw / draw.io originals)
///     children/<projectID>@<revision>.bin
///                            opaque professional child project archives
///
/// The archive is a plain ZIP with strict bounds: entry count (20 000),
/// per-entry size (64 MiB) and expanded total (512 MiB) are capped; absolute
/// paths, `..` traversal, symlinks and duplicate/unnormalized paths are
/// rejected on read. Writes are all-or-nothing: any integrity failure aborts
/// before bytes are produced. No code signatures, credentials or executable
/// permissions are ever stored.
public enum CanvasNativeArchive {
    public static let fileExtension = "floecanvaslab"
    public static let manifestPath = "manifest.json"
    public static let documentPath = "document.json"

    // MARK: Manifest DTOs

    public struct AssetEntry: Codable, Hashable, Sendable {
        public var id: UUID
        public var path: String
        public var byteCount: Int
        public var sha256: String
        public var mimeType: String?
        public var license: String?
        public var originalRelativePath: String?

        public init(id: UUID, path: String, byteCount: Int, sha256: String, mimeType: String? = nil, license: String? = nil, originalRelativePath: String? = nil) {
            self.id = id
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256
            self.mimeType = mimeType
            self.license = license
            self.originalRelativePath = originalRelativePath
        }
    }

    public struct SourceEntry: Codable, Hashable, Sendable {
        public var id: UUID
        public var kind: CanvasOriginalSource.Kind
        public var path: String
        public var suggestedName: String
        public var byteCount: Int
        public var sha256: String
        public var nodeIDs: [UUID]

        public init(id: UUID, kind: CanvasOriginalSource.Kind, path: String, suggestedName: String, byteCount: Int, sha256: String, nodeIDs: [UUID]) {
            self.id = id
            self.kind = kind
            self.path = path
            self.suggestedName = suggestedName
            self.byteCount = byteCount
            self.sha256 = sha256
            self.nodeIDs = nodeIDs
        }
    }

    public struct ChildEntry: Codable, Hashable, Sendable {
        public var projectID: UUID
        public var editorKind: String
        public var appliedRevision: Int64
        public var path: String
        public var byteCount: Int
        public var sha256: String
        public var formatHint: String?

        public init(projectID: UUID, editorKind: String, appliedRevision: Int64, path: String, byteCount: Int, sha256: String, formatHint: String? = nil) {
            self.projectID = projectID
            self.editorKind = editorKind
            self.appliedRevision = appliedRevision
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256
            self.formatHint = formatHint
        }
    }

    // MARK: Reusable flow template definitions

    /// A reusable, versioned flow template definition embedded in the
    /// archive. This is a pure serialization envelope owned by the exchange
    /// module: it stores and verifies the exact Core data fields (the same
    /// six fields a host maps to/from its runtime `FlowSubgraphTemplate`
    /// registry). The archive never interprets or executes template graphs,
    /// never adopts credentials, and never grants execution authority.
    public struct FlowTemplateDefinition: Codable, Hashable, Sendable {
        public var id: UUID
        public var version: Int
        public var name: String
        public var graph: FlowGraph
        public var exposedPorts: [FlowPort]

        public init(id: UUID = UUID(), version: Int = 1, name: String, graph: FlowGraph, exposedPorts: [FlowPort] = []) {
            self.id = id
            self.version = version
            self.name = name
            self.graph = graph
            self.exposedPorts = exposedPorts
        }
    }

    /// Manifest descriptor for one embedded template definition file.
    public struct TemplateEntry: Codable, Hashable, Sendable {
        public var id: UUID
        public var version: Int
        public var path: String
        public var byteCount: Int
        public var sha256: String
        public var name: String?

        public init(id: UUID, version: Int, path: String, byteCount: Int, sha256: String, name: String? = nil) {
            self.id = id
            self.version = version
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256
            self.name = name
        }
    }

    public struct Manifest: Codable, Hashable, Sendable {
        public var format = "org.floe.canvaslab"
        public var version = 1
        public var generator = "FloeCanvasExchange"
        public var canvasID: UUID
        public var canvasName: String
        public var canvasRevision: Int64
        public var schemaVersion: Int
        public var pageCount: Int
        public var createdAt: Date
        public var documentPath = CanvasNativeArchive.documentPath
        public var documentByteCount: Int
        public var documentSHA256: String
        public var assets: [AssetEntry]
        public var sources: [SourceEntry]
        public var children: [ChildEntry]
        /// Embedded reusable flow template definitions. Absent in archives
        /// written before templates existed — decodes as empty, so old
        /// archives stay valid.
        public var flowTemplates: [TemplateEntry] = []

        public init(canvasID: UUID, canvasName: String, canvasRevision: Int64, schemaVersion: Int, pageCount: Int, createdAt: Date = Date(), documentByteCount: Int, documentSHA256: String, assets: [AssetEntry] = [], sources: [SourceEntry] = [], children: [ChildEntry] = [], flowTemplates: [TemplateEntry] = []) {
            self.canvasID = canvasID
            self.canvasName = canvasName
            self.canvasRevision = canvasRevision
            self.schemaVersion = schemaVersion
            self.pageCount = pageCount
            self.createdAt = createdAt
            self.documentByteCount = documentByteCount
            self.documentSHA256 = documentSHA256
            self.assets = assets
            self.sources = sources
            self.children = children
            self.flowTemplates = flowTemplates
        }
    }

    // MARK: Original source envelopes

    /// Original bytes plus the manifest metadata describing them.
    public struct OriginalSourceEnvelope: Sendable {
        public var source: CanvasOriginalSource
        public var data: Data
        public init(source: CanvasOriginalSource, data: Data) {
            self.source = source
            self.data = data
        }

        /// Wraps a legacy adapter result so its raw bytes (the compatibility
        /// authority) travel inside the archive.
        public init(legacy result: LegacyImportResult) {
            let digest = CanvasDigest.sha256(result.rawBytes)
            self.source = CanvasOriginalSource(
                id: result.snapshot.id,
                kind: .legacyRawBytes,
                suggestedName: "\(result.snapshot.id.uuidString).legacy.json",
                byteCount: result.rawBytes.count,
                sha256: digest,
                nodeIDs: result.snapshot.pages.flatMap { $0.nodes.map(\.id) }
            )
            self.data = result.rawBytes
        }
    }

    // MARK: Child project archiving (host-provided)

    /// Opaque archive bytes for one professional child project, produced by
    /// the host's own editor export channel. The exchange module treats
    /// them as opaque: it never interprets or executes them.
    public struct ChildProjectArchiveData: Sendable {
        public var data: Data
        /// Media type or format hint the host can use on recovery.
        public var formatHint: String?
        public init(data: Data, formatHint: String? = nil) {
            self.data = data
            self.formatHint = formatHint
        }
    }

    /// Host channel that archives a child project at an exact revision.
    /// Defined here (not in Core) so the exchange contract is usable before
    /// the Core protocol lands; hosts conform at the integration layer.
    public protocol CanvasChildProjectExportProvider: Sendable {
        func archive(projectID: UUID, appliedRevision: Int64, draftRevision: Int64?, editorKind: String) async throws -> ChildProjectArchiveData
    }

    /// A child project recovered from an archive.
    public struct RecoveredChildProject: Sendable {
        public var projectID: UUID
        public var editorKind: String
        public var appliedRevision: Int64
        public var formatHint: String?
        public var sha256: String
        public var data: Data
    }

    // MARK: Export

    public struct ExportResult: Sendable {
        public var data: Data
        public var manifest: Manifest
        public var issues: [CanvasExchangeIssue]
    }

    /// Packs the snapshot, every referenced asset (resolved through the
    /// injected resolver), every child project (through the injected host
    /// provider) and every supplied original source into one archive.
    ///
    /// Integrity is strict: when a locator carries a content hash that the
    /// resolved bytes do not match, the export FAILS — the host must refresh
    /// the asset and commit a new canvas revision first; the export never
    /// silently adopts changed bytes under an old hash. When the snapshot
    /// references assets or child projects and the matching provider is
    /// missing, the export fails loudly rather than producing an archive
    /// that cannot reopen offline.
    public static func export(
        _ snapshot: CanvasSnapshot,
        assetResolver: (any CanvasAssetResolver)? = nil,
        childProjectProvider: (any CanvasChildProjectExportProvider)? = nil,
        originalSources: [OriginalSourceEnvelope] = [],
        flowTemplates: [FlowTemplateDefinition] = [],
        stagedByteBudget: Int? = nil
    ) async throws -> ExportResult {
        // Reusable template completeness is checked first: only definitions
        // REACHABLE from the snapshot graphs (transitively, through nested
        // template graphs) may be embedded — a larger host registry never
        // leaks unrelated templates into the archive. Missing referenced
        // definitions fail the export; nothing executable is interpreted.
        let templateResolution = try CanvasFlowTemplateSupport.resolve(
            referencedIn: snapshot,
            from: flowTemplates
        )

        // Reference completeness is checked before anything is encoded;
        // template graphs contribute their own typed asset references.
        let documentReferences = try CanvasAssetReferences.collect(from: snapshot)
        let templateReferences = try CanvasAssetReferences.collect(from: templateResolution.definitions.map(\.graph))
        let references = try CanvasAssetReferences.merge(documentReferences, templateReferences)
        let editorReferences = try CanvasAssetReferences.collectEditorReferences(from: snapshot)
        guard references.isEmpty || assetResolver != nil else {
            throw CanvasExchangeError.assetUnavailable(
                "snapshot references \(references.count) assets; an asset resolver is required so the archive can reopen without the original files"
            )
        }
        guard editorReferences.isEmpty || childProjectProvider != nil else {
            throw CanvasExchangeError.assetUnavailable(
                "snapshot references \(editorReferences.count) child project(s) (\(editorReferences.map(\.projectID.uuidString).joined(separator: ", "))); a CanvasChildProjectExportProvider is required — a bare projectID is not an offline-reopenable project"
            )
        }

        let documentData = try CanvasExchangeJSON.encode(snapshot)
        let documentDigest = CanvasDigest.sha256(documentData)

        // Staged-bytes budget: every entry is accounted BEFORE it lands in
        // `entries`, so an over-budget archive fails as soon as the budget is
        // crossed — never after pulling every referenced byte into memory.
        // `CanvasLabZIP.pack` keeps its own outer bounds check as defense in
        // depth.
        let stagingBudget = min(
            stagedByteBudget ?? CanvasExchangeLimits.maxExpandedTotalBytes,
            CanvasExchangeLimits.maxExpandedTotalBytes
        )
        var entries: [String: Data] = [:]
        var stagedBytes = 0
        func stageEntry(_ path: String, bytes: Data) throws {
            let next = stagedBytes &+ bytes.count
            guard next <= stagingBudget else {
                throw CanvasExchangeError.limitExceeded("archive staged content exceeds the \(stagingBudget)-byte budget at \(path)")
            }
            stagedBytes = next
            entries[path] = bytes
        }
        try stageEntry(documentPath, bytes: documentData)
        var assetEntries: [AssetEntry] = []
        var seenAssetIDs: Set<UUID> = []
        var seenPaths: Set<String> = [documentPath, manifestPath]
        for locator in references.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard seenAssetIDs.insert(locator.id).inserted else { continue }
            guard let resolver = assetResolver else { continue }
            // Pre-flight the budget with the locator's declared size so an
            // over-budget asset fails before its bytes are pulled.
            if let declared = locator.byteCount, stagedBytes &+ Int(declared) > stagingBudget {
                throw CanvasExchangeError.limitExceeded("asset \(locator.id) would exceed the \(stagingBudget)-byte staging budget before resolution")
            }
            let bytes: Data
            do {
                bytes = try await resolver.data(for: locator)
            } catch {
                throw CanvasExchangeError.assetUnavailable("asset \(locator.id): \(error)")
            }
            guard bytes.count <= CanvasExchangeLimits.maxSingleEntryBytes else {
                throw CanvasExchangeError.limitExceeded("asset \(locator.id) is \(bytes.count) bytes; the single-entry limit is \(CanvasExchangeLimits.maxSingleEntryBytes)")
            }
            let digest = CanvasDigest.sha256(bytes)
            if let expected = locator.contentHash, expected != digest {
                throw CanvasExchangeError.integrity(
                    "asset \(locator.id) resolved bytes hash \(digest) but the snapshot locator records \(expected); refresh the asset through the host and commit a new canvas revision before exporting"
                )
            }
            if let expected = locator.byteCount, expected != bytes.count {
                throw CanvasExchangeError.integrity("asset \(locator.id) resolved byte count differs from the snapshot locator")
            }
            let path = "assets/\(locator.id.uuidString)"
            guard seenPaths.insert(path).inserted else {
                throw CanvasExchangeError.invalid("duplicate asset path \(path)")
            }
            try stageEntry(path, bytes: bytes)
            assetEntries.append(AssetEntry(
                id: locator.id,
                path: path,
                byteCount: bytes.count,
                sha256: digest,
                mimeType: locator.mimeType,
                license: locator.license,
                originalRelativePath: locator.relativePath
            ))
        }

        var childEntries: [ChildEntry] = []
        for reference in editorReferences.sorted(by: { $0.projectID.uuidString < $1.projectID.uuidString }) {
            guard let provider = childProjectProvider else { continue }
            let archived: ChildProjectArchiveData
            do {
                archived = try await provider.archive(
                    projectID: reference.projectID,
                    appliedRevision: reference.appliedRevision,
                    draftRevision: reference.draftRevision,
                    editorKind: reference.editorKind
                )
            } catch {
                throw CanvasExchangeError.assetUnavailable("child project \(reference.projectID): \(error)")
            }
            guard archived.data.count <= CanvasExchangeLimits.maxSingleEntryBytes else {
                throw CanvasExchangeError.limitExceeded("child project \(reference.projectID) archive is \(archived.data.count) bytes; the single-entry limit is \(CanvasExchangeLimits.maxSingleEntryBytes)")
            }
            let digest = CanvasDigest.sha256(archived.data)
            let path = "children/\(reference.projectID.uuidString)@\(reference.appliedRevision).bin"
            guard seenPaths.insert(path).inserted else {
                throw CanvasExchangeError.invalid("duplicate child project path \(path)")
            }
            try stageEntry(path, bytes: archived.data)
            childEntries.append(ChildEntry(
                projectID: reference.projectID,
                editorKind: reference.editorKind,
                appliedRevision: reference.appliedRevision,
                path: path,
                byteCount: archived.data.count,
                sha256: digest,
                formatHint: archived.formatHint
            ))
        }

        var sourceEntries: [SourceEntry] = []
        var seenSourceIDs: Set<UUID> = []
        for envelope in originalSources {
            guard seenSourceIDs.insert(envelope.source.id).inserted else {
                throw CanvasExchangeError.invalid("duplicate original source \(envelope.source.id)")
            }
            let data = envelope.data
            if stagedBytes &+ data.count > stagingBudget {
                throw CanvasExchangeError.limitExceeded("original source \(envelope.source.id) would exceed the \(stagingBudget)-byte staging budget")
            }
            guard data.count <= CanvasExchangeLimits.maxSingleEntryBytes else {
                throw CanvasExchangeError.limitExceeded("original source \(envelope.source.id) is \(data.count) bytes; the single-entry limit is \(CanvasExchangeLimits.maxSingleEntryBytes)")
            }
            let digest = CanvasDigest.sha256(data)
            guard digest == envelope.source.sha256 else {
                throw CanvasExchangeError.integrity("original source \(envelope.source.id) bytes do not match its recorded digest")
            }
            let path = "sources/\(envelope.source.id.uuidString).bin"
            guard seenPaths.insert(path).inserted else {
                throw CanvasExchangeError.invalid("duplicate original source path \(path)")
            }
            try stageEntry(path, bytes: data)
            sourceEntries.append(SourceEntry(
                id: envelope.source.id,
                kind: envelope.source.kind,
                path: path,
                suggestedName: envelope.source.suggestedName,
                byteCount: data.count,
                sha256: digest,
                nodeIDs: envelope.source.nodeIDs
            ))
        }

        // Embedded reusable template definitions, sorted by id for a
        // deterministic archive layout.
        var templateEntries: [TemplateEntry] = []
        for definition in templateResolution.definitions.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let encoded = try CanvasExchangeJSON.encode(definition)
            let digest = CanvasDigest.sha256(encoded)
            let path = "templates/\(definition.id.uuidString)@\(definition.version).json"
            guard seenPaths.insert(path).inserted else {
                throw CanvasExchangeError.invalid("duplicate flow template path \(path)")
            }
            try stageEntry(path, bytes: encoded)
            templateEntries.append(TemplateEntry(
                id: definition.id,
                version: definition.version,
                path: path,
                byteCount: encoded.count,
                sha256: digest,
                name: definition.name
            ))
        }

        let manifest = Manifest(
            canvasID: snapshot.id,
            canvasName: snapshot.name,
            canvasRevision: snapshot.revision,
            schemaVersion: snapshot.schemaVersion,
            pageCount: snapshot.pages.count,
            documentByteCount: documentData.count,
            documentSHA256: documentDigest,
            assets: assetEntries,
            sources: sourceEntries,
            children: childEntries,
            flowTemplates: templateEntries
        )
        try stageEntry(manifestPath, bytes: CanvasExchangeJSON.encode(manifest, pretty: true))

        let data = try CanvasLabZIP.pack(entries)
        return ExportResult(data: data, manifest: manifest, issues: templateResolution.issues)
    }

    // MARK: Import

    public struct ImportResult: Sendable {
        public var snapshot: CanvasSnapshot
        public var manifest: Manifest
        /// Raw document.json bytes: the exact recovery envelope for any
        /// newer-schema field the current DTO does not model.
        public var documentData: Data
        /// Asset bytes keyed by asset id (manifest-verified).
        public var assets: [UUID: Data]
        /// Original import bytes keyed by source id, so import -> export can
        /// carry the exact original payloads back out.
        public var sourceDataByID: [UUID: Data]
        public var originalSources: [CanvasOriginalSource]
        /// Recovered child project archives keyed by project id.
        public var childProjects: [UUID: RecoveredChildProject]
        /// Verified reusable flow template definitions embedded in the
        /// archive (data only — recovery never executes them or adopts
        /// their permissions).
        public var flowTemplates: [FlowTemplateDefinition]
        public var issues: [CanvasExchangeIssue]
    }

    /// Opens an archive and verifies every digest and cross-reference.
    /// A manifest that references a missing or altered entry, omits an
    /// asset/child the document still references, or disagrees with the
    /// document identity is an integrity failure — never a quiet partial
    /// success.
    public static func `import`(_ data: Data) throws -> ImportResult {
        try CanvasExchangeLimits.validateInputSize(data)
        let entries = try CanvasLabZIP.unpack(data)

        guard let manifestData = entries[manifestPath] else {
            throw CanvasExchangeError.integrity("archive has no \(manifestPath); it is not a floecanvaslab archive")
        }
        guard let documentData = entries[documentPath] else {
            throw CanvasExchangeError.integrity("archive has no \(documentPath)")
        }
        let manifest: Manifest
        do {
            manifest = try CanvasExchangeJSON.decode(Manifest.self, from: manifestData)
        } catch {
            throw CanvasExchangeError.integrity("archive manifest is unreadable: \(error)")
        }
        guard manifest.format == "org.floe.canvaslab" else {
            throw CanvasExchangeError.invalid("archive format is \(manifest.format), expected org.floe.canvaslab")
        }
        guard manifest.version == 1 else {
            throw CanvasExchangeError.unsupported("archive manifest version \(manifest.version); this build reads version 1")
        }
        guard CanvasDigest.sha256(documentData) == manifest.documentSHA256 else {
            throw CanvasExchangeError.integrity("document.json digest does not match the manifest; the archive is corrupt")
        }
        guard documentData.count == manifest.documentByteCount else {
            throw CanvasExchangeError.integrity("document.json byte count does not match the manifest")
        }
        try validateUniqueness(manifest)

        let snapshot: CanvasSnapshot
        do {
            snapshot = try CanvasExchangeJSON.decode(CanvasSnapshot.self, from: documentData)
        } catch {
            throw CanvasExchangeError.invalid("document.json does not decode as CanvasSnapshot: \(error)")
        }
        guard snapshot.id == manifest.canvasID else {
            throw CanvasExchangeError.integrity("document canvas id \(snapshot.id) differs from the manifest \(manifest.canvasID)")
        }
        guard snapshot.name == manifest.canvasName else {
            throw CanvasExchangeError.integrity("document canvas name \"\(snapshot.name)\" differs from the manifest \"\(manifest.canvasName)\"")
        }
        guard snapshot.revision == manifest.canvasRevision else {
            throw CanvasExchangeError.integrity("document revision \(snapshot.revision) differs from the manifest \(manifest.canvasRevision)")
        }
        guard snapshot.schemaVersion == manifest.schemaVersion else {
            throw CanvasExchangeError.integrity("document schemaVersion \(snapshot.schemaVersion) differs from the manifest \(manifest.schemaVersion)")
        }
        guard snapshot.pages.count == manifest.pageCount else {
            throw CanvasExchangeError.integrity("document has \(snapshot.pages.count) pages but the manifest records \(manifest.pageCount)")
        }

        // Embedded flow templates: every entry must decode, match its
        // manifest id/version, and satisfy its digest; the document and
        // every template graph must find all their referenced template ids
        // inside the manifest. Recovery is data-only — nothing is executed.
        var flowTemplates: [FlowTemplateDefinition] = []
        var templateIDs = Set<UUID>()
        for entry in manifest.flowTemplates {
            guard entry.version >= 1 else {
                throw CanvasExchangeError.integrity("manifest lists flow template \(entry.id) at invalid version \(entry.version)")
            }
            guard templateIDs.insert(entry.id).inserted else {
                throw CanvasExchangeError.integrity("manifest lists flow template \(entry.id) twice")
            }
            guard let bytes = entries[entry.path] else {
                throw CanvasExchangeError.integrity("manifest references flow template \(entry.id) at \(entry.path) but the entry is missing")
            }
            guard bytes.count == entry.byteCount, CanvasDigest.sha256(bytes) == entry.sha256 else {
                throw CanvasExchangeError.integrity("flow template \(entry.id) failed its manifest digest; the archive is corrupt")
            }
            let definition: FlowTemplateDefinition
            do {
                definition = try CanvasExchangeJSON.decode(FlowTemplateDefinition.self, from: bytes)
            } catch {
                throw CanvasExchangeError.integrity("flow template \(entry.id) does not decode as a template definition: \(error)")
            }
            guard definition.id == entry.id else {
                throw CanvasExchangeError.integrity("flow template file at \(entry.path) has id \(definition.id) but the manifest records \(entry.id)")
            }
            guard definition.version == entry.version else {
                throw CanvasExchangeError.integrity("flow template \(entry.id) is version \(definition.version) in its file but version \(entry.version) in the manifest")
            }
            flowTemplates.append(definition)
        }
        let documentTemplateIDs = try CanvasFlowTemplateSupport.referencedTemplateIDs(in: snapshot)
        for id in documentTemplateIDs where !templateIDs.contains(id) {
            throw CanvasExchangeError.integrity("document references flow template \(id) but the manifest has no definition for it; the archive is incomplete")
        }
        for definition in flowTemplates {
            for id in try CanvasFlowTemplateSupport.referencedTemplateIDs(in: definition.graph) where !templateIDs.contains(id) {
                throw CanvasExchangeError.integrity("flow template \(definition.id) references template \(id) but the manifest has no definition for it; the archive is incomplete")
            }
        }

        var assets: [UUID: Data] = [:]
        let manifestAssetIDs = Set(manifest.assets.map(\.id))
        for entry in manifest.assets {
            guard let bytes = entries[entry.path] else {
                throw CanvasExchangeError.integrity("manifest references asset \(entry.id) at \(entry.path) but the entry is missing")
            }
            guard bytes.count == entry.byteCount, CanvasDigest.sha256(bytes) == entry.sha256 else {
                throw CanvasExchangeError.integrity("asset \(entry.id) failed its manifest digest; the archive is corrupt")
            }
            assets[entry.id] = bytes
        }
        // The document and every embedded template must not reference
        // anything the manifest omits.
        let referencedAssets = try CanvasAssetReferences.merge(
            CanvasAssetReferences.collect(from: snapshot),
            CanvasAssetReferences.collect(from: flowTemplates.map(\.graph))
        )
        for locator in referencedAssets {
            guard manifestAssetIDs.contains(locator.id), let bytes = assets[locator.id] else {
                throw CanvasExchangeError.integrity("document references asset \(locator.id) but the manifest does not contain it; the archive is incomplete")
            }
            if let expected = locator.contentHash, expected != CanvasDigest.sha256(bytes) {
                throw CanvasExchangeError.integrity("document asset \(locator.id) hash differs from archived bytes")
            }
            if let expected = locator.byteCount, expected != bytes.count {
                throw CanvasExchangeError.integrity("document asset \(locator.id) byte count differs from archived bytes")
            }
        }

        var sourceDataByID: [UUID: Data] = [:]
        var sources: [CanvasOriginalSource] = []
        var seenSourceIDs = Set<UUID>()
        for entry in manifest.sources {
            guard seenSourceIDs.insert(entry.id).inserted else {
                throw CanvasExchangeError.integrity("manifest lists source \(entry.id) twice")
            }
            guard let bytes = entries[entry.path] else {
                throw CanvasExchangeError.integrity("manifest references original source \(entry.id) at \(entry.path) but the entry is missing")
            }
            guard bytes.count == entry.byteCount, CanvasDigest.sha256(bytes) == entry.sha256 else {
                throw CanvasExchangeError.integrity("original source \(entry.id) failed its manifest digest; the archive is corrupt")
            }
            sourceDataByID[entry.id] = bytes
            sources.append(CanvasOriginalSource(
                id: entry.id,
                kind: entry.kind,
                suggestedName: entry.suggestedName,
                byteCount: entry.byteCount,
                sha256: entry.sha256,
                nodeIDs: entry.nodeIDs
            ))
        }

        var childProjects: [UUID: RecoveredChildProject] = [:]
        let editorReferences = try CanvasAssetReferences.collectEditorReferences(from: snapshot)
        let manifestChildrenByID = Dictionary(grouping: manifest.children, by: \.projectID)
        for reference in editorReferences {
            guard let entry = manifestChildrenByID[reference.projectID]?.first else {
                throw CanvasExchangeError.integrity("document references child project \(reference.projectID) but the manifest has no entry for it; the archive is incomplete")
            }
            guard entry.appliedRevision == reference.appliedRevision,
                  entry.editorKind == reference.editorKind else {
                throw CanvasExchangeError.integrity("child project \(reference.projectID) is at revision \(reference.appliedRevision) in the document but the manifest archived revision \(entry.appliedRevision); re-export the archive from a consistent revision")
            }
            guard let bytes = entries[entry.path] else {
                throw CanvasExchangeError.integrity("manifest references child project \(reference.projectID) at \(entry.path) but the entry is missing")
            }
            guard bytes.count == entry.byteCount, CanvasDigest.sha256(bytes) == entry.sha256 else {
                throw CanvasExchangeError.integrity("child project \(reference.projectID) failed its manifest digest; the archive is corrupt")
            }
            childProjects[reference.projectID] = RecoveredChildProject(
                projectID: reference.projectID,
                editorKind: entry.editorKind,
                appliedRevision: entry.appliedRevision,
                formatHint: entry.formatHint,
                sha256: entry.sha256,
                data: bytes
            )
        }

        var issues: [CanvasExchangeIssue] = []
        if snapshot.schemaVersion > CanvasSnapshot.currentSchemaVersion {
            issues.append(.init(
                "archive.newerSchema",
                "archive schemaVersion \(snapshot.schemaVersion) is newer than this build's \(CanvasSnapshot.currentSchemaVersion); known fields were decoded and the original document bytes are returned in `documentData` as the recovery envelope — fields this build does not model are NOT guaranteed and are not claimed preserved",
                contentClass: "archive", severity: .preserved
            ))
        }
        return ImportResult(
            snapshot: snapshot,
            manifest: manifest,
            documentData: documentData,
            assets: assets,
            sourceDataByID: sourceDataByID,
            originalSources: sources,
            childProjects: childProjects,
            flowTemplates: flowTemplates.sorted(by: { $0.id.uuidString < $1.id.uuidString }),
            issues: issues
        )
    }

    private static func validateUniqueness(_ manifest: Manifest) throws {
        let allPaths = [manifestPath, manifest.documentPath]
            + manifest.assets.map(\.path) + manifest.sources.map(\.path) + manifest.children.map(\.path)
            + manifest.flowTemplates.map(\.path)
        guard manifest.documentPath == documentPath,
              Set(allPaths).count == allPaths.count,
              allPaths.allSatisfy(CanvasLabZIP.validPath) else {
            throw CanvasExchangeError.integrity("manifest entry paths overlap, are unsafe, or use an unsupported document path")
        }
        let assetIDs = manifest.assets.map(\.id)
        guard Set(assetIDs).count == assetIDs.count else {
            throw CanvasExchangeError.integrity("manifest lists an asset id twice")
        }
        let assetPaths = manifest.assets.map(\.path)
        guard Set(assetPaths).count == assetPaths.count else {
            throw CanvasExchangeError.integrity("manifest lists an asset path twice")
        }
        let sourceIDs = manifest.sources.map(\.id)
        guard Set(sourceIDs).count == sourceIDs.count else {
            throw CanvasExchangeError.integrity("manifest lists a source id twice")
        }
        let sourcePaths = manifest.sources.map(\.path)
        guard Set(sourcePaths).count == sourcePaths.count else {
            throw CanvasExchangeError.integrity("manifest lists a source path twice")
        }
        let childIDs = manifest.children.map(\.projectID)
        guard Set(childIDs).count == childIDs.count else {
            throw CanvasExchangeError.integrity("manifest lists a child project twice")
        }
        let childPaths = manifest.children.map(\.path)
        guard Set(childPaths).count == childPaths.count else {
            throw CanvasExchangeError.integrity("manifest lists a child path twice")
        }
        let templatePaths = manifest.flowTemplates.map(\.path)
        guard Set(templatePaths).count == templatePaths.count else {
            throw CanvasExchangeError.integrity("manifest lists a flow template path twice")
        }
    }
}

// MARK: - Reference collection

/// Collects every asset a canvas document references so the archive can
/// embed and hash them all. Conflicting locators for one asset id (two
/// different hashes, paths, mime types, byte counts or licenses) are an
/// error: the caller must resolve the ambiguity, never last-write-wins.
public enum CanvasAssetReferences {
    /// Deduplicating, conflict-checking accumulator shared by the snapshot
    /// and template-graph collection paths.
    private struct LocatorCollector {
        var byID: [UUID: CanvasAssetLocator] = [:]

        mutating func insert(_ locator: CanvasAssetLocator) throws {
            guard let existing = byID[locator.id] else {
                byID[locator.id] = locator
                return
            }
            guard CanvasAssetReferences.compatible(existing, locator) else {
                throw CanvasExchangeError.invalid("asset \(locator.id) is referenced with conflicting locators (differing hash/path/mime/size/license); resolve the conflict before archiving")
            }
            // Merge: prefer the fuller description for archival metadata.
            byID[locator.id] = CanvasAssetReferences.merged(existing, locator)
        }

        var result: [CanvasAssetLocator] { Array(byID.values) }
    }

    public static func collect(from snapshot: CanvasSnapshot) throws -> [CanvasAssetLocator] {
        var collector = LocatorCollector()
        for page in snapshot.pages {
            for node in page.nodes {
                switch node.content {
                case .media(let locator):
                    try collector.insert(locator)
                case .formula(_, let renderedAssetID):
                    if let id = renderedAssetID {
                        try collector.insert(CanvasAssetLocator(id: id))
                    }
                case .pdf(let documentAssetID, _):
                    if let id = documentAssetID {
                        try collector.insert(CanvasAssetLocator(id: id))
                    }
                default:
                    break
                }
                if let pencil = node.metadata["pencilKitDataID"].flatMap(UUID.init(uuidString:)) {
                    try collector.insert(CanvasAssetLocator(id: pencil))
                }
            }
        }
        let graphs = snapshot.pages.flatMap { CanvasExchangeFlowSupport.flowGraphs(of: $0) }
        try collectAssetReferences(from: graphs, into: &collector)
        return collector.result
    }

    /// Every typed asset reference inside the given flow graphs: variable
    /// initial values and `FlowOperand` literals inside condition-branch
    /// predicates (the `stopWhen` / `inputBindings` predicate spellings the
    /// runtime uses are the same typed `FlowPredicate` tree). Node
    /// `parameters` are raw `JSONValue` and are deliberately NOT scanned —
    /// arbitrary UUID-looking JSON never becomes filesystem authority.
    public static func collect(from graphs: [FlowGraph]) throws -> [CanvasAssetLocator] {
        var collector = LocatorCollector()
        try collectAssetReferences(from: graphs, into: &collector)
        return collector.result
    }

    /// Combines two reference sets with the same conflict discipline used
    /// inside one collection pass.
    public static func merge(_ first: [CanvasAssetLocator], _ second: [CanvasAssetLocator]) throws -> [CanvasAssetLocator] {
        var collector = LocatorCollector()
        for locator in first + second {
            try collector.insert(locator)
        }
        return collector.result
    }

    private static func collectAssetReferences(from graphs: [FlowGraph], into collector: inout LocatorCollector) throws {
        for graph in graphs {
            for variable in graph.variables {
                try walk(variable.initial, collector: &collector)
            }
            for node in graph.nodes {
                for branch in node.branches ?? [] {
                    try walk(branch.predicate, collector: &collector)
                }
            }
        }
    }

    private static func walk(_ value: FlowValue?, collector: inout LocatorCollector) throws {
        guard let value else { return }
        switch value {
        case .asset(let locator):
            try collector.insert(locator)
        case .list(let items):
            for item in items {
                try walk(item, collector: &collector)
            }
        default:
            break
        }
    }

    private static func walk(_ predicate: FlowPredicate?, collector: inout LocatorCollector) throws {
        guard let predicate else { return }
        switch predicate {
        case .comparison(_, let lhs, let rhs):
            try walk(lhs, collector: &collector)
            try walk(rhs, collector: &collector)
        case .and(let children), .or(let children):
            for child in children {
                try walk(child, collector: &collector)
            }
        case .not(let child):
            try walk(child, collector: &collector)
        }
    }

    private static func walk(_ operand: FlowOperand, collector: inout LocatorCollector) throws {
        if case .literal(let value) = operand {
            try walk(value, collector: &collector)
        }
    }

    /// All professional child projects referenced by the snapshot. A bare
    /// projectID is not an offline-reopenable project; archiving requires a
    /// host `CanvasChildProjectExportProvider` (see CanvasNativeArchive).
    public static func collectEditorReferences(from snapshot: CanvasSnapshot) throws -> [CanvasEditorReference] {
        var byID: [UUID: CanvasEditorReference] = [:]
        for page in snapshot.pages {
            for node in page.nodes {
                guard case .editor(let reference) = node.content else { continue }
                if let existing = byID[reference.projectID],
                   existing.appliedRevision != reference.appliedRevision || existing.editorKind != reference.editorKind {
                    throw CanvasExchangeError.invalid("child project \(reference.projectID) is referenced with conflicting revisions or editor kinds; resolve before archiving")
                }
                byID[reference.projectID] = byID[reference.projectID] ?? reference
            }
        }
        return Array(byID.values)
    }

    /// Fields where a nil means "unknown" and must not conflict.
    private static func compatible(_ a: CanvasAssetLocator, _ b: CanvasAssetLocator) -> Bool {
        func same<T: Equatable>(_ x: T?, _ y: T?) -> Bool {
            x == nil || y == nil || x == y
        }
        return same(a.contentHash, b.contentHash)
            && same(a.relativePath, b.relativePath)
            && same(a.mimeType, b.mimeType)
            && same(a.byteCount, b.byteCount)
            && same(a.license, b.license)
    }

    private static func merged(_ a: CanvasAssetLocator, _ b: CanvasAssetLocator) -> CanvasAssetLocator {
        CanvasAssetLocator(
            id: a.id,
            contentHash: a.contentHash ?? b.contentHash,
            relativePath: a.relativePath ?? b.relativePath,
            mimeType: a.mimeType ?? b.mimeType,
            byteCount: a.byteCount ?? b.byteCount,
            sourceURL: a.sourceURL ?? b.sourceURL,
            license: a.license ?? b.license
        )
    }
}

// MARK: - Flow template reachability

/// Data-only reachability analysis for reusable flow templates. The archive
/// embeds exactly the definitions reachable from the snapshot graphs —
/// never a whole host registry — and reports recursive references and
/// unconfigured draft subgraphs honestly. Graph execution validity stays
/// with the runtime; this is bounded finite traversal for data fidelity.
public enum CanvasFlowTemplateSupport {
    public struct Resolution: Sendable {
        /// Reachable, registry-verified definitions (unsorted).
        public var definitions: [CanvasNativeArchive.FlowTemplateDefinition]
        /// Honest data-only observations (recursion, unconfigured drafts).
        public var issues: [CanvasExchangeIssue]
    }

    /// Every template id a graph references: node `subgraphTemplateID` and
    /// node `group.id` (both are registration points for the same template
    /// identity in the Core DTO).
    public static func referencedTemplateIDs(in graph: FlowGraph) -> [UUID] {
        var ids: [UUID] = []
        var seen = Set<UUID>()
        for node in graph.nodes {
            for candidate in [node.subgraphTemplateID, node.group?.id] {
                guard let id = candidate, seen.insert(id).inserted else { continue }
                ids.append(id)
            }
        }
        return ids
    }

    /// Every template id the snapshot's page graphs reference.
    public static func referencedTemplateIDs(in snapshot: CanvasSnapshot) throws -> [UUID] {
        var ids: [UUID] = []
        var seen = Set<UUID>()
        for page in snapshot.pages {
            for graph in CanvasExchangeFlowSupport.flowGraphs(of: page) {
                for id in referencedTemplateIDs(in: graph) where seen.insert(id).inserted {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    /// Subgraph nodes that reference no template at all (unconfigured
    /// drafts). Data-complete to archive; reported so hosts do not mistake
    /// them for runnable references.
    public static func unconfiguredDraftNodes(in graph: FlowGraph) -> [FlowNode] {
        graph.nodes.filter { $0.kind == .subgraph && $0.subgraphTemplateID == nil && $0.group == nil }
    }

    /// Resolves the definitions reachable from `snapshot` against a host
    /// registry. The registry may be larger than needed — unrelated
    /// templates are never embedded. A referenced id missing from the
    /// registry fails resolution (the export must not claim completeness).
    public static func resolve(
        referencedIn snapshot: CanvasSnapshot,
        from registry: [CanvasNativeArchive.FlowTemplateDefinition]
    ) throws -> Resolution {
        var byID: [UUID: CanvasNativeArchive.FlowTemplateDefinition] = [:]
        for definition in registry {
            guard byID[definition.id] == nil else {
                throw CanvasExchangeError.invalid("the flow template registry contains duplicate id \(definition.id); resolve the ambiguity before archiving")
            }
            guard definition.version >= 1 else {
                throw CanvasExchangeError.invalid("flow template \(definition.id) has invalid version \(definition.version)")
            }
            byID[definition.id] = definition
        }

        var issues: [CanvasExchangeIssue] = []
        var reachable: [UUID: CanvasNativeArchive.FlowTemplateDefinition] = [:]
        // Iterative transitive closure; the visited set bounds the walk by
        // the registry size. Shared (diamond) dependencies are fine — they
        // embed once.
        var stack = try referencedTemplateIDs(in: snapshot)
        while let id = stack.popLast() {
            if reachable[id] != nil { continue }
            guard let definition = byID[id] else {
                throw CanvasExchangeError.invalid("the snapshot references flow template \(id) but no definition was provided; the archive cannot claim completeness")
            }
            reachable[id] = definition
            for nested in referencedTemplateIDs(in: definition.graph) where reachable[nested] == nil {
                stack.append(nested)
            }
        }

        // Honest cycle reporting: a template that can reach itself embeds
        // completely but instantiating it would recurse forever — a runtime
        // concern, reported here as data-only observation.
        for id in reachable.keys {
            if canReach(from: id, target: id, within: reachable) {
                issues.append(.init(
                    "flowTemplate.recursiveReference",
                    "flow template \(id) has a cyclic template reference; its definition is archived completely, but instantiation recursion is a runtime concern, not archive data",
                    contentClass: "flowGraph", severity: .preserved
                ))
            }
        }
        for page in snapshot.pages {
            for graph in CanvasExchangeFlowSupport.flowGraphs(of: page) {
                for draft in unconfiguredDraftNodes(in: graph) {
                    issues.append(.init(
                        "flowTemplate.unconfiguredDraft",
                        "subgraph node \(draft.id) (\"\(draft.name)\") references no template; archived as an unconfigured draft",
                        contentClass: "flowGraph", severity: .preserved
                    ))
                }
            }
        }
        return Resolution(definitions: Array(reachable.values), issues: issues)
    }

    /// Bounded reachability test inside the resolved subgraph (visits each
    /// node at most once; data only, never executes).
    private static func canReach(
        from start: UUID,
        target: UUID,
        within graph: [UUID: CanvasNativeArchive.FlowTemplateDefinition]
    ) -> Bool {
        var visited: Set<UUID> = [start]
        var stack = referencedTemplateIDs(in: graph[start]?.graph ?? FlowGraph())
        while let id = stack.popLast() {
            if id == target { return true }
            guard visited.insert(id).inserted, let definition = graph[id] else { continue }
            stack.append(contentsOf: referencedTemplateIDs(in: definition.graph))
        }
        return false
    }
}

// MARK: - ZIP container

/// Bounded ZIP reader/writer. Limits (enforced before any bytes are
/// emitted, so a failure never leaves a half-written archive): at most
/// 20 000 entries, each at most 64 MiB, expanded total at most 512 MiB,
/// compressed output at most 128 MiB. Entry paths must be relative,
/// normalized (no empty segments), free of drive/UNC separators, and
/// unique; symlinks are refused.
enum CanvasLabZIP {
    static func validPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        // No "..", no empty segments (so no "//", trailing "/", or leading "/").
        return !components.contains("..") && !components.contains(".") && !components.contains("")
    }

    static func unpack(_ data: Data) throws -> [String: Data] {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw CanvasExchangeError.invalid("not a readable ZIP archive: \(error)")
        }
        var result: [String: Data] = [:]
        var total: UInt64 = 0
        var count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= CanvasExchangeLimits.maxArchiveEntries else {
                throw CanvasExchangeError.limitExceeded("archive has more than \(CanvasExchangeLimits.maxArchiveEntries) entries")
            }
            guard validPath(entry.path), result[entry.path] == nil else {
                throw CanvasExchangeError.invalid("archive entry path is unsafe or duplicated: \(entry.path)")
            }
            guard entry.type != .symlink else {
                throw CanvasExchangeError.invalid("archive entry \(entry.path) is a symlink; refusing to unpack")
            }
            guard entry.uncompressedSize <= CanvasExchangeLimits.maxSingleEntryBytes else {
                throw CanvasExchangeError.limitExceeded("archive entry \(entry.path) exceeds the single-entry byte bound")
            }
            total += UInt64(entry.uncompressedSize)
            guard total <= UInt64(CanvasExchangeLimits.maxExpandedTotalBytes) else {
                throw CanvasExchangeError.limitExceeded("archive expansion exceeds \(CanvasExchangeLimits.maxExpandedTotalBytes) bytes")
            }
            if entry.type == .directory { continue }
            var bytes = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    guard bytes.count + chunk.count <= CanvasExchangeLimits.maxSingleEntryBytes else {
                        throw CanvasExchangeError.limitExceeded("archive entry \(entry.path) grows past its declared size")
                    }
                    bytes.append(chunk)
                }
            } catch let error as CanvasExchangeError {
                throw error
            } catch {
                throw CanvasExchangeError.integrity("archive entry \(entry.path) failed to decompress: \(error)")
            }
            result[entry.path] = bytes
        }
        return result
    }

    static func pack(_ entries: [String: Data]) throws -> Data {
        guard entries.count <= CanvasExchangeLimits.maxArchiveEntries else {
            throw CanvasExchangeError.limitExceeded("archive would contain \(entries.count) entries; the limit is \(CanvasExchangeLimits.maxArchiveEntries)")
        }
        let total = entries.values.reduce(Int64(0)) { $0 + Int64($1.count) }
        guard total <= Int64(CanvasExchangeLimits.maxExpandedTotalBytes) else {
            throw CanvasExchangeError.limitExceeded("archive content exceeds \(CanvasExchangeLimits.maxExpandedTotalBytes) bytes")
        }
        let archive = try Archive(accessMode: .create)
        for path in entries.keys.sorted() {
            try Task.checkCancellation()
            guard validPath(path), let data = entries[path] else {
                throw CanvasExchangeError.invalid("archive output path is unsafe: \(path)")
            }
            guard data.count <= CanvasExchangeLimits.maxSingleEntryBytes else {
                throw CanvasExchangeError.limitExceeded("archive output entry \(path) exceeds the single-entry byte bound")
            }
            do {
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    modificationDate: Date(timeIntervalSince1970: 315_532_800),
                    compressionMethod: .deflate
                ) { position, size in
                    data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
                }
            } catch {
                throw CanvasExchangeError.io("archive write failed for \(path): \(error)")
            }
        }
        guard let data = archive.data else {
            throw CanvasExchangeError.io("archive serialization produced no data")
        }
        guard data.count <= CanvasExchangeLimits.maxInputBytes else {
            throw CanvasExchangeError.limitExceeded("compressed archive exceeds \(CanvasExchangeLimits.maxInputBytes) bytes")
        }
        return data
    }
}
