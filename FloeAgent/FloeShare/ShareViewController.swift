// SPDX-License-Identifier: MPL-2.0
//
// FloeShare — Share extension entry point (S5 P1).
//
// The extension's ONLY job is to stage a bounded, validated envelope in the
// shared App Group and tell the user to open Floe. It never opens the main app
// (`NSExtensionContext.open` is unsupported for share extensions), never
// sends a task and never claims success for a failed write.
//
// Provider handling lives in ShareItemProviderLoader.swift (same target):
// * a provider that advertises BOTH a file representation and public.url is
//   intaken from the file representation — coordinated original bytes are
//   copied inside the provider callback; a file: URL string that cannot yield
//   retained bytes is rejected instead of committing its transient path;
//   genuine http/https web page URLs keep the text-URL behavior.
// * text / URL are loaded into memory only up to the text envelope limit.
// * image / file providers are copied through `loadFileRepresentation` inside
//   the provider URL lifetime, with a bounded streaming copy and file
//   coordination. Original bytes and provider type identifiers are preserved.
// * the UIImage-only fallback is limited to a 2048 px PNG (never a silent
//   lossy JPEG); anything larger/corrupt is rejected with a visible error.
// * at most five items are accepted; the whole share is rejected when more
//   are present rather than silently dropping the rest.

import UIKit
import SwiftUI
import FloeCore

final class ShareViewController: UIViewController {
    private var confirmationState = ShareConfirmationState(phase: .saving)
    private var hostingController: UIHostingController<ShareConfirmationView>?
    private var stagingSession: ShareInbox.StagingSession?
    private var processingTask: Task<Void, Never>?
    private var temporaryDirectory: URL?
    private var didFinish = false
    private var hasRequestedCompletion = false
    private var failureMessage: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        FloeL10n.bootstrap()
        view.backgroundColor = .systemBackground
        installHostingControllerIfNeeded()
        updateConfirmation(.init(phase: .saving))
        startProcessing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !didFinish else { return }
        // The user dismissed the share sheet before tapping Done. Remove only
        // this extension's uncommitted staging bytes and temporary copies.
        processingTask?.cancel()
        stagingSession?.cancel()
        stagingSession = nil
        cleanupTemporaryDirectory()
    }

    // MARK: - Processing

    private func startProcessing() {
        processingTask = Task { [weak self] in
            await self?.processSharedContent()
        }
    }

    private func processSharedContent() async {
        do {
            guard let extensionContext,
                  let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
                throw ShareInboxError.emptyEnvelope
            }
            let inbox = try ShareInbox.applicationGroup()
            let session = try inbox.beginStaging(producer: "FloeShare")
            stagingSession = session

            let tempRoot = try makeTemporaryDirectory()
            let inputs = try await ShareItemProviderLoader.loadInputs(
                from: inputItems,
                temporaryRoot: tempRoot
            )
            try Task.checkCancellation()
            guard !inputs.isEmpty else {
                throw ShareInboxError.emptyEnvelope
            }
            for input in inputs {
                try Task.checkCancellation()
                switch input {
                case .text(let text):
                    try session.appendText(text, kind: .text)
                case .url(let absoluteString):
                    try session.appendText(absoluteString, kind: .url)
                case .file(let url, let displayName, let typeIdentifier, let kind):
                    try session.adoptTemporaryFile(
                        at: url,
                        displayName: displayName,
                        typeIdentifier: typeIdentifier,
                        kind: kind
                    )
                case .data(let data, let displayName, let typeIdentifier, let kind):
                    try session.appendData(
                        data,
                        displayName: displayName,
                        typeIdentifier: typeIdentifier,
                        kind: kind
                    )
                }
            }
            let envelope = try session.commit()
            stagingSession = nil
            cleanupTemporaryDirectory()
            didFinish = true
            failureMessage = nil
            updateConfirmation(.init(phase: .saved(itemCount: envelope.items.count)))
        } catch is CancellationError {
            stagingSession?.cancel()
            stagingSession = nil
            cleanupTemporaryDirectory()
        } catch {
            stagingSession?.cancel()
            stagingSession = nil
            cleanupTemporaryDirectory()
            let message: String
            if let inboxError = error as? ShareInboxError {
                message = inboxError.localizedDescription
            } else {
                message = FloeL10n.l("share.extension.failed_detail")
            }
            failureMessage = message
            updateConfirmation(.init(phase: .failed(message: message)))
        }
    }

    private func retry() {
        guard !hasRequestedCompletion else { return }
        processingTask?.cancel()
        stagingSession?.cancel()
        stagingSession = nil
        cleanupTemporaryDirectory()
        failureMessage = nil
        updateConfirmation(.init(phase: .saving))
        startProcessing()
    }

    // MARK: - Completion

    private func finishWithSuccess() {
        guard !hasRequestedCompletion else { return }
        hasRequestedCompletion = true
        didFinish = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func finishWithFailure() {
        guard !hasRequestedCompletion else { return }
        hasRequestedCompletion = true
        didFinish = true
        let message = failureMessage ?? FloeL10n.l("share.extension.failed_detail")
        let error = NSError(
            domain: "org.floeagent.share",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        // Not a success completion: the host learns the share was not saved.
        extensionContext?.cancelRequest(withError: error)
    }

    // MARK: - Hosting

    private func installHostingControllerIfNeeded() {
        guard hostingController == nil else { return }
        let controller = UIHostingController(rootView: makeConfirmationView())
        controller.view.backgroundColor = .clear
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        hostingController = controller
        preferredContentSize = CGSize(width: 420, height: 260)
    }

    private func updateConfirmation(_ state: ShareConfirmationState) {
        confirmationState = state
        installHostingControllerIfNeeded()
        hostingController?.rootView = makeConfirmationView()
    }

    private func makeConfirmationView() -> ShareConfirmationView {
        ShareConfirmationView(
            state: confirmationState,
            onDone: { [weak self] in self?.finishWithSuccess() },
            onClose: { [weak self] in self?.finishWithFailure() },
            onRetry: { [weak self] in self?.retry() }
        )
    }

    // MARK: - Temporary files

    private func makeTemporaryDirectory() throws -> URL {
        if let temporaryDirectory {
            return temporaryDirectory
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectory = url
        return url
    }

    private func cleanupTemporaryDirectory() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
        self.temporaryDirectory = nil
    }
}
