// FloeApp — task-owned staged-export pull service.
//
// One `BrowserStagedExportService` lives on each `BrowserTaskSession`, beside
// the Impeccable capture service and modeled on the same authority rules:
//
// * Only an authorized native tool call (runtime-issued ToolContext: task
//   owner, non-temporary, workspace root + resolved environment, authorized
//   destination path) can start an export. The page NEVER initiates anything:
//   there is no WKScriptMessageHandler, no registered page channel and no
//   ambient write path — the operation is a native-issued fixed-script PULL
//   of the page's own staged raster (`window.__posterExport` /
//   `window.__artExport` staged by the reviewed art/canvas packages).
// * The export is bound at issue time to the exact session/tab/documentID/
//   documentGeneration and to the tab's committed loopback URL, which must be
//   this conversation's OWN authorized local endpoint (the LocalService/
//   preview registry behind `BrowserURLPolicy`), not a generic host test.
//   Every suspension point re-checks the live binding; any navigation,
//   document swap, endpoint revocation, tab close, user takeover, owner
//   handoff, session release or cancellation fences the export and removes
//   its staging bytes. A fenced or late export can never commit.
// * Bytes are untrusted data: declared size is capped BEFORE any chunk is
//   requested, every chunk's encoded length is bounded BEFORE base64 decode,
//   decoded chunks stream straight into an exclusively created staging file in
//   app-private storage (never one whole-blob buffer on the main actor), and the
//   commit requires the exact declared byte count, the page-declared SHA-256 to
//   equal the native-computed digest, the digest recomputed from the published
//   inode, and the PNG structural contract (signature, IHDR dimensions/color
//   contract, terminal IEND). The deep content walk stays with the package's
//   verify_png.py, as its SKILL contract requires.
// * Publication goes through `StagedExportFileTransaction`: bytes are staged in
//   a service-owned private directory outside every mounted workspace, and the
//   destination directory is anchored by descriptor under the authorized
//   workspace root (nofollow walk, `..` containment proof, authorized-path name
//   binding). Publication is one atomic no-overwrite syscall across those two
//   descriptors, so it never follows a symlink, never overwrites an existing
//   destination, never publishes an inode it did not write, and never deletes a
//   file it did not create. A path-based exclusive-create plus a path-based link
//   would leave the ancestors and the staging name open to any concurrent writer
//   of the workspace; the anchored transaction is the authority here, and the
//   path-based pre-flight below is only an early, user-friendly refusal.
//
// Page output is data, never authority: nothing returned by the script can
// choose the destination, widen a bound, or mint a write.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Foundation
import CryptoKit
import WebKit
import FloeCore
import FloeTools

// MARK: - Transport seam

/// Fixed-script read-back transport. Production is the WebKit implementation
/// below (the ONLY script it ever runs is `StagedExportScript.source`, with
/// data-only arguments); focused tests inject a deterministic transport so
/// the real validation, fencing, staging and commit paths run without a live
/// page. Mirrors `ImpeccableMeasurementTransport`.
@MainActor
protocol StagedExportTransport: AnyObject {
    func call(
        arguments: [String: Any],
        in webView: WKWebView,
        exportID: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> [String: Any]

    /// Fail every in-flight call for one export (synchronous fence).
    func fenceInFlight(exportID: UUID, reason: String)
}

/// Single-shot WebKit call with the same guarantees as `BrowserProbeRequest`
/// (which it reuses): exactly one resolution on callback, deadline,
/// cancellation or fence; no unbounded wait for an uncooperative page. The
/// reply crosses as JSON Data and is re-materialized as a dictionary on the
/// main actor.
@MainActor
final class StagedExportWebKitTransport: StagedExportTransport {
    private var calls: [UUID: [BrowserProbeRequest]] = [:]

