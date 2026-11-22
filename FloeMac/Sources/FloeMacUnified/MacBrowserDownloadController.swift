// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import FloeMacToolbox
import FloeTools
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Owns one human-initiated browser transfer from the destination sheet through
/// the shared iPad download service. Browser navigation and task changes do not
/// retarget the transfer or grant access to any other destination.
@MainActor
final class MacBrowserDownloadController: ObservableObject {
    private struct Transfer {
        let id = UUID()
        let owner: UUID?
        let cancellation = CancellationToken()
        let release: HostAgentWorkspace.ReleaseWork
        var panel: NSSavePanel?
    }

    @Published private var activeSnapshot: MacBrowserDownloadSnapshot?
    @Published private var saved: MacBrowserSavedDownload?
    @Published private var errorText: String?
    private var savedOwner: UUID?
    private var errorOwner: UUID?
    private let service = BrowserDownloadService()
    private let admitWork: HostAgentWorkspace.AdmitWork
    private var observation: AnyCancellable?
    private var transfer: Transfer?
    #if FLOE_MAC_HOST_SMOKE
    var smokeDestination: URL?
    #endif

    init(admitWork: @escaping HostAgentWorkspace.AdmitWork) {
        self.admitWork = admitWork
        observation = service.$active
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncProgress() }
    }

    func snapshot(for owner: UUID?) -> MacBrowserDownloadSnapshot? {
        transfer?.owner == owner ? activeSnapshot : nil
    }

    func saved(for owner: UUID?) -> MacBrowserSavedDownload? {
        savedOwner == owner ? saved : nil
    }

    func error(for owner: UUID?) -> String? {
        errorOwner == owner ? errorText : nil
    }

    func startDownload(page: WKWebView, owner: UUID?, in window: NSWindow?) {
        guard transfer == nil, let window, window.attachedSheet == nil,
              let url = page.url, MacBrowserAddress.allows(url), let release = try? admitWork() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.contentTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let suggested = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = suggested.isEmpty || suggested == "/" ? "download" : String(suggested.prefix(180))
        #if FLOE_MAC_HOST_SMOKE
        if let smokeDestination {
            panel.directoryURL = smokeDestination.deletingLastPathComponent()
            panel.nameFieldStringValue = smokeDestination.lastPathComponent
        }
        #endif
        let transfer = Transfer(owner: owner, release: release, panel: panel)
        self.transfer = transfer
        discardResult(for: owner)
        let id = transfer.id
        panel.beginSheetModal(for: window) { [weak self, weak panel, weak page] response in
            guard let self, let transfer = self.transfer, transfer.id == id else { return }
            self.transfer?.panel = nil
            guard response == .OK, !transfer.cancellation.isCancelled, let destination = panel?.url, let page else {
                self.finish(id)
                return
            }
            self.begin(transfer, url: url, page: page, destination: destination)
        }
    }

    func cancel(_ id: UUID) {
        guard activeSnapshot?.id == id else { return }
        service.cancel(id)
    }

    func discard(owner: UUID?) {
        if let transfer, transfer.owner == owner { cancelAll() }
        discardResult(for: owner)
    }

    private func discardResult(for owner: UUID?) {
        if savedOwner == owner {
            saved = nil
            savedOwner = nil
        }
        if errorOwner == owner {
            errorText = nil
            errorOwner = nil
        }
    }

    func cancelAll() {
        guard let transfer else { return }
        transfer.cancellation.cancel()
        if let panel = transfer.panel {
            panel.cancel(nil)
            finish(transfer.id)
        } else {
            service.cancelAll()
        }
    }

    private func begin(_ transfer: Transfer, url: URL, page: WKWebView, destination: URL) {
        let overwrite = FileManager.default.fileExists(atPath: destination.path)
        let id = transfer.id
        let owner = transfer.owner
        let cancellation = transfer.cancellation
        Task { [weak self] in
            guard let self, self.transfer?.id == id else { return }
            defer { self.finish(id) }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            do {
                let receipt = try await service.start(
                    webView: page, request: URLRequest(url: url), destinationURL: destination,
                    relativePath: destination.lastPathComponent, suggestedFilename: destination.lastPathComponent,
                    maxBytes: Self.maxBytes, overwrite: overwrite, cancellation: cancellation
                )
                guard !cancellation.isCancelled else { return }
                savedOwner = owner
                saved = MacBrowserSavedDownload(displayName: receipt.suggestedFilename, fileURL: receipt.destinationURL)
            } catch {
                guard !cancellation.isCancelled else { return }
                if case BrowserDownloadError.cancelled = error { return }
                errorOwner = owner
                errorText = Self.visibleTaskError(error)
            }
        }
    }

    private func finish(_ id: UUID) {
        guard let transfer, transfer.id == id else { return }
        self.transfer = nil
        activeSnapshot = nil
        transfer.release()
    }

    private func syncProgress() {
        guard transfer != nil, let current = service.active.first else {
            activeSnapshot = nil
            return
        }
        activeSnapshot = MacBrowserDownloadSnapshot(id: current.id, displayName: current.displayName,
                                                     progress: current.progress, isFinishing: current.state == .finishing)
    }

    private static let maxBytes = 64 * 1_024 * 1_024
    private static let contentTypes: [UTType] = [.pdf, .png, .jpeg, .gif, .webP, .heic]

    /// Shared by the user Save-panel transfer and the task-owned model
    /// download lane (`MacTaskBrowserSession`), so both surfaces phrase the
    /// same service failures identically.
    static func visibleTaskError(_ error: Error) -> String {
        switch error as? BrowserDownloadError {
        case .unsupportedType(_)?, .signatureMismatch(_, _)?:
            String(localized: "mac.browser.download.unsupported")
        case .tooLarge(_)?:
            String(localized: "mac.browser.download.tooLarge")
        default:
            String(localized: "mac.browser.download.failed")
        }
    }
}
