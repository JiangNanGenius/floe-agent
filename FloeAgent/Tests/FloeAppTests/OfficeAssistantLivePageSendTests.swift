// SPDX-License-Identifier: MPL-2.0
// FloeAppTests — Office ASSISTANT SENDER contract for build 283 (job-29206d4ffa9644d3
// superseded by the Office283 region follow-up).
//
// ONE end-to-end App-host integration qualification test over a REAL mounted
// OfficeDocumentSurface showing a real XLSX with a VISIBLE BUT UNSAVED stroke
// (drawn through the existing tested gate path from
// OfficeLiveInkAppQualificationTests.swift):
//
//   1. DEFAULT SEND CARRIES NO MANDATORY OFFICE VIEWPORT SNAPSHOT. The
//      canonical ThreadDetailViewModel.send -> ConversationCenter.startRun
//      request carries the exact user goal text, the task context and the
//      user's own staged attachment — and ZERO auto-captured Office page
//      images. The saved package is still untouched at send time.
//   2. The assistant inspects specific regions DELIBERATELY through
//      notes.read section=officeRegion (job-cf21c7009ba746c7): its real PNG
//      artifacts are bounded tool evidence that the provider vision resolver
//      attaches to the NEXT provider request. In this mounted harness the
//      editable session has no autosave owner installed, so the staging
//      transaction refuses honestly and NOTHING is rendered — the truthful
//      refusal contract — while the production owner route is qualified in
//      the primary hosted region suite.
//
// Proven by REAL pixels, not metadata: while the pen is down the live preview
// paints visible red ink, and the on-disk saved package is independently
// verified unchanged (identical SHA-256, zero custGeom ink vectors) — so the
// provider request provably carries NO current-view image, while the user's
// own staged attachment arrives byte-identical.
//
// Boundaries (by design):
// - No network, no Keychain, no provider secrets: the adapter is the scripted
//   recording stand-in for the ONLY provider in this isolated
//   AppEnvironment.preview() graph (in-memory database; the fake
//   ProviderProfile carries no secretRef so resolveCredentials never reads).
// - The provider is vision-capable so canonical visualEvidence routes the
//   user attachment inline; this test never hand-authors a provider request.
// - This sender-proof mount owns no Notes commit route; the bind closure
//   deliberately reports "no commit performed" and the region staging
//   transaction's honest refusal is the asserted behavior here.
// - Isolated Notes store via the existing NotesRepository.setStoreOverride
//   seam; the user's real Notes library is never opened. Own window is
//   mounted on the real foreground UIWindowScene and restored.
//
// Opt-in native/Simulator qualification; source-parsed here, execution and
// final acceptance are owned by the primary:
//   membership: project.yml FloeAppTests sources +=
//     - path: Tests/FloeAppTests/OfficeAssistantLivePageSendTests.swift
//   then `bash FloeAgent/scripts/gen_project.sh`.
//   run: FLOE_OFFICE_SENDER_PROOF=1 xcodebuild test-without-building \
//     -only-testing:FloeAppTests/OfficeAssistantLivePageSendTests \
//     (canonical single reused iPad per FloeAgent/scripts/select_test_simulator.py,
//      -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1)
#if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import XCTest
import UIKit
import SwiftUI
import WebKit
import ZIPFoundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
import FloeProviders
import FloeNotes
import FloeDocuments
import FloeOfficeNative
@testable import FloeApp

