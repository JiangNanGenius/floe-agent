// SPDX-License-Identifier: MPL-2.0
//
// AI-facing verified electronics catalogue and download tool. The model sees
// only publisher identities from the installed receipt (library IDs and exact
// model IDs), never a URL, host path or mirror endpoint. Every download is
// size/digest/Git-object verified before it becomes a task-owned run output.

import Foundation
import CoreFoundation
import UniformTypeIdentifiers
import ZIPFoundation
import FloeCore
import FloeModels
import FloeTools
import FloeSkills
import FloeElectronicsCore
import FloeElectronicsUI

struct ElectronicsRemoteTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let action: String
        let inputJSON: String?
    }

    static let name = "electronics.library"
    static let toolDescription = "Search, download and install the verified public Floe electronics catalogue. Actions: refresh fetches the official release receipt and re-verifies catalog.json, manifest.json and the model index through the existing signed GitHub mirror policy; status reports the installed snapshot and cache; search kind=libraries lists sources, kind=parts searches a library's actual normalized 2D index (downloading and verifying that exact per-library ZIP when its index is not cached), kind=models searches the metadata index of individually downloadable 3D files; read returns a library, a normalized part record or one exact model record; install libraryID=<source id> partID=<exact part id> converts that verified converted record through the native KiCad adapter, retains its exact original/license and installs a small immutable native EDALibraryPackage, returning the exact EDALibraryReference after catalog read-back; download libraryID=<library> downloads that verified 2D exchange ZIP, full2D=true downloads the complete package; downloadModel modelID=<exact model id> downloads one verified Git blob. Only IDs returned by search/read are accepted; never a URL, host path, credentials or model-authored policy. Files are returned as verified run-owned outputFile receipts. Install is not project placement; use eda.library.place with the returned reference. 3D metadata download or install is not rendering acceptance."
    static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "action": {"type": "string", "enum": ["refresh", "status", "search", "read", "install", "download", "downloadModel"]},
        "inputJSON": {"type": "string", "maxLength": 65536, "description": "Action request object. refresh/status: {}. search: {kind:libraries|parts|models,text?,libraryID?,sourceID?,format?,status?,offset?,limit?}. read: {kind:library|part|model,id,libraryID?}. install: {libraryID,partID}. download: {libraryID} or {full2D:true}. downloadModel: {modelID}."}
      },
      "required": ["action"],
      "additionalProperties": false
    }
    """#
    static let riskLabels: Set<RiskLabel> = [.networkAccess, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    private let policyStore: GitHubTransportMirrorPolicyStore
    private let cacheRootProvider: @Sendable () throws -> URL
    private let manifestDownload: @Sendable () async throws -> GitHubTransportMirrorPolicyStore.Downloaded

    init(policyStore: GitHubTransportMirrorPolicyStore,
         cacheRootProvider: @escaping @Sendable () throws -> URL,
         manifestDownload: @escaping @Sendable () async throws -> GitHubTransportMirrorPolicyStore.Downloaded,
         archiveReader: @escaping @Sendable (URL, String) async throws -> Data = ElectronicsRemoteTool.readArchiveEntry) {
        self.policyStore = policyStore
        self.cacheRootProvider = cacheRootProvider
        self.manifestDownload = manifestDownload
        self.archiveReaderOverride = archiveReader
    }

    private let archiveReaderOverride: @Sendable (URL, String) async throws -> Data

    func validate(_ args: Arguments) throws {
        guard ["refresh", "status", "search", "read", "install", "download", "downloadModel"].contains(args.action),
              (args.inputJSON?.utf8.count ?? 0) <= 64 * 1_024 else {
            throw FloeError.validationFailed("Use a documented electronics.library action and bounded inputJSON")
        }
        try Self.validateRequest(args, object: Self.object(args.inputJSON, action: args.action))
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        let object = try Self.object(args.inputJSON, action: args.action)
        let networkAction = ["refresh", "download", "downloadModel", "install"].contains(args.action)
            || (args.action == "search" && (object["kind"] as? String) == "parts")
            || (args.action == "read" && (object["kind"] as? String) == "part")
        if context.temporaryReadOnly, networkAction {
            throw FloeError.validationFailed("Temporary chats can search an installed catalogue read-only but cannot refresh or download library files")
        }
        let cacheRoot: URL
        do { cacheRoot = try cacheRootProvider() } catch {
            throw FloeError.storageCorrupted("Electronics library cache is unavailable")
        }
        let policy = await policyStore.policyForTransfer(download: manifestDownload)
        try context.cancellation.throwIfCancelled()
        let network = Self.network(policy: policy.roles, archiveReader: archiveReaderOverride)
        let service = ElectronicsRemoteService(storeRoot: cacheRoot, network: network)
        let progress = Self.progress(context: context)
        switch args.action {
        case "status":
            try Self.reject(object, outside: [])
            return try Self.output(action: args.action, value: try await service.status())
        case "refresh":
            try Self.reject(object, outside: [])
            let receipt = try await service.refresh(progress: progress)
            return try Self.output(action: args.action, value: receipt)
        case "search":
            let kind = try Self.requiredString(object, "kind")
            switch kind {
            case "libraries":
                try Self.reject(object, outside: ["kind", "text", "status", "offset", "limit"])
                let query = ElectronicsRemoteLibraryQuery(text: try Self.string(object, "text") ?? "",
                    status: try Self.string(object, "status"), offset: try Self.integer(object, "offset") ?? 0,
                    limit: try Self.integer(object, "limit") ?? 50)
                return try Self.output(action: args.action, value: try await service.searchLibraries(query))
            case "parts":
                try Self.reject(object, outside: ["kind", "text", "libraryID", "partKind", "status", "offset", "limit"])
                let libraryID = try Self.requiredString(object, "libraryID")
                let query = ElectronicsRemotePartQuery(text: try Self.string(object, "text") ?? "",
                    kind: try Self.string(object, "partKind"), status: try Self.string(object, "status"),
                    offset: try Self.integer(object, "offset") ?? 0, limit: try Self.integer(object, "limit") ?? 50)
                return try Self.output(action: args.action,
                    value: try await service.searchParts(libraryID: libraryID, query: query, progress: progress))
            case "models":
                try Self.reject(object, outside: ["kind", "text", "sourceID", "format", "offset", "limit"])
                let query = ElectronicsRemoteModelQuery(text: try Self.string(object, "text") ?? "",
                    sourceID: try Self.string(object, "sourceID"), format: try Self.string(object, "format"),
                    offset: try Self.integer(object, "offset") ?? 0, limit: try Self.integer(object, "limit") ?? 50)
                return try Self.output(action: args.action, value: try await service.searchModels(query))
            default:
                throw FloeError.validationFailed("search.kind must be libraries, parts or models")
            }
        case "read":
            try Self.reject(object, outside: ["kind", "id", "libraryID"])
            let kind = try Self.requiredString(object, "kind")
            let id = try Self.requiredString(object, "id")
            switch kind {
            case "library":
                return try Self.output(action: args.action, value: try await service.readLibrary(id: id))
            case "model":
                let record = try await service.readModel(id: id)
                return try Self.output(action: args.action, value: ModelRead(model: record))
            case "part":
                let libraryID = try Self.requiredString(object, "libraryID")
                let part = try await service.readPart(libraryID: libraryID, id: id, progress: progress)
                let data = Data(part.recordJSON.utf8)
                let truncated = data.count > 48 * 1_024
                return try Self.output(action: args.action, value: PartRead(
                    libraryID: part.libraryID, part: part.part,
                    recordJSON: truncated ? String(decoding: data.prefix(48 * 1_024), as: UTF8.self) : part.recordJSON,
                    recordJSONTruncated: truncated, recordSHA256: part.recordSHA256,
                    sourcePath: part.sourcePath,
                    note: truncated ? "The normalized record exceeds the inline limit; use the exact sourcePath and library ZIP for complete unsupported/geometry fields." : "Actual publisher-normalized 2D record; compatibility status is explicit."))
            default:
                throw FloeError.validationFailed("read.kind must be library, part or model")
            }
        case "install":
            try Self.reject(object, outside: ["libraryID", "partID"])
            let libraryID = try Self.requiredString(object, "libraryID")
            let partID = try Self.requiredString(object, "partID")
            guard ElectronicsRemoteValidation.safeSourceID(libraryID) else {
                throw FloeError.validationFailed("inputJSON.libraryID must be a catalogue source ID")
            }
            guard partID.hasPrefix("floe:electronics:" + libraryID + ":"), partID.utf8.count <= 8_192 else {
                throw FloeError.validationFailed("inputJSON.partID must be an exact part ID returned by search or read for this library")
            }
            let library: EDLibraryController
            do { library = try await MainActor.run { try ElectronicsLibraryService.shared() } }
            catch { throw FloeError.storageCorrupted("The native electronics library is unavailable") }
            let cancellation = context.cancellation
            let result = try await ElectronicsRemoteInstallSupport.install(service: service, library: library,
                libraryID: libraryID, partID: partID, progress: progress,
                cancelled: { cancellation.isCancelled })
            return try Self.output(action: args.action, value: InstallOutput(result))
        case "download":
            let libraryID = try Self.string(object, "libraryID")
            let full2D = try Self.boolean(object, "full2D") ?? false
            if (libraryID == nil) == (full2D == false) {
                throw FloeError.validationFailed("download requires exactly one of libraryID or full2D=true")
            }
            try Self.reject(object, outside: ["libraryID", "full2D"])
            if let libraryID {
                let downloaded = try await service.downloadLibrary(id: libraryID, progress: progress)
                return try Self.downloadOutput(action: args.action, name: downloaded.name,
                    kind: "library", byteCount: downloaded.byteCount, sha256: downloaded.sha256,
                    cached: downloaded.cached, file: URL(fileURLWithPath: downloaded.path), context: context)
            }
            let downloaded = try await service.downloadFull2D(progress: progress)
            return try Self.downloadOutput(action: args.action, name: downloaded.name,
                kind: "full2D", byteCount: downloaded.byteCount, sha256: downloaded.sha256,
                cached: downloaded.cached, file: URL(fileURLWithPath: downloaded.path), context: context)
        case "downloadModel":
            try Self.reject(object, outside: ["modelID"])
            let modelID = try Self.requiredString(object, "modelID")
            let downloaded = try await service.downloadModel(id: modelID, progress: progress)
            return try Self.downloadOutput(action: args.action, name: downloaded.displayName,
                kind: "model", byteCount: downloaded.byteCount, sha256: downloaded.sha256,
                cached: downloaded.cached, file: URL(fileURLWithPath: downloaded.cachePath),
                gitBlobSHA1: downloaded.gitBlobSHA1, modelID: downloaded.id, context: context)
        default:
            throw FloeError.validationFailed("Unsupported electronics.library action")
        }
    }

    // MARK: - Output

    private struct ModelRead: Encodable {
        let model: ElectronicsRemoteModelRecord
        let semantics = "Metadata-only publisher row. downloadModel obtains and verifies the exact Git blob; no 3D rendering or native placement is claimed."
    }

    private struct PartRead: Encodable {
        let libraryID: String
        let part: ElectronicsRemotePartSummary
        let recordJSON: String
        let recordJSONTruncated: Bool
        let recordSHA256: String
        let sourcePath: String
        let note: String
    }

    private struct InstallOutput: Encodable {
        let installed: Bool
        let reference: EDALibraryReference
        let partName: String
        let partKind: String
        let snapshotSHA256: String
        let sourceRecordID: String
        let sourceRecordSHA256: String
        let sourcePath: String
        let models: [ElectronicsRemoteInstalledModel]
        let catalogRevision: String
        let semantics: String
        let nextAction: String
        init(_ result: ElectronicsRemoteInstallResult) {
            installed = true; reference = result.reference; partName = result.partName
            partKind = result.partKind.rawValue; snapshotSHA256 = result.snapshotSHA256
            sourceRecordID = result.sourceRecordID; sourceRecordSHA256 = result.sourceRecordSHA256
            sourcePath = result.sourcePath; models = result.models
            catalogRevision = String(result.catalogRevision)
            semantics = result.semantics
            nextAction = "Use eda.library.place with this exact reference. Model references are metadata; download a model separately before expecting 3D rendering."
        }
    }

    private struct DownloadOutput: Encodable {
        let action: String
        let kind: String
        let name: String
        let byteCount: Int
        let sha256: String
        let cachedBeforeThisCall: Bool
        let outputFile: RunOutputFile
        let gitBlobSHA1: String?
        let modelID: String?
        let semantics: String
    }

    private static func downloadOutput(action: String, name: String, kind: String, byteCount: Int,
                                       sha256: String, cached: Bool, file: URL,
                                       gitBlobSHA1: String? = nil, modelID: String? = nil,
                                       context: ToolContext) throws -> ToolExecutionOutput {
        guard !context.temporaryReadOnly else {
            throw FloeError.validationFailed("Temporary chats cannot publish downloaded files")
        }
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        let slot = "electronics-" + kind + "-" + String(sha256.prefix(24))
        let request = RunOutputSnapshotRequest(producerTool: context.executionToolName ?? Self.name,
            slot: slot,
            commit: .init(sourceURL: file, sha256: sha256, byteCount: byteCount, displayName: name,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream", uti: type?.identifier))
        let published: RunOutputFile
        do { published = try RunOutputSnapshotStore.publish(request, using: context) }
        catch let error as RunOutputSnapshotError {
            switch error {
            case .overCap(_): throw FloeError.validationFailed("This file exceeds the run output size limit; download a single library instead of the full package")
            case .policyRefused(_): throw FloeError.validationFailed("This context cannot publish a run-owned download")
            default: throw FloeError.validationFailed("The verified download is cached but its run-owned receipt could not be published")
            }
        }
        let output = DownloadOutput(action: action, kind: kind, name: name, byteCount: byteCount,
            sha256: sha256, cachedBeforeThisCall: cached, outputFile: published,
            gitBlobSHA1: gitBlobSHA1, modelID: modelID,
            semantics: "Verified publisher bytes, copied into this run's immutable output snapshot. This is not native placement, conversion or 3D rendering acceptance.")
        var result = try make(action: action, value: output)
        result.outputFiles = [published]
        return result
    }

    private static func output<T: Encodable>(action: String, value: T) throws -> ToolExecutionOutput {
        try make(action: action, value: value)
    }

    private static func make<T: Encodable>(action: String, value: T) throws -> ToolExecutionOutput {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes: Data
        do { bytes = try encoder.encode(value) } catch { throw FloeError.validationFailed("Electronics result is not encodable") }
        guard bytes.count <= 96 * 1_024 else {
            throw FloeError.validationFailed("Electronics result exceeds the response budget; request a smaller page")
        }
        let text = String(decoding: bytes, as: UTF8.self)
        return .init(summary: text, fullOutputSHA256: FloeDigest.sha256Hex(bytes), exitStatus: 0,
                     maximumSummaryCharacters: 96 * 1_024)
    }

    // MARK: - Request validation

    private static func object(_ json: String?, action: String) throws -> [String: Any] {
        if json?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            guard action == "refresh" || action == "status" else {
                throw FloeError.validationFailed("inputJSON is required for this action")
            }
            return [:]
        }
        guard let json, json.utf8.count <= 64 * 1_024 else {
            throw FloeError.validationFailed("inputJSON must be one bounded JSON object")
        }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: Data(json.utf8)) }
        catch { throw FloeError.validationFailed("inputJSON must be one bounded JSON object") }
        guard let value = raw as? [String: Any], JSONSerialization.isValidJSONObject(value) else {
            throw FloeError.validationFailed("inputJSON must be one bounded JSON object")
        }
        return value
    }

    private static func reject(_ object: [String: Any], outside allowed: Set<String>) throws {
        if let unknown = Set(object.keys).subtracting(allowed).sorted().first {
            throw FloeError.validationFailed("inputJSON.\(unknown) is not accepted for this action")
        }
    }

    private static func requiredString(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = try string(object, key, required: true) else {
            throw FloeError.validationFailed("inputJSON.\(key) is required")
        }
        return value
    }

    private static func validateRequest(_ args: Arguments, object: [String: Any]) throws {
        func sourceID(_ key: String) throws {
            let value = try requiredString(object, key)
            guard ElectronicsRemoteValidation.safeSourceID(value) else {
                throw FloeError.validationFailed("inputJSON.\(key) must be a catalogue library ID")
            }
        }
        func modelID(_ key: String) throws {
            let value = try requiredString(object, key)
            let fields = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "model",
                  ElectronicsRemoteValidation.safeSourceID(String(fields[1])),
                  ElectronicsRemoteValidation.safeRelativePath(String(fields[2])) else {
                throw FloeError.validationFailed("inputJSON.\(key) must be an exact catalogue model ID")
            }
        }
        func query() throws {
            for key in ["text", "status", "format", "partKind", "sourceID"] where object[key] != nil {
                if key == "text", let value = object[key] as? String, value.isEmpty { continue }
                _ = try string(object, key)
            }
            _ = try integer(object, "offset")
            if let limit = try integer(object, "limit"), !(1...100).contains(limit) {
                throw FloeError.validationFailed("inputJSON.limit must be between 1 and 100")
            }
        }
        switch args.action {
        case "refresh", "status":
            try reject(object, outside: [])
        case "search":
            switch try requiredString(object, "kind") {
            case "libraries":
                try reject(object, outside: ["kind", "text", "status", "offset", "limit"])
            case "parts":
                try reject(object, outside: ["kind", "text", "libraryID", "partKind", "status", "offset", "limit"])
                try sourceID("libraryID")
            case "models":
                try reject(object, outside: ["kind", "text", "sourceID", "format", "offset", "limit"])
                if object["sourceID"] != nil { try sourceID("sourceID") }
            default:
                throw FloeError.validationFailed("search.kind must be libraries, parts or models")
            }
            try query()
        case "read":
            switch try requiredString(object, "kind") {
            case "library":
                try reject(object, outside: ["kind", "id"]); try sourceID("id")
            case "model":
                try reject(object, outside: ["kind", "id"]); try modelID("id")
            case "part":
                try reject(object, outside: ["kind", "id", "libraryID"]); try sourceID("libraryID")
                let id = try requiredString(object, "id")
                let library = try requiredString(object, "libraryID")
                guard id.hasPrefix("floe:electronics:" + library + ":") else {
                    throw FloeError.validationFailed("inputJSON.id must belong to the selected library")
                }
            default:
                throw FloeError.validationFailed("read.kind must be library, part or model")
            }
        case "download":
            try reject(object, outside: ["libraryID", "full2D"])
            let library = try string(object, "libraryID")
            let full = try boolean(object, "full2D") ?? false
            guard (library != nil) != full else {
                throw FloeError.validationFailed("download requires exactly one of libraryID or full2D=true")
            }
            if library != nil { try sourceID("libraryID") }
        case "install":
            try reject(object, outside: ["libraryID", "partID"])
            try sourceID("libraryID")
            let partID = try requiredString(object, "partID")
            let libraryID = try requiredString(object, "libraryID")
            guard partID.hasPrefix("floe:electronics:" + libraryID + ":") else {
                throw FloeError.validationFailed("inputJSON.partID must be an exact part ID returned by search or read for this library")
            }
        case "downloadModel":
            try reject(object, outside: ["modelID"]); try modelID("modelID")
        default:
            throw FloeError.validationFailed("Unsupported electronics.library action")
        }
    }

    private static func string(_ object: [String: Any], _ key: String, required: Bool = false) throws -> String? {
        guard let raw = object[key] else {
            if required { throw FloeError.validationFailed("inputJSON.\(key) is required") }
            return nil
        }
        guard let value = raw as? String, (!value.isEmpty || key == "text"), value.utf8.count <= 4_096 else {
            throw FloeError.validationFailed("inputJSON.\(key) must be a bounded non-empty string")
        }
        return value
    }

    private static func integer(_ object: [String: Any], _ key: String) throws -> Int? {
        guard let raw = object[key] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.int64Value),
              number.int64Value >= 0, number.int64Value <= 1_000_000 else {
            throw FloeError.validationFailed("inputJSON.\(key) must be a bounded non-negative integer")
        }
        return number.intValue
    }

    private static func boolean(_ object: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = object[key] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw FloeError.validationFailed("inputJSON.\(key) must be a boolean")
        }
        return number.boolValue
    }

    // MARK: - Network

    static func network(policy roles: GitHubTransportMirrorRoles,
                        archiveReader: @escaping @Sendable (URL, String) async throws -> Data) -> ElectronicsRemoteNetwork {
        let candidates: @Sendable (ElectronicsRemoteTarget) -> [URL] = { target in
            target.routes.flatMap { route in
                ElectronicsLibraryMirrorTransport.candidates(for: route.url, roles: roles)
            }
        }
        return .init(
            canonicalBytes: { url, maximum in
                try await ElectronicsRemoteHTTPDownloader().data(url, maximumBytes: maximum, redirectHosts: Self.receiptRedirectHosts)
            },
            mirroredBytes: { target, maximum in
                let routes = candidates(target)
                guard !routes.isEmpty else { throw ElectronicsLibraryMirrorTransport.Failure.invalidTarget }
                var last: Error = ElectronicsLibraryMirrorTransport.Failure.invalidResponse
                for (index, url) in routes.enumerated() {
                    try Task.checkCancellation()
                    do { return try await ElectronicsRemoteHTTPDownloader().data(url, maximumBytes: maximum,
                                                          redirectHosts: Self.dataRedirectHosts) }
                    catch {
                        if Task.isCancelled { throw CancellationError() }
                        last = error
                        guard index + 1 < routes.count,
                              ElectronicsLibraryMirrorTransport.isAvailabilityFailure(error) else { throw error }
                    }
                }
                throw last
            },
            mirroredFile: { target, maximum, destination, progress in
                let routes = candidates(target)
                guard !routes.isEmpty else { throw ElectronicsLibraryMirrorTransport.Failure.invalidTarget }
                var last: Error = ElectronicsLibraryMirrorTransport.Failure.invalidResponse
                for (index, url) in routes.enumerated() {
                    try Task.checkCancellation()
                    progress.report(received: 0, expected: nil)
                    do {
                        try await ElectronicsRemoteHTTPDownloader().download(url, to: destination, maximumBytes: maximum,
                                                      redirectHosts: Self.dataRedirectHosts, progress: progress)
                        return
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        if Task.isCancelled { throw CancellationError() }
                        last = error
                        guard index + 1 < routes.count,
                              ElectronicsLibraryMirrorTransport.isAvailabilityFailure(error) else { throw error }
                    }
                }
                throw last
            },
            archiveEntry: archiveReader
        )
    }

    static let receiptRedirectHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
        "raw.githubusercontent.com"
    ]
    static let dataRedirectHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
        "raw.githubusercontent.com", "ghfast.top", "gh-proxy.com", "gitlab.com"
    ]

    static func progress(context: ToolContext) -> ElectronicsRemoteProgress {
        guard let reporter = context.taskProgress else {
            return .init { _, _ in }
        }
        let relay = ElectronicsProgressRelay(reporter: reporter)
        return .init { received, expected in relay.report(received, expected) }
    }

    // MARK: - ZIP entry

    static func readArchiveEntry(_ archiveURL: URL, _ path: String) async throws -> Data {
        guard ElectronicsRemoteValidation.safeRelativePath(path) else {
            throw ElectronicsRemoteError.invalidCatalog("archive entry path is unsafe")
        }
        let extraction = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let archive: Archive
            do { archive = try Archive(url: archiveURL, accessMode: .read) }
            catch { throw ElectronicsRemoteError.integrity("verified library ZIP cannot be opened") }
            guard let entry = archive[path], entry.type == .file,
                  entry.uncompressedSize <= 64 * 1_024 * 1_024 else {
                throw ElectronicsRemoteError.integrity("library index entry is absent or oversized")
            }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            _ = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard data.count <= 64 * 1_024 * 1_024 - chunk.count else {
                    throw ElectronicsRemoteError.limits("library index entry")
                }
                data.append(chunk)
            }
            return data
        }
        return try await withTaskCancellationHandler {
            try await extraction.value
        } onCancel: {
            extraction.cancel()
        }
    }

}

/// Coalesces real byte progress to at most four reports per second; it never
/// invents completed/total units when the transfer does not provide them.
private final class ElectronicsProgressRelay: @unchecked Sendable {
    private let reporter: any TaskProgressReporting
    private let lock = NSLock()
    private var last = Date.distantPast
    private var lastReceived: Int64 = -1
    init(reporter: any TaskProgressReporting) { self.reporter = reporter }
    func report(_ received: Int64, _ expected: Int64?) {
        lock.lock()
        let now = Date()
        let shouldReport = now.timeIntervalSince(last) >= 0.25 || received == 0
            || (expected.map { received >= $0 } ?? false) || lastReceived < 0
        if shouldReport { last = now; lastReceived = received }
        lock.unlock()
        guard shouldReport else { return }
        Task {
            await reporter.report(TaskProgressUpdate(stage: "running", phase: "download",
                completedUnits: Int(max(0, received)),
                totalUnits: expected.flatMap { $0 > 0 ? Int($0) : nil },
                note: "Downloading electronics library"))
        }
    }
}

/// One-shot download with bounded bytes, real progress, redirect-host
/// revalidation and cooperative cancellation. Non-2xx responses surface as
/// the shared availability classification; integrity failures never do.
final class ElectronicsRemoteHTTPDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var maximumBytes = 0
    private var received: Int64 = 0
    private var finished = false
    private var redirectHosts: Set<String> = []
    private var progress: ElectronicsRemoteProgress?

    func download(_ url: URL, to destination: URL, maximumBytes: Int,
                  redirectHosts: Set<String>, progress: ElectronicsRemoteProgress) async throws {
        _ = try await run(url, destination: destination, maximumBytes: maximumBytes,
                      redirectHosts: redirectHosts, progress: progress)
    }

    func data(_ url: URL, maximumBytes: Int, redirectHosts: Set<String>) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-electronics-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload")
        _ = try await run(url, destination: file, maximumBytes: maximumBytes,
                          redirectHosts: redirectHosts, progress: .init { _, _ in })
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
            throw ElectronicsRemoteError.limits("download exceeded its byte budget")
        }
        return try Data(contentsOf: file, options: [.mappedIfSafe])
    }

    private func run(_ url: URL, destination: URL, maximumBytes: Int,
                     redirectHosts: Set<String>, progress: ElectronicsRemoteProgress) async throws -> URL {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw ElectronicsRemoteError.limits("download byte budget") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = 120
                configuration.timeoutIntervalForResource = 3_600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("FloeAgent electronics library", forHTTPHeaderField: "User-Agent")
                let task = session.downloadTask(with: request)
                lock.lock()
                guard !self.finished, !Task.isCancelled else {
                    lock.unlock()
                    task.cancel(); session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation; self.session = session; self.task = task
                self.destination = destination; self.maximumBytes = maximumBytes
                self.received = 0; self.redirectHosts = redirectHosts; self.progress = progress
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.complete(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        received = totalBytesWritten
        let progress = self.progress
        let maximum = maximumBytes
        lock.unlock()
        if totalBytesWritten > Int64(maximum) {
            complete(.failure(ElectronicsRemoteError.limits("download exceeded its byte budget")))
            return
        }
        progress?.report(received: totalBytesWritten,
                         expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            complete(.failure(ElectronicsLibraryMirrorTransport.Failure.httpStatus(status)))
            return
        }
        let expected = downloadTask.response?.expectedContentLength ?? -1
        if expected > Int64(maximumBytes) {
            complete(.failure(ElectronicsRemoteError.limits("download exceeded its byte budget")))
            return
        }
        lock.lock()
        let destination = self.destination
        lock.unlock()
        guard let destination else {
            complete(.failure(ElectronicsLibraryMirrorTransport.Failure.invalidResponse)); return
        }
        do {
            let staged = destination.deletingLastPathComponent()
                .appendingPathComponent(".floe-electronics-staging-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.moveItem(at: location, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staged, to: destination)
            complete(.success(destination))
        } catch {
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, redirectHosts.contains(host) else {
            complete(.failure(ElectronicsLibraryMirrorTransport.Failure.invalidResponse))
            completionHandler(nil); return
        }
        completionHandler(request)
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation, task = self.task, session = self.session
        self.continuation = nil; self.task = nil; self.session = nil
        self.progress = nil; self.destination = nil
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