    func call(
        arguments: [String: Any],
        in webView: WKWebView,
        exportID: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> [String: Any] {
        let request = BrowserProbeRequest()
        calls[exportID, default: []].append(request)
        defer {
            if let group = calls[exportID],
               let index = group.firstIndex(where: { $0 === request }) {
                var remaining = group
                remaining.remove(at: index)
                if remaining.isEmpty { calls[exportID] = nil } else { calls[exportID] = remaining }
            }
        }
        let data = try await request.run(deadline: deadline) { completion in
            webView.callAsyncJavaScript(
                StagedExportScript.source,
                arguments: arguments,
                in: nil,
                in: .page,
                completionHandler: completion
            )
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dictionary = object as? [String: Any] else {
            throw StagedExportError.invalidReply("read-back reply is not an object")
        }
        return dictionary
    }

    func fenceInFlight(exportID: UUID, reason: String) {
        for request in calls[exportID] ?? [] { request.invalidate() }
        calls[exportID] = nil
    }
}

// MARK: - Streamed staging sink

/// Append-only sink over the anchored transaction: every decoded chunk goes
/// straight to the staging descriptor; only bounded head/tail windows and a
/// running SHA-256 stay in memory. The full raster is never one buffer on the
/// main actor, and because the bytes target a descriptor rather than a path, a
/// concurrent writer renaming or replacing the staging name cannot redirect
/// them.
private final class StagedExportFileSink: StagedExportByteSinking {
    private let transaction: StagedExportFileTransaction
    private var digest = SHA256()
    private var head = Data()
    private var tail = Data()
    private var finished = false
    private(set) var bytesAppended = 0

    init(transaction: StagedExportFileTransaction) {
        self.transaction = transaction
    }

    var headBytes: Data { head }
    var tailBytes: Data { tail }

    func append(_ data: Data) throws {
        guard !finished else { throw StagedExportError.storage("sink used after finalize") }
        guard !data.isEmpty else { return }
        do {
            try transaction.append(data)
        } catch let error as StagedExportFileTransactionError {
            throw Self.map(error)
        }
        digest.update(data: data)
        bytesAppended += data.count
        if head.count < 64 {
            head.append(data.prefix(64 - head.count))
        }
        tail = Data((tail + data).suffix(16))
    }

    /// Seals the staged bytes (flushed to stable storage and re-measured
    /// against exactly what was appended) and returns the native-computed
    /// SHA-256 hex. Called exactly once on the success path, before the commit.
    func finalizeDigest() throws -> String {
        guard !finished else { throw StagedExportError.storage("sink finalized twice") }
        do {
            try transaction.seal(expectedBytes: Int64(bytesAppended))
        } catch let error as StagedExportFileTransactionError {
            finished = true
            throw Self.map(error)
        }
        finished = true
        let finalized = digest.finalize()
        return finalized.map { String(format: "%02x", $0) }.joined()
    }

    func discard() {
        finished = true
        transaction.abort()
    }

    /// Maps a transaction refusal onto the frozen staged-export error surface.
    /// An occupied destination stays a `rejected` outcome (the caller can choose
    /// another path); every integrity or I/O refusal stays `storage`, which the
    /// events surface reports without echoing file content.
    static func map(_ error: StagedExportFileTransactionError) -> StagedExportError {
        switch error {
        case .destinationOccupied(let reason):
            .rejected([reason + "; nothing was overwritten"])
        case .anchorRefused(let reason), .crossDevice(let reason),
             .containmentLost(let reason), .stagedNameReplaced(let reason),
             .commitIdentityMismatch(let reason), .commitContentChanged(let reason),
             .storage(let reason):
            .storage(reason)
        }
    }
}

// MARK: - Service

@MainActor
final class BrowserStagedExportService {
    enum FenceReason: String, Sendable {
        case navigation
        case reload
        case documentSwap
        case tabClosed
        case userTakeover
        case ownerHandoff
        case released
        case taskCancelled
        case endpointRevoked
    }

    /// The authorized destination + binding expectations of one export call.
    /// `workspaceRootURL` is the task's authorized workspace root exactly as the
    /// tool context resolved it: the staged commit anchors on that directory by
    /// descriptor and proves the destination sits inside it. `destinationURL` is
    /// the guard-resolved physical path (validated with `.createNew` semantics by
    /// the caller) and must be `workspaceRootURL` + `relativePath`.
    /// `relativePath` is the workspace-relative form used for the receipt.
    struct Request {
        var tabID: UUID
        var workspaceRootURL: URL
        var destinationURL: URL
        var relativePath: String
        var expectedWidth: Int?
        var expectedHeight: Int?
    }

    /// One in-flight export. Fences are synchronous from the session
    /// lifecycle points; the pull loop re-checks after every suspension.
    private final class InFlight {
        let exportID: UUID
        let tabID: UUID
        var fenceReason: String?
        init(exportID: UUID, tabID: UUID) {
            self.exportID = exportID
            self.tabID = tabID
        }
    }

    /// Name of the service-owned private staging directory. It lives in
    /// app-private temporary storage, outside every mounted workspace, so the
    /// staged bytes are never a workspace file and no workspace writer — neither
    /// another tool nor model-authored code in the resolved environment — can
    /// name, read or replace them. Nothing is ever delivered here.
    static let stagingDirectoryName = "FloeStagedExport"

    private weak var session: BrowserTaskSession?
    private let transport: StagedExportTransport
    /// Read-only query against the real owned-preview/local-service registry.
    /// Injected for tests; production is the BrowserURLPolicy registry check.
    private let endpointAuthorizer: @MainActor (URL, UUID) -> Bool
    private let fileManager: FileManager
    /// Private staging directory for the bytes in flight. Injectable for tests.
    private let stagingDirectoryURL: URL
    private var activeExports: [UUID: InFlight] = [:]

    init(
        session: BrowserTaskSession,
        transport: StagedExportTransport = StagedExportWebKitTransport(),
        fileManager: FileManager = .default,
        stagingDirectoryURL: URL? = nil,
        endpointAuthorizer: (@MainActor (URL, UUID) -> Bool)? = nil
    ) {
        self.session = session
        self.transport = transport
        self.fileManager = fileManager
        self.stagingDirectoryURL = stagingDirectoryURL ?? fileManager.temporaryDirectory
            .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
        self.endpointAuthorizer = endpointAuthorizer ?? { url, conversationID in
            BrowserURLPolicy.isOwnedLocalEndpoint(url, conversationID: conversationID)
        }
    }

    // MARK: Export

    /// Runs one authorized staged-file export end to end. Throws
    /// `StagedExportError`; every failure path leaves the destination
    /// untouched and removes this export's own staging file.
    func export(_ request: Request, cancellation: CancellationToken) async throws -> StagedExportReceipt {
        guard let session, !session.isReleased else {
            throw StagedExportError.fenced(FenceReason.released.rawValue)
        }
        guard !session.isUserControlling else {
            throw StagedExportError.rejected(["the user currently controls this task's browser"])
        }
        guard activeExports.isEmpty else {
            throw StagedExportError.rejected(["another staged export is already in flight for this task"])
        }
        guard let tab = session.tabs.first(where: { $0.id == request.tabID }) else {
            throw StagedExportError.unavailable("the browser tab is no longer available")
        }
        guard let endpoint = tab.webView.url else {
            throw StagedExportError.rejected(["the tab has no committed document; open the artifact preview first"])
        }
        guard endpointAuthorizer(endpoint, session.conversationID) else {
            throw StagedExportError.rejected([
                "the tab is not showing this task's own authorized local preview; start the artifact preview and open it in this task's browser first"
            ])
        }
        // Authoritative anchor: the tool context's workspace root plus the
        // declared relative path, which the commit walks by descriptor and
        // proves contained. No path-based check is the exclusion guarantee.
        guard !request.relativePath.split(separator: "/").contains("..") else {
            throw StagedExportError.rejected(["the destination must not traverse upward"])
        }
        let anchored: StagedExportFileTransaction.Anchor
        do {
            anchored = try StagedExportFileTransaction.anchor(
                workspaceRootURL: request.workspaceRootURL,
                destinationURL: request.destinationURL,
                relativePath: request.relativePath)
        } catch let error as StagedExportFileTransactionError {
            throw StagedExportFileSink.map(error)
        }
        // Advisory pre-flight, so an ordinary mistake is refused with an
        // actionable message before any page read: the parent must be a real
        // directory and the destination must not exist. The anchored commit
        // re-proves both against races, so this check is never load-bearing.
        let parent = request.destinationURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw StagedExportError.storage("the destination directory does not exist")
        }
        guard !fileManager.fileExists(atPath: request.destinationURL.path) else {
            throw StagedExportError.rejected(["a file already exists at the destination; nothing was overwritten"])
        }

        let documentID = tab.documentID
        let documentGeneration = tab.documentGeneration
        let exportID = UUID()
        let record = InFlight(exportID: exportID, tabID: request.tabID)
        activeExports[exportID] = record
        // The staging name lives in the private staging directory, so workspace
        // writers can neither reach the staged bytes nor contest its retirement.
        let stagingName = "floe-export-\(exportID.uuidString).part"
        var sink: StagedExportFileSink?
        var committed = false
        defer {
            activeExports.removeValue(forKey: exportID)
            if !committed { sink?.discard() }
        }
        let overallDeadline = ContinuousClock.now.advanced(
            by: .milliseconds(StagedExportContract.overallTimeoutMilliseconds))

        do {
            let stagingDirectoryPath = try Self.prepareStagingDirectory(
                at: stagingDirectoryURL, fileManager: fileManager)
            let transaction: StagedExportFileTransaction
            do {
                transaction = try StagedExportFileTransaction.open(
                    stagingDirectoryPath: stagingDirectoryPath,
                    stagingName: stagingName,
                    rootPath: anchored.rootPath,
                    directoryComponents: anchored.directoryComponents,
                    destinationName: anchored.destinationName)
            } catch let error as StagedExportFileTransactionError {
                throw StagedExportFileSink.map(error)
            }
            let staged = StagedExportFileSink(transaction: transaction)
            sink = staged

            // 1. Descriptor pull (metadata only; caps decided before bytes).
            try cancellation.throwIfCancelled()
            let liveTab = try liveBinding(record: record, documentID: documentID,
                                          documentGeneration: documentGeneration, endpoint: endpoint)
            let descriptorNonce = UUID().uuidString
            let descriptorReply = try await call(
                record: record, webView: liveTab.webView,
                arguments: StagedExportScript.descriptorArguments(nonce: descriptorNonce),
                deadline: overallDeadline)
            let (descriptor, descriptorRejections) = StagedExportValidation.decodeDescriptor(
                descriptorReply,
                expectedNonce: descriptorNonce,
                expectedLocation: endpoint.absoluteString,
                expectedWidth: request.expectedWidth,
                expectedHeight: request.expectedHeight)
            guard let descriptor, descriptorRejections.isEmpty else {
                throw StagedExportError.rejected(descriptorRejections)
            }
            let (chunkCount, totalChars, planRejections) = StagedExportValidation.chunkPlan(for: descriptor)
            guard planRejections.isEmpty else {
                throw StagedExportError.rejected(planRejections)
            }

            // 2. Bounded chunk pull; re-bind after every suspension.
            var remainingBytes = descriptor.bytes
            for index in 0..<chunkCount {
                try bindingOrFence(record: record, documentID: documentID,
                                   documentGeneration: documentGeneration, endpoint: endpoint)
                try cancellation.throwIfCancelled()
                let current = try liveBinding(record: record, documentID: documentID,
                                              documentGeneration: documentGeneration, endpoint: endpoint)
                let chunkNonce = UUID().uuidString
                let reply = try await call(
                    record: record, webView: current.webView,
                    arguments: StagedExportScript.chunkArguments(source: descriptor.source,
                                                                 index: index, nonce: chunkNonce),
                    deadline: overallDeadline)
                let (data, chunkRejections) = StagedExportValidation.decodeChunk(
                    reply,
                    expectedNonce: chunkNonce,
                    expectedLocation: endpoint.absoluteString,
                    expectedIndex: index,
                    expectedTotalChars: totalChars,
                    remainingBytes: remainingBytes)
                guard let data, chunkRejections.isEmpty else {
                    throw StagedExportError.rejected(chunkRejections)
                }
                remainingBytes -= data.count
                try staged.append(data)
            }

            // 3. Final gates before the commit point.
            try bindingOrFence(record: record, documentID: documentID,
                               documentGeneration: documentGeneration, endpoint: endpoint)
            try cancellation.throwIfCancelled()
            guard staged.bytesAppended == descriptor.bytes else {
                throw StagedExportError.rejected([
                    "delivered \(staged.bytesAppended) bytes != declared \(descriptor.bytes)"
                ])
            }
            let structural = StagedExportPNGStructure.rejections(
                head: staged.headBytes,
                tail: staged.tailBytes,
                totalBytes: staged.bytesAppended,
                declaredWidth: descriptor.width,
                declaredHeight: descriptor.height,
                expectedWidth: request.expectedWidth,
                expectedHeight: request.expectedHeight)
            guard structural.isEmpty else {
                throw StagedExportError.rejected(structural)
            }
            let nativeSHA = try staged.finalizeDigest()
            guard nativeSHA == descriptor.sha256 else {
                throw StagedExportError.rejected([
                    "native sha256 does not match the staged declaration; the raster changed or is corrupt"
                ])
            }

            // 4. Commit through the anchored transaction: exclusive (an
            // occupied destination fails and nothing is overwritten), never
            // following a planted symlink, never adopting an inode it did not
            // write, verified after the link and re-verified against the anchor
            // before anything is reported as delivered.
            try bindingOrFence(record: record, documentID: documentID,
                               documentGeneration: documentGeneration, endpoint: endpoint)
            try cancellation.throwIfCancelled()
            let commit: StagedExportFileTransaction.Commit
            do {
                // The digest the page declared and the native streamed digest
                // already agree; the transaction recomputes it from the published
                // inode itself, so a payload rewritten during the pull is a
                // failure rather than a delivery.
                commit = try transaction.commit(expectedSHA256: nativeSHA)
            } catch let error as StagedExportFileTransactionError {
                throw StagedExportFileSink.map(error)
            }
            guard commit.bytes == Int64(descriptor.bytes),
                  commit.contentSHA256 == nativeSHA else {
                throw StagedExportError.storage(
                    "the published file does not match the verified export bytes")
            }
            committed = true

            var deliveryDetail = "\(descriptor.name) bytes=\(descriptor.bytes) \(descriptor.width)x\(descriptor.height) sha256=\(nativeSHA) path=\(request.relativePath)"
            if !commit.stagingRetired {
                // Honest surfacing: the export is delivered and verified, but the
                // private staging name could not be retired.
                deliveryDetail += " staging-leftover=true"
            }
            session.appendEvent(
                tabID: request.tabID,
                method: "Browser.exportDelivered",
                detail: deliveryDetail)
            return StagedExportReceipt(
                state: "delivered",
                exportID: exportID.uuidString,
                path: request.relativePath,
                stagedName: descriptor.name,
                source: descriptor.source.rawValue,
                bytes: descriptor.bytes,
                sha256: nativeSHA,
                declaredSHA256Matched: true,
                width: descriptor.width,
                height: descriptor.height,
                documentGeneration: documentGeneration,
                endpoint: endpoint.absoluteString)
        } catch {
            Self.recordRejection(on: session, tabID: request.tabID, error: error)
            throw error
        }
    }

    // MARK: Fencing (session lifecycle hooks)

    func fence(exportID: UUID, reason: FenceReason) {
        guard let record = activeExports[exportID], record.fenceReason == nil else { return }
        record.fenceReason = reason.rawValue
        transport.fenceInFlight(exportID: exportID, reason: reason.rawValue)
    }

    func fenceTab(_ tabID: UUID, reason: FenceReason) {
        for record in activeExports.values where record.tabID == tabID {
            fence(exportID: record.exportID, reason: reason)
        }
    }

    func fenceAll(reason: FenceReason) {
        for exportID in Array(activeExports.keys) {
            fence(exportID: exportID, reason: reason)
        }
    }

    var activeExportCount: Int { activeExports.count }

    // MARK: Binding checks

    /// Synchronous binding gate: fence state, live session/tab, exact
    /// document identity and the still-authorized owned endpoint.
    @discardableResult
    private func liveBinding(
        record: InFlight,
        documentID: String,
        documentGeneration: Int,
        endpoint: URL
    ) throws -> BrowserTaskSession.Tab {
        if let reason = record.fenceReason {
            throw StagedExportError.fenced(reason)
        }
        guard let session, !session.isReleased else {
            throw StagedExportError.fenced(FenceReason.released.rawValue)
        }
        guard !session.isUserControlling else {
            throw StagedExportError.fenced(FenceReason.userTakeover.rawValue)
        }
        guard let tab = session.tabs.first(where: { $0.id == record.tabID }) else {
            throw StagedExportError.fenced(FenceReason.tabClosed.rawValue)
        }
        guard tab.documentID == documentID, tab.documentGeneration == documentGeneration else {
            throw StagedExportError.fenced("document changed during export")
        }
        guard let url = tab.webView.url, url.absoluteString == endpoint.absoluteString else {
            throw StagedExportError.fenced("the bound page navigated during export")
        }
        guard endpointAuthorizer(url, session.conversationID) else {
            throw StagedExportError.fenced(FenceReason.endpointRevoked.rawValue)
        }
        return tab
    }

    private func bindingOrFence(
        record: InFlight,
        documentID: String,
        documentGeneration: Int,
        endpoint: URL
    ) throws {
        _ = try liveBinding(record: record, documentID: documentID,
                            documentGeneration: documentGeneration, endpoint: endpoint)
    }

    private func call(
        record: InFlight,
        webView: WKWebView,
        arguments: [String: Any],
        deadline: ContinuousClock.Instant
    ) async throws -> [String: Any] {
        let perCall = ContinuousClock.now.advanced(
            by: .milliseconds(StagedExportContract.perCallTimeoutMilliseconds))
        let effective = min(deadline, perCall)
        guard ContinuousClock.now < effective else {
            throw StagedExportError.unavailable("staged export timed out")
        }
        do {
            return try await transport.call(arguments: arguments, in: webView,
                                            exportID: record.exportID, deadline: effective)
        } catch let error as BrowserProbeError {
            if let reason = record.fenceReason {
                throw StagedExportError.fenced(reason)
            }
            switch error {
            case .timedOut:
                throw StagedExportError.unavailable("the page did not answer the fixed read-back call in time")
            case .released:
                throw StagedExportError.fenced(record.fenceReason ?? FenceReason.released.rawValue)
            }
        } catch is CancellationError {
            throw StagedExportError.fenced(FenceReason.taskCancelled.rawValue)
        } catch let error as StagedExportError {
            throw error
        } catch {
            throw StagedExportError.unavailable("the fixed read-back call failed")
        }
    }

    /// Creates the private staging directory on demand, owner-only, and returns
    /// its physical path. This is app-private transient storage for bytes in
    /// flight; it is never a deliverable location and never inside a workspace.
    private static func prepareStagingDirectory(at url: URL, fileManager: FileManager) throws -> String {
        let physical = url.standardizedFileURL.resolvingSymlinksInPath()
        do {
            try fileManager.createDirectory(
                at: physical,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: physical.path)
        } catch {
            throw StagedExportError.storage("the private export staging directory could not be prepared")
        }
        return physical.path
    }

    /// Content-free rejection observability on the existing browser events
    /// surface. Never echoes page text or byte content.
    private static func recordRejection(on session: BrowserTaskSession?, tabID: UUID, error: Error) {
        let detail: String
        switch error {
        case StagedExportError.rejected(let reasons):
            detail = String(reasons.joined(separator: "; ").prefix(400))
        case StagedExportError.fenced(let reason):
            detail = "fenced: \(reason)"
        case StagedExportError.unavailable(let reason):
            detail = "unavailable: \(reason)"
        case StagedExportError.invalidReply:
            detail = "the fixed read-back returned an unusable reply"
        case StagedExportError.storage(let reason):
            detail = "storage: \(reason)"
        case is CancellationError:
            detail = "fenced: \(FenceReason.taskCancelled.rawValue)"
        case let floe as FloeError where floe == .cancelled:
            detail = "fenced: \(FenceReason.taskCancelled.rawValue)"
        default:
            detail = "failed"
        }
        session?.appendEvent(tabID: tabID, method: "Browser.exportRejected", detail: detail)
    }
}
#endif