@MainActor
final class OfficeAssistantLivePageSendTests: XCTestCase {
    /// The single acceptance test: a default send carries the user goal and
    /// the user's own staged attachment to the provider with NO mandatory
    /// Office viewport snapshot, while the unsaved live stroke exists only
    /// in the editor; a deliberate officeRegion read on this owner-less
    /// mount refuses honestly and renders nothing.
    func testDefaultSendOmitsOfficeSnapshotAndUserAttachmentSurvives() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_OFFICE_SENDER_PROOF"] == "1" else {
            throw XCTSkip("Opt-in App-host Office live-page sender proof (native engine + real WebKit pixels required)")
        }
        XCTAssertTrue(UIView.areAnimationsEnabled,
                      "Sender proof runs with production UIKit animation timing")
        executionTimeAllowance = 300
        continueAfterFailure = false

        // MARK: - Isolated canonical App graph (existing preview seams only)
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        environment.markIsolatedLaunchReadyForTesting()
        let center = ConversationCenter(environment: environment)
        defer { center.providerAdapterTestOverride = nil }

        // Isolated fake provider/model with REAL vision capability. No
        // secretRef is ever set, so ConversationCenter.resolveCredentials
        // returns empty credentials without any Keychain access.
        let configuration = ModelConfigurationStore(database: environment.database)
        let provider = ProviderProfile(
            kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://senderproof.invalid/v1")!
        )
        let model = ModelProfile(
            providerID: provider.id, remoteModelID: "sender-proof-vision",
            displayName: "Sender Proof Vision", limits: .init(contextTokens: 4096, maxOutputTokens: 1024),
            capabilities: [.text, .tools, .vision]
        )
        try await configuration.saveProvider(provider)
        try await configuration.saveModel(model)
        var preferences = try await configuration.preferences()
        preferences.defaultAgentModelID = model.id
        try await configuration.savePreferences(preferences)

        // MARK: - Task-owned workspace
        let baseToken = "Sender proof"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-sender-proof-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("\(baseToken).xlsx")
        try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
            .init(name: baseToken, rows: [[baseToken.uppercased(), "12"], ["Sum", "=B1*2"]])
        ])
        let originalHash = try FloeDigest.sha256Hex(ofFileAt: source)

        // FilesCenter stages the live-page JPEG into the app container's
        // canonical attachments directory; only files this run added (unique
        // "<uuid>-Sender proof…" names) are removed at teardown.
        let support = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let attachmentsDirectory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        let stagedBefore = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path)) ?? [])
        var stagedExtra: [String] = []
        func resolveStagedAdditions() {
            let current = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path)) ?? [])
            stagedExtra = current.subtracting(stagedBefore).filter { $0.contains(baseToken) }
        }
        defer {
            for name in stagedExtra {
                try? FileManager.default.removeItem(at: attachmentsDirectory.appendingPathComponent(name))
            }
        }

        // The isolated Notes store must be installed on the EXISTING
        // NotesRepository.setStoreOverride seam BEFORE the center's first
        // reload(): reload reconciles assistant ownership through the shared
        // repository, and an unset override would lazily open the real user
        // library. From here on every canonical Notes read in this process
        // resolves only this task-owned store; teardown restores nil.
        let store = try NotesStore(root: root.appendingPathComponent("notes-store"))
        await NotesRepository.shared.setStoreOverride(store)

        await center.reload()

        let box = SenderProofCaptureBox()
        center.providerAdapterTestOverride = { _, ownerRunID in
            RecordingSenderProofAdapter(box: box, ownerRunID: ownerRunID)
        }

        let session = OfficeFileSession()
        do {
            // MARK: - Real mounted Office current view
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: OfficeDocumentSurface(session: session))
            window.windowLevel = .normal + 1
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

            let imported = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
            let document = try await store.create(imported)
            XCTAssertEqual(document.kind, .office)
            XCTAssertNotNil(document.officeResourceID)
            XCTAssertEqual(document.officeFileName, "\(baseToken).xlsx")

            let conversation = try await center.createConversation(title: "\(baseToken) assistant", purpose: .notes)
            let conversationID = conversation.id
            try await store.bindAssistant(conversationID: conversationID, documentID: document.id, canEdit: true)
            XCTAssertNotNil(environment.workspaceCenter.workspaceID(for: conversationID),
                            "The production Notes creation path must establish canonical workspace ownership")
            defer { ComposerDraftStore.shared.clear(conversationID: conversationID) }

            // Bind exactly through the production seams the assistant panel
            // uses: conversation -> selected document -> live session.
            NotesAssistantConversationBinding.map(conversationID: conversationID, documentID: document.id)
            defer { NotesAssistantConversationBinding.unmap(conversationID: conversationID, documentID: document.id) }
            NotesOfficeLiveBinding.bind(documentID: document.id, session: session) {
                // This sender-proof mount owns no Notes commit route (the
                // parent lane does). The capture/send path never invokes this
                // closure; if anything ever did, it must truthfully report
                // "no commit performed" rather than fabricate a revision.
                NotesOfficeCommitOutcome(committed: false, revision: nil, resourceID: nil,
                                         packageSHA256: nil, hadUnsavedChanges: true,
                                         message: "Sender-proof qualification mount performs no Notes commit.")
            }
            defer { NotesOfficeLiveBinding.unbind(documentID: document.id, session: session) }

            await session.open(source)
            try await wait { session.canAct && session.documentActionsReady && session.controller != nil }
            if session.readOnly {
                let entered = await session.requestEditing()
                XCTAssertTrue(entered, session.error ?? "Edit entry rejected")
            }
            try await wait { !session.readOnly && session.canAct && session.documentActionsReady }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await wait {
                let facts = OfficeFileSession.hostRenderDiagnostics(native)
                return facts["stage"] == "visible-render" && facts["docLoaded"] == "1"
            }
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))

            // Baseline of the SAME live view before any ink exists.
            let baseline = try await snapshot(web, label: "sender-proof-baseline-before-ink")

            session.useInkPreferences(workspaceIdentity: root.path, documentKey: source.lastPathComponent)
            let preferences = session.inkPreferences
            let old = preferences.stroke
            defer {
                preferences.setPreset(old.preset); preferences.setColorHex(old.colorHex)
                preferences.setWidthMillimeters(old.widthMillimeters)
                preferences.setTransparencyPercent(old.transparencyPercent)
            }
            preferences.setPreset(.marker)
            preferences.setColorHex("#FF0000")
            preferences.setWidthMillimeters(4)
            try await session.toggleDrawing()
            await session.applyInkPreferences()
            XCTAssertNil(session.inkError)

            // The existing tested gate path: synthetic pen contact through
            // the real PointerEvent bridge; one visible frame while the pen
            // is still down proves presentation ordering; then lift. The
            // stroke is NEVER saved — no saveInPlace, no commit.
            let beforeContact = baseline
            _ = try await web.callAsyncJavaScript(Self.beginAndMove,
                arguments: ["contactIndex": 0], in: nil, contentWorld: .page)
            let during = try await snapshot(web, label: "sender-proof-while-pen-is-down")
            let stillDown = try await web.evaluateJavaScript("window.__floeOfficePenState().activeStroke") as? Bool
            XCTAssertEqual(stillDown, true, "Evidence frame must be captured before pointerup")
            XCTAssertGreaterThan(redPixels(during) - redPixels(beforeContact), 40,
                                 "The live preview must already paint visible pixels while the pen is down")
            _ = try await web.evaluateJavaScript(Self.liftPen)
            try await Task.sleep(for: .milliseconds(750))
            let afterLift = try await web.evaluateJavaScript("window.__floeOfficePenState().activeStroke") as? Bool
            XCTAssertEqual(afterLift, false)
            let pendingPreview = try await web.evaluateJavaScript(
                "window.__floeOfficePenPreview ? window.__floeOfficePenPreview().pending : -1") as? Int
            XCTAssertEqual(pendingPreview, 0, "The overlay must hand off before the send captures the canvas")
            let position = try await web.evaluateJavaScript(Self.committedInkPosition) as? [String: Any]
            let positionJSON = try JSONSerialization.data(
                withJSONObject: try XCTUnwrap(position as? [String: Any]), options: [.sortedKeys])
            let positionAttachment = XCTAttachment(string: String(decoding: positionJSON, as: UTF8.self))
            positionAttachment.name = "sender-proof-committed-ink-position"
            positionAttachment.lifetime = .keepAlways; add(positionAttachment)
            XCTAssertGreaterThan(position?["pixels"] as? Int ?? 0, 80,
                                 "The lifted stroke must live in the committed canvas while the package stays unsaved")

            // The production live readout itself reports the unsaved state
            // against the unchanged saved package, right before the send.
            let readout = try await session.liveEnginePageReadout()
            XCTAssertTrue(readout.hadUnsavedChanges,
                          "The current view must hold unsaved edits for the sender proof scenario")
            XCTAssertEqual(readout.committedSHA256, originalHash,
                           "The saved package must still be the untouched original at capture time")
            XCTAssertEqual(readout.captureScope, "liveDocumentViewSnapshot")
            let readoutImage = try XCTUnwrap(UIImage(data: readout.page.pngData))
            let readoutAttachment = XCTAttachment(image: readoutImage)
            readoutAttachment.name = "sender-proof-live-readout-page"
            readoutAttachment.lifetime = .keepAlways; add(readoutAttachment)
            XCTAssertGreaterThan(redPixels(readoutImage), 80,
                                 "The live readout itself must contain the current red ink")

            // MARK: - Canonical send through ThreadDetailViewModel
            // Build 283 sender contract: a default send carries the exact user
            // goal plus the user's OWN staged attachment — and no mandatory
            // Office viewport snapshot. The tiny white PNG proves the live
            // red stroke never travels: its red count is exactly zero.
            let userName = "user-note-\(UUID().uuidString).png"
            let userPNG = try Self.plainWhitePNG()
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            try userPNG.write(to: attachmentsDirectory.appendingPathComponent(userName), options: .atomic)
            defer { try? FileManager.default.removeItem(at: attachmentsDirectory.appendingPathComponent(userName)) }
            let userAttachment = AttachmentRef(
                kind: .image, displayName: userName, uti: "public.png",
                byteCount: userPNG.count, sha256: FloeDigest.sha256Hex(userPNG),
                storage: .applicationSupport, relativePath: userName)
            let goal = "Use the handwritten totals visible on the current sheet and write them into cells A1 and B1 of this workbook"
            let viewModel = ThreadDetailViewModel(conversationID: conversationID, center: center)
            viewModel.draft = goal
            viewModel.attachments = [userAttachment]
            await viewModel.send()
            XCTAssertNil(viewModel.actionError,
                         "Canonical send failed: \(viewModel.actionError ?? "")")
            XCTAssertTrue(viewModel.draft.isEmpty)
            // Successful canonical handoff clears the composer. The durable
            // message and provider assertions below prove the user's exact
            // attachment was transferred once, without an Office snapshot.
            XCTAssertTrue(viewModel.attachments.isEmpty,
                          "Sent attachments must leave the composer after successful handoff")

            // Build 283: a default send stages NO Office snapshot file at all.
            resolveStagedAdditions()
            XCTAssertEqual(stagedExtra.count, 0,
                           "A default send must not stage any live Office page file")

            // MARK: - Canonical run/message ownership
            let runs = try await environment.runStore.runs(conversationID: conversationID)
            XCTAssertEqual(runs.count, 1)
            let run = try XCTUnwrap(runs.first)
            XCTAssertEqual(run.goal, goal)
            XCTAssertEqual(viewModel.selectedRunID, run.id)
            let messages = try await environment.conversationStore.messages(conversationID: conversationID)
            let userMessages = messages.filter { $0.role == "user" }
            XCTAssertEqual(userMessages.count, 1)
            XCTAssertEqual(userMessages.first?.content, goal,
                           "The durable user turn must be the exact original goal")

            // MARK: - ACTUAL ProviderStreamRequest proof
            let captured = box.snapshot
            XCTAssertFalse(captured.requests.isEmpty,
                           "The canonical run must reach the provider through the override")
            // The canonical main dispatch is the recorded request whose user
            // turn carries the goal. Hypothetical auxiliary adapter calls never
            // carry the goal; exactly one goal dispatch proves the run
            // completed its single provider turn.
            let goalIndices = captured.requests.indices.filter { index in
                captured.requests[index].messages.contains { $0.role == "user" && $0.content == goal }
            }
            XCTAssertEqual(goalIndices.count, 1,
                           "Exactly one canonical goal dispatch must reach the provider")
            let goalIndex = try XCTUnwrap(goalIndices.first)
            XCTAssertEqual(captured.ownerRunIDs[goalIndex], run.id,
                           "The goal dispatch must be bound to THIS conversation's run")
            XCTAssertTrue(captured.sawNilCredentials[goalIndex],
                          "No credential may exist on the fake-provider request")
            for recorded in captured.requests {
                XCTAssertEqual(recorded.provider.id, provider.id,
                               "Every recorded dispatch must belong to the isolated fake provider")
                XCTAssertEqual(recorded.model.id, model.id)
            }
            let request = captured.requests[goalIndex]
            XCTAssertFalse(request.ephemeralTransport)
            // Legacy text channel carries the exact goal.
            XCTAssertTrue(request.messages.contains { $0.role == "user" && $0.content == goal },
                          "The provider request must carry the original goal text unmodified")
            // Multimodal channel: the user turn carries EXACTLY the user's own
            // attachment image and NO auto-captured Office page image.
            let userTurn = try XCTUnwrap(request.effectiveMessages.first { message in
                message.role == "user" && message.content.contains { if case .text(goal) = $0 { true } else { false } }
            })
            var imageParts: [(mimeType: String, base64: String)] = []
            for part in userTurn.content {
                if case .imageData(let mimeType, let base64) = part {
                    imageParts.append((mimeType, base64))
                }
            }
            XCTAssertEqual(imageParts.count, 1,
                           "The send must deliver exactly the user-staged image and no Office snapshot")
            XCTAssertEqual(imageParts[0].mimeType, "image/png")
            let imageBytes = try XCTUnwrap(Data(base64Encoded: imageParts[0].base64))
            XCTAssertGreaterThan(imageBytes.count, 512)
            XCTAssertEqual(imageBytes, userPNG,
                           "The user's own attachment must reach the provider byte-identical")
            let providerImage = try XCTUnwrap(UIImage(data: imageBytes),
                                              "The intercepted provider payload must decode as a real image")
            let providerAttachment = XCTAttachment(image: providerImage)
            providerAttachment.name = "sender-proof-provider-user-attachment"
            providerAttachment.lifetime = .keepAlways; add(providerAttachment)
            XCTAssertEqual(redPixels(providerImage), 0,
                           "The user image is ink-free: the live red stroke must NOT have traveled with the send")

            // MARK: - The saved package still cannot produce this image
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), originalHash,
                           "No send may save the working copy")
            XCTAssertEqual(try vectorCount(in: source), 0,
                           "The saved workbook package must contain zero ink vectors")

            // MARK: - Deliberate region read (officeRegion) refuses honestly here
            // The assistant's real region tool runs its staging save
            // transaction first. This sender-proof mount owns no autosave
            // owner, so the transaction refuses and NOTHING is rendered —
            // the truthful unsaved-current state, never a stale snapshot.
            let regionArguments = try JSONDecoder().decode(
                NotesReadTool.Arguments.self,
                from: Data(#"{"documentID":"\#(document.id.uuidString)","section":"officeRegion","sheetIndex":0,"cellRange":"A1:B2"}"#.utf8))
            let toolContext = ToolContext(runID: UUID(), toolCallID: "sender-region-1",
                                          scope: .local, workspaceRootURL: root,
                                          cancellation: CancellationToken(),
                                          conversationID: conversationID)
            var regionFailure: Error?
            do {
                _ = try await NotesReadTool().execute(regionArguments, context: toolContext)
            } catch { regionFailure = error }
            let refusal = try XCTUnwrap(regionFailure, "An owner-less live mount must refuse the region read honestly")
            let refusalText = (refusal as? LocalizedError)?.errorDescription ?? refusal.localizedDescription
            XCTAssertTrue(refusalText.contains("could not prove a saved, quiescent state"),
                          "The refusal must name the unproven saved state: \(refusalText)")
            // The refusal must not have saved anything either.
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), originalHash,
                           "A refused region read must leave the working copy untouched")
            XCTAssertEqual(try vectorCount(in: source), 0)

            await session.release()
            await NotesRepository.shared.setStoreOverride(nil)
        } catch {
            resolveStagedAdditions()
            await session.release()
            await NotesRepository.shared.setStoreOverride(nil)
            throw error
        }
        _ = ComposerDraftStore.shared.flushAndWait()
    }

    // MARK: - Helpers (mirror the existing tested gate path; presentation
    // proof here is strictly secondary to the sender assertions above)

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(150))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate(), "Actual document did not become ready")
        if !predicate() { throw CocoaError(.coderInvalidValue) }
    }

    /// A tiny opaque white PNG used as the user's own staged attachment: any
    /// red ink reaching the provider through it would be measurable.
    static func plainWhitePNG() throws -> Data {
        let size = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.pngData(), "The fixture attachment must encode as PNG")
    }

    private func snapshot(_ web: WKWebView, label: String) async throws -> UIImage {        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: configuration)
        let attachment = XCTAttachment(image: image)
        attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
        return image
    }

    private func redPixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: flags) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return 0 }
        return stride(from: 0, to: bytes.count, by: 4).reduce(into: 0) { count, offset in
            let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
            if r > 140 && r > g * 3 / 2 && r > b * 3 / 2 { count += 1 }
        }
    }

    private func vectorCount(in url: URL) throws -> Int {
        let archive = try Archive(url: url, accessMode: .read)
        let counter = SenderProofVectorCounter()
        for entry in archive where entry.path == "word/document.xml"
            || entry.path.hasPrefix("xl/drawings/drawing")
            || entry.path.hasPrefix("ppt/slides/slide") {
            guard entry.path.hasSuffix(".xml") else { continue }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.shouldProcessNamespaces = true; parser.delegate = counter
            guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        }
        return counter.count
    }

    /// Verbatim gate-path stimulus from OfficeLiveInkAppQualificationTests:
    /// real PointerEvent contacts on the engine canvas (pen pointerType,
    /// one down + 12 rAF-paced moves); no handler replacement, no zoom call,
    /// no edit-state reset.
    private static let beginAndMove = #"""
    const canvas = window.app && window.app.sectionContainer && window.app.sectionContainer.canvas;
    if (!canvas || !window.__floeOfficePenState().drawing) throw new Error('Actual Office pen surface unavailable');
    const layout = app.activeDocument && app.activeDocument.activeLayout;
    const size = app.activeDocument && app.activeDocument.fileSize;
    const section = app.sectionContainer.getDocumentAnchorSection();
    if (!layout || !size || !section) throw new Error('Actual document geometry unavailable');
    const rect = canvas.getBoundingClientRect();
    const scaleX = rect.width / canvas.width, scaleY = rect.height / canvas.height;
    const origin = size.clone(); origin.pX = 0; origin.pY = 0;
    const end = size.clone();
    const dx1 = layout.documentToViewX(origin), dy1 = layout.documentToViewY(origin);
    const dx2 = layout.documentToViewX(end), dy2 = layout.documentToViewY(end);
    const x1 = rect.left + Math.max(0, section.myTopLeft[0], Math.min(dx1, dx2)) * scaleX;
    const y1 = rect.top + Math.max(0, section.myTopLeft[1], Math.min(dy1, dy2)) * scaleY;
    const x2 = rect.left + Math.min(canvas.width, section.myTopLeft[0] + section.size[0], Math.max(dx1, dx2)) * scaleX;
    const y2 = rect.top + Math.min(canvas.height, section.myTopLeft[1] + section.size[1], Math.max(dy1, dy2)) * scaleY;
    if (![x1,y1,x2,y2].every(Number.isFinite) || x2-x1 < 120 || y2-y1 < 120)
        throw new Error('No visible document drawing area');
    const offset = typeof contactIndex === 'number' ? contactIndex * .15 : 0;
    const x = x1 + (x2-x1)*(.35+offset), y = y1 + (y2-y1)*.6;
    const length = Math.min(96,(x2-x1)*.25), amplitude = Math.min(24,(y2-y1)*.08);
    if (contactIndex === 0) {
        window.__floeLiveInkRawBounds = [Infinity,Infinity,-Infinity,-Infinity];
        window.__floeLiveInkBase = {width:canvas.width,height:canvas.height,
            rgba:canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data};
    }
    const include = (px,py) => {
        const b=window.__floeLiveInkRawBounds;
        b[0]=Math.min(b[0],px); b[1]=Math.min(b[1],py);
        b[2]=Math.max(b[2],px); b[3]=Math.max(b[3],py);
    };
    const send = (type, px, py, buttons) => {
        if (buttons) include(px,py);
        return canvas.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, pointerType: 'pen', pointerId: 933,
        isPrimary: true, clientX: px, clientY: py, button: 0, buttons, pressure: buttons ? .5 : 0
    })); };
    send('pointerdown', x, y, 1);
    for (let i = 1; i <= 12; ++i) {
        send('pointermove', x + i * length / 12, y + Math.sin(i / 3) * amplitude, 1);
        await new Promise(resolve => requestAnimationFrame(resolve));
    }
    window.__floeLiveInkQualificationEnd = () => send('pointerup', x + length, y + Math.sin(4) * amplitude, 0);
    return true;
    """#

    private static let liftPen = #"""
    window.__floeLiveInkQualificationEnd();
    delete window.__floeLiveInkQualificationEnd;
    true;
    """#

    /// Verbatim committed-paint observation from the existing gate path:
    /// canvas-pixel change strictly inside the raw pen bounds, excluding
    /// pre-existing content.
    private static let committedInkPosition = #"""
    (() => {
        const c=app.sectionContainer.canvas, r=c.getBoundingClientRect();
        const rgba=c.getContext('2d').getImageData(0,0,c.width,c.height).data;
        const raw=window.__floeLiveInkRawBounds, base=window.__floeLiveInkBase;
        if (!raw || !base || base.width!==c.width || base.height!==c.height)
            throw new Error('Actual ink canvas geometry changed during the contact');
        const red=(a,i)=>a[i]>140 && a[i]>a[i+1]*1.5 && a[i]>a[i+2]*1.5;
        let minX=c.width,minY=c.height,maxX=-1,maxY=-1,pixels=0;
        // Exclude pre-existing red cells/text and unrelated UI. The generous
        // 48 CSS px observation margin retains the measured 17px Writer
        // displacement; it cannot make that displacement pass the 4px check.
        const left=Math.max(0,Math.floor((raw[0]-48-r.left)*c.width/r.width));
        const right=Math.min(c.width,Math.ceil((raw[2]+48-r.left)*c.width/r.width));
        const top=Math.max(0,Math.floor((raw[1]-48-r.top)*c.height/r.height));
        const bottom=Math.min(c.height,Math.ceil((raw[3]+48-r.top)*c.height/r.height));
        for (let y=top;y<bottom;y++) for (let x=left;x<right;x++) {
            const i=(y*c.width+x)*4;
            if (red(rgba,i) && !red(base.rgba,i)) {
                minX=Math.min(minX,x);maxX=Math.max(maxX,x);
                minY=Math.min(minY,y);maxY=Math.max(maxY,y);pixels++;
            }
        }
        if (!raw || !pixels) return {pixels};
        const painted=[r.left+minX*r.width/c.width,r.top+minY*r.height/c.height,
            r.left+(maxX+1)*r.width/c.width,r.top+(maxY+1)*r.height/c.height];
        return {pixels,raw,painted,
            driftX:Math.abs((raw[0]+raw[2]-painted[0]-painted[2])/2),
            driftY:Math.abs((raw[1]+raw[3]-painted[1]-painted[3])/2)};
    })()
    """#
}

private final class SenderProofVectorCounter: NSObject, XMLParserDelegate {
    var count = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "custGeom", namespaceURI == "http://schemas.openxmlformats.org/drawingml/2006/main"
            || namespaceURI == "http://purl.oclc.org/ooxml/drawingml/main" { count += 1 }
    }
}

/// Lock-boxed recording of the ACTUAL dispatch boundary: every stream call
/// from the canonical run is captured together with the run identity the
/// center bound the adapter to, and with whether the request carried no
/// credentials at all.
private final class SenderProofCaptureBox: @unchecked Sendable {
    struct Captured {
        let requests: [ProviderStreamRequest]
        let ownerRunIDs: [UUID?]
        let sawNilCredentials: [Bool]
        let streamCount: Int
    }
    private let lock = NSLock()
    private var requests: [ProviderStreamRequest] = []
    private var ownerRunIDs: [UUID?] = []
    private var sawNilCredentials: [Bool] = []

    func record(ownerRunID: UUID?, request: ProviderStreamRequest, credentials: ProviderCredentials) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        ownerRunIDs.append(ownerRunID)
        sawNilCredentials.append(credentials.apiKey == nil)
    }

    var snapshot: Captured {
        lock.lock(); defer { lock.unlock() }
        return Captured(requests: requests, ownerRunIDs: ownerRunIDs,
                 sawNilCredentials: sawNilCredentials, streamCount: requests.count)
    }
}

/// Installed ONLY through the existing ConversationCenter.providerAdapterTestOverride
/// seam; implements the public ProviderAdapter contract. It never performs
/// network I/O: it records the request the canonical runtime actually built
/// and streams one short scripted answer so the run completes.
private struct RecordingSenderProofAdapter: ProviderAdapter {
    let box: SenderProofCaptureBox
    let ownerRunID: UUID?

    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        box.record(ownerRunID: ownerRunID, request: request, credentials: credentials)
        return AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.textDelta(.init(text: "Sender proof acknowledged.")))
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}
#endif
