// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeModels
import FloeProviders
import Foundation

/// Diagnostics are constructed from bounded status fields. A model's answer,
/// provider error body, endpoint, account and credentials never enter it.
struct MacProviderDiagnostic: Sendable {
    enum Result: String, Sendable {
        case response, authentication, quotaOrRateLimit, modelUnavailable, network, rejected, invalidResponse, cancelled
    }

    let result: Result
    var httpStatus: Int? = nil
    var testedAt = Date()

    var message: String {
        switch result {
        case .response: MacPermissionsText.t("模型调用成功。", "The model returned a response.")
        case .authentication: MacPermissionsText.t("供应商拒绝访问。请检查密钥和模型权限。", "Access was refused. Check the API key and model permissions.")
        case .quotaOrRateLimit: MacPermissionsText.t("请求受限。请检查余额、订阅和调用频率。", "The request was limited. Check quota, subscription, and request rate.")
        case .modelUnavailable: MacPermissionsText.t("模型或接口不存在。请检查模型 ID 和接口地址。", "The model or endpoint was not found. Check the model ID and endpoint.")
        case .network: MacPermissionsText.t("无法连接模型。请检查网络和接口地址。", "Could not reach the model. Check the network and endpoint.")
        case .rejected: MacPermissionsText.t("供应商拒绝了请求。请检查协议和模型配置。", "The provider rejected the request. Check the protocol and model configuration.")
        case .invalidResponse: MacPermissionsText.t("模型未返回可用的文本。", "The model did not return usable text.")
        case .cancelled: MacPermissionsText.t("已取消测试。", "The test was cancelled.")
        }
    }

    var exportText: String {
        ["Floe model call diagnostic", "Format 1", "Time \(testedAt.ISO8601Format())", "Result \(result.rawValue)",
         httpStatus.map { "HTTP \($0)" }].compactMap { $0 }.joined(separator: "\n")
    }

    static func from(_ error: AgentEvent.NormalizedError) -> Self {
        let code = error.httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        let result: Result
        switch (code, error.kind) {
        case (402, _), (429, _): result = .quotaOrRateLimit
        case (404, _), (410, _): result = .modelUnavailable
        case (401, _), (403, _), (_, .auth): result = .authentication
        case (_, .rateLimited): result = .quotaOrRateLimit
        case (_, .network), (_, .server): result = .network
        case (_, .cancelled): result = .cancelled
        default: result = .rejected
        }
        return .init(result: result, httpStatus: code)
    }

    static func verify(provider: ProviderProfile, model: ModelProfile, credentials: ProviderCredentials,
                       adapter: any ProviderAdapter) async -> Self {
        await withTaskGroup(of: Self.self) { group in
            group.addTask {
                let request = ProviderStreamRequest(provider: provider, model: model,
                    messages: [("user", "Reply with OK.")], ephemeralTransport: true)
                var receivedText = false
                do {
                    for try await event in adapter.stream(request: request, credentials: credentials) {
                        switch event {
                        case .textDelta(let delta):
                            if !delta.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { receivedText = true }
                        case .completed(let completion):
                            return .init(result: receivedText && completion.stopReason != .cancelled ? .response : .invalidResponse)
                        case .error(let error):
                            if ProviderConnectionProbe.isInactiveVolcenginePlan(provider: provider, status: error.httpStatus, body: error.providerMessage) {
                                return .init(result: .quotaOrRateLimit, httpStatus: error.httpStatus)
                            }
                            return from(error)
                        default: break
                        }
                    }
                    return .init(result: .invalidResponse)
                } catch is CancellationError { return .init(result: .cancelled) }
                catch let error as URLError where error.code == .cancelled { return .init(result: .cancelled) }
                catch is URLError { return .init(result: .network) }
                catch { return .init(result: .rejected) }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(18)) }
                catch { return .init(result: .cancelled) }
                return .init(result: .network)
            }
            let result = await group.next() ?? .init(result: .cancelled)
            group.cancelAll()
            return result
        }
    }
}
