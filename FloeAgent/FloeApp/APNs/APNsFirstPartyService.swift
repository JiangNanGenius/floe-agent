// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation

/// Signed native deployment configuration only. No new entitlement/profile
/// presence gate: actual DeviceCheck support/API results stay authoritative.
/// No model-authored URL, shared key or remote trust flag.
struct APNsServiceConfiguration {
    let baseURL: URL
    let testFlightURL: URL?
    let appStoreURL: URL?
    static func bundled(_ bundle: Bundle = .main) -> Self? {
        guard let raw = bundle.object(forInfoDictionaryKey: "FloePushServiceBaseURL") as? String,
              let baseURL = URL(string: raw), baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { return nil }
        return .init(baseURL: baseURL,
            testFlightURL: (bundle.object(forInfoDictionaryKey: "FloePushTestFlightURL") as? String).flatMap(URL.init(string:)),
            appStoreURL: (bundle.object(forInfoDictionaryKey: "FloePushAppStoreURL") as? String).flatMap(URL.init(string:)))
    }
}

@MainActor struct APNsFirstPartyService {
    let transport: HTTPAPNsTransport?
    let enrollment: APNsEnrollmentCoordinator?
    let testFlightURL: URL?
    let appStoreURL: URL?
    let platform: APNsPlatform
    init(configuration: APNsServiceConfiguration? = .bundled()) {
        var platform = APNsPlatform.live
        guard let configuration else {
            transport = nil; enrollment = nil; testFlightURL = nil; appStoreURL = nil
            self.platform = platform
            return
        }
        do {
            let http = try HTTPAPNsTransport(baseURL: configuration.baseURL)
            let enrollment = try APNsEnrollmentCoordinator(http: http, installation: APNsNativeInstallationProofs(), isForeground: platform.isForeground)
            self.enrollment = enrollment
            transport = http.withEnrollmentProof { [weak enrollment] request, secret in
                guard let enrollment else { throw APNsServiceError.unconfigured }
                return try await enrollment.proof(for: request, secret: secret)
            }
            platform.installChannel = { [weak enrollment] in await enrollment?.refreshInstallationEvidence() ?? .unknown }
            self.platform = platform
            testFlightURL = configuration.testFlightURL
            appStoreURL = configuration.appStoreURL
        } catch {
            transport = nil; enrollment = nil; testFlightURL = nil; appStoreURL = nil
            self.platform = platform
        }
    }
}
#endif
