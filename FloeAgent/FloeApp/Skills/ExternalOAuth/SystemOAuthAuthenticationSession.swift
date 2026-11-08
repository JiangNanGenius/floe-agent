#if canImport(AuthenticationServices) && canImport(Combine)
import AuthenticationServices
import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shared by the App and the focused qualification host. A cancelled browser
/// callback after successful issuance cannot undo the completed connection.
@MainActor
final class SystemOAuthAuthenticationSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    enum State: Equatable { case idle, preparing, waitingForCodeCopy, signingIn, refreshing, connected, failed(ExternalOAuthFailure) }
    @Published private(set) var state = State.idle
    @Published private(set) var userCode: String?
    private var generation: UUID?
    private var session: ASWebAuthenticationSession?
    private var listener: ExternalOAuthLoopbackListener?
    private var transport: (any ExternalOAuthPluginTransport)?
    private var task: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var anchor: ASPresentationAnchor?
    private var deviceContinuation: CheckedContinuation<Void, any Error>?
    private var deviceTimeout: Task<Void, Never>?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    @discardableResult
    func signIn(context: ExternalOAuthCredentialContext, transport: any ExternalOAuthPluginTransport, anchor: ASPresentationAnchor) -> Bool {
        guard context == transport.credentialContext else { return false }
        let client = context.client
        cancel()
        let cleanup = cleanupTask
        let id = UUID()
        generation = id
        self.transport = transport; self.anchor = anchor
        state = .preparing; userCode = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                await cleanup?.value
                try self.checkOwner(id)
                let redirect: URL?
                if client.grant == .authorizationCode {
                    let listener = ExternalOAuthLoopbackListener()
                    self.listener = listener
                    redirect = try await listener.start()
                } else { redirect = nil }
                try self.checkOwner(id)
                let offer = try await transport.begin(client: client, redirectURI: redirect)
                try self.checkOwner(id)
                guard offer.expiresIn.map({ $0.isFinite && (1...3_600).contains($0) }) ?? true else {
                    throw ExternalOAuthFailure.invalidAuthorization
                }
                let deadline = offer.expiresIn.map { ContinuousClock.now.advanced(by: .seconds($0)) }
                if client.grant == .authorizationCode {
                    guard offer.kind == .authorization, let redirect else { throw ExternalOAuthFailure.invalidAuthorization }
                    self.listener?.policy = try ExternalOAuthAuthorizationPolicy(authorizationURL: offer.url, client: client, redirect: redirect)
                    self.listener?.onCallback = { [weak self] result in
                        guard let self, self.generation == id else { return }
                        switch result {
                        case .success(let url):
                            Task { @MainActor [weak self] in
                                do { try await transport.resume(callback: url) }
                                catch { self?.finish(id, result: .failed(.pluginUnavailable)) }
                            }
                        case .failure(let error): self.finish(id, result: .failed(error))
                        }
                    }
                } else { try ExternalOAuthAuthorizationPolicy.validateDeviceOffer(offer, provider: client.provider) }
                self.userCode = offer.userCode
                if offer.kind == .device && offer.completeURL == nil {
                    self.state = .waitingForCodeCopy
                    try await withCheckedThrowingContinuation { continuation in
                        self.deviceContinuation = continuation
                        if let expiresIn = offer.expiresIn {
                            self.deviceTimeout = Task { [weak self] in
                                try? await Task.sleep(for: .seconds(expiresIn))
                                if !Task.isCancelled { self?.finish(id, result: .failed(.timedOut)) }
                            }
                        }
                    }
                    try self.checkOwner(id)
                }
                let session = ASWebAuthenticationSession(url: offer.completeURL ?? offer.url, callbackURLScheme: "floe-external-auth") { @Sendable [weak self] _, error in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.finish(id, result: .failed(error == nil ? .invalidCallback : .cancelled))
                    }
                }
                session.presentationContextProvider = self
                // Use the user's existing system-browser login where available.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                guard session.start() else { throw ExternalOAuthFailure.pluginUnavailable }
                self.state = .signingIn
                while deadline.map({ ContinuousClock.now < $0 }) ?? true {
                    try self.checkOwner(id)
                    switch try await transport.status() {
                    case .issued:
                        try self.checkOwner(id)
                        self.finish(id, result: .connected); return
                    case .failed: throw ExternalOAuthFailure.denied
                    case .pending: break
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                throw ExternalOAuthFailure.timedOut
            } catch let error as ExternalOAuthFailure { self.finish(id, result: .failed(error)) }
            catch is CancellationError { self.finish(id, result: .failed(.cancelled)) }
            catch { self.finish(id, result: .failed(.pluginUnavailable)) }
        }
        return true
    }

    /// The explicit native button copies only the public verification code,
    /// locally, before the system page covers the configuration screen. A
    /// provider-supplied complete URI needs no copy/paste step.
    func copyDeviceCodeAndContinue() {
        guard state == .waitingForCodeCopy, let code = userCode,
              let continuation = deviceContinuation else { return }
        #if canImport(UIKit)
        UIPasteboard.general.setItems([["public.utf8-plain-text": code]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
        #elseif canImport(AppKit)
        NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        deviceContinuation = nil
        deviceTimeout?.cancel(); deviceTimeout = nil
        continuation.resume()
    }

    /// Refresh uses a transport opened for the same installed client/profile
    /// and its existing native-vault binding. It never opens a browser.
    @discardableResult
    func refresh(context: ExternalOAuthCredentialContext, transport: any ExternalOAuthPluginTransport) -> Bool {
        guard context == transport.credentialContext else { return false }
        guard ![.preparing, .waitingForCodeCopy, .signingIn].contains(state) else { return false }
        let client = context.client
        cancel()
        let cleanup = cleanupTask
        let id = UUID(); generation = id
        self.transport = transport; state = .refreshing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                await cleanup?.value
                try self.checkOwner(id)
                try await transport.refresh(client: client)
                try self.checkOwner(id)
                self.finish(id, result: .connected)
            } catch { self.finish(id, result: .failed(.pluginUnavailable)) }
        }
        return true
    }

    func cancel() {
        let old = transport
        generation = nil
        let continuation = deviceContinuation; deviceContinuation = nil
        deviceTimeout?.cancel(); deviceTimeout = nil
        continuation?.resume(throwing: ExternalOAuthFailure.cancelled)
        task?.cancel(); task = nil
        session?.cancel(); session = nil
        listener?.stop(); listener = nil
        transport = nil; anchor = nil; userCode = nil
        if let old {
            let prior = cleanupTask
            cleanupTask = Task { await prior?.value; await old.cancel() }
        }
        if [.preparing, .waitingForCodeCopy, .signingIn, .refreshing].contains(state) { state = .idle }
    }

    /// Navigation, reconnect and uninstall await native callbacks and worker
    /// cleanup before releasing their existing operation/environment owner.
    func cancelAndJoin() async {
        let previous = task
        cancel()
        await previous?.value
        await cleanupTask?.value
    }

    func waitUntilFinished() async -> State {
        await task?.value
        await cleanupTask?.value
        return state
    }

    private func checkOwner(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id else { throw ExternalOAuthFailure.cancelled }
    }

    private func finish(_ id: UUID, result: State) {
        guard generation == id else { return }
        cancel()
        state = result
    }
}
#endif
