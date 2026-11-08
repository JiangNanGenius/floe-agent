#if canImport(UIKit)
import Foundation
import Observation
import UIKit
import FloeExecution

@MainActor @Observable
final class NativeExternalOAuthConnectionCenter {
    let request: SkillConfigurationConnectionRequest
    let session = SystemOAuthAuthenticationSession()
    var draft: NativeExternalOAuthDraft
    private(set) var environments: [NativeExternalOAuthAppIntegration.EnvironmentChoice] = []
    private(set) var saved: NativeExternalOAuthAppIntegration.Saved?
    private(set) var isLoading = false
    private(set) var isBusy = false
    private(set) var isRefreshing = false
    private(set) var isCancelling = false
    private(set) var stopUnconfirmed = false
    private(set) var errorMessage: String?
    private(set) var hasPresentationAnchor = false
    @ObservationIgnored private let integration: NativeExternalOAuthAppIntegration
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var retainedOwnerID: UUID?
    @ObservationIgnored private var lastOwnerID: UUID?
    @ObservationIgnored private var cancellation: Task<Bool, Never>?
    @ObservationIgnored private weak var anchor: UIWindow?
    private var restoredDraft = false

    init(request: SkillConfigurationConnectionRequest, integration: NativeExternalOAuthAppIntegration) {
        self.request = request; self.integration = integration
        draft = .init(provider: request.skillID == "floe-google-auth" ? .google : .microsoft)
    }

    var canConnect: Bool {
        !isBusy && !isLoading && !isCancelling && !stopUnconfirmed && hasPresentationAnchor
            && environments.contains(where: { $0.id == draft.environmentID }) && (try? draft.profile()) != nil
    }
    var canRefresh: Bool {
        guard !isBusy, !isCancelling, !stopUnconfirmed, let saved else { return false }
        return (try? draft.profile()) == saved.details.client
            && draft.environmentID == saved.details.environmentID && draft.clientSecret.isEmpty
    }

    func setAnchor(_ value: UIWindow?) { anchor = value; hasPresentationAnchor = value != nil }

    func reload(restoreDraft: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        environments = await integration.environments()
        do {
            saved = try await integration.saved(request)
            if restoreDraft, !restoredDraft, let saved {
                draft.restore(client: saved.details.client, environmentID: saved.details.environmentID)
                restoredDraft = true
            }
        } catch is CancellationError { return }
        catch { saved = nil; errorMessage = Self.message(error) }
    }

    func connect() {
        guard canConnect, let anchor else { return }
        let value = draft
        draft.clientSecret = ""
        run { [self] owner in try await integration.connect(request, draft: value, session: session, anchor: anchor, ownerID: owner) }
    }

    func refresh() {
        guard canRefresh, let reference = saved?.details.reference else { return }
        run(refreshing: true) { [self] owner in try await integration.quietRefresh(reference: reference, validateConsumer: {}, ownerID: owner) }
    }

    func disconnect() {
        guard !isBusy, !isCancelling else { return }
        draft.clientSecret = ""
        run { [self] _ in try await integration.disconnect(request) }
    }

    private func run(refreshing: Bool = false, _ body: @escaping @MainActor (UUID) async throws -> Void) {
        guard work == nil, !isCancelling else { return }
        let id = UUID(); generation = id; lastOwnerID = id; isBusy = true; isRefreshing = refreshing; errorMessage = nil
        work = Task { [self] in
            defer {
                if generation == id { work = nil; generation = nil; isBusy = false; isRefreshing = false }
            }
            do { try await body(id); stopUnconfirmed = false; retainedOwnerID = nil; await reload(restoreDraft: false) }
            catch is CancellationError { }
            catch ExternalOAuthFailure.cancelled { }
            catch NativeExternalOAuthAppFailure.cancelled { }
            catch NativeExternalOAuthAppFailure.stopUnconfirmed { stopUnconfirmed = true; retainedOwnerID = id; errorMessage = Self.message(NativeExternalOAuthAppFailure.stopUnconfirmed) }
            catch { errorMessage = Self.message(error) }
        }
    }

    @discardableResult
    func cancelAndJoin() async -> Bool {
        requestCancel()
        return await cancellation?.value ?? true
    }

    /// Capture the page's owner synchronously at navigation/cancel time;
    /// a delayed old teardown must never cancel a later same-profile flow.
    func requestCancel() {
        draft.clientSecret = ""
        guard !isCancelling else { return }
        guard let ownerID = generation ?? retainedOwnerID else { return }
        let previous = work
        previous?.cancel()
        isCancelling = true
        cancellation = Task { [self] in
            defer { if lastOwnerID == ownerID { isCancelling = false } }
            let stopped = await integration.stop(request, ownerID: ownerID)
            await previous?.value
            guard lastOwnerID == ownerID else { return stopped }
            stopUnconfirmed = !stopped
            if stopped { retainedOwnerID = nil }
            else { retainedOwnerID = ownerID; errorMessage = Self.message(NativeExternalOAuthAppFailure.stopUnconfirmed) }
            return stopped
        }
    }

    private static func message(_ error: any Error) -> String {
        switch error {
        case ExternalOAuthFailure.invalidAuthorization:
            NativeExternalOAuthCopy.text("Check the client ID and requested permissions.", "请检查客户端 ID 和申请的权限。")
        case NativeExternalOAuthAppFailure.stopUnconfirmed:
            NativeExternalOAuthCopy.text("The previous connection is still stopping. Try Cancel again.", "上一次连接仍在停止，请再次尝试取消。")
        case NativeExternalOAuthLifecycle.Failure.busy:
            NativeExternalOAuthCopy.text("Another account is connecting. Finish or cancel it first.", "另一个账号正在连接，请先完成或取消。")
        case NativeExternalOAuthAppFailure.unavailable:
            NativeExternalOAuthCopy.text("The connection service is unavailable. Check the selected environment.", "连接服务暂不可用，请检查所选环境。")
        case ExternalOAuthFailure.denied:
            NativeExternalOAuthCopy.text("Authorization was not granted. Try connecting again.", "尚未获得授权，请重新连接。")
        default:
            NativeExternalOAuthCopy.text("Could not finish. Check the connection and try again.", "未能完成，请检查连接后重试。")
        }
    }
}
#endif
