import Foundation
import Crypto
import FloeCore
#if canImport(Security)
import Security
#endif

public struct AdvancedRemoteLink: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let hostID: UUID
    public let deviceID: UUID
    public let endpoint: String
    public let port: Int
    public let serverCAFingerprint: String
    public let createdAt: Date
}

public struct AdvancedRemoteEnrollment: Sendable {
    public let link: AdvancedRemoteLink
    public let pkcs12: Data
    public let password: String
    public let serverCA: Data
}

/// Device-local advanced-link registry. Host metadata is serializable, but the
/// client identity is deliberately stored with a ThisDeviceOnly keychain class
/// and is never eligible for iCloud Keychain synchronization.
public actor AdvancedRemoteLinkStore {
    public static let shared = AdvancedRemoteLinkStore()
    private var links: [UUID: AdvancedRemoteLink] = [:]
    private let fileURL: URL

    public init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("FloeAgent/AdvancedRemoteLinks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("links.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([UUID: AdvancedRemoteLink].self, from: data) {
            links = decoded
        }
    }

    public func link(hostID: UUID) -> AdvancedRemoteLink? { links[hostID] }
    public func allLinks() -> [AdvancedRemoteLink] { links.values.sorted { $0.createdAt < $1.createdAt } }

    public func save(_ enrollment: AdvancedRemoteEnrollment) throws {
        try Self.saveIdentity(enrollment)
        links[enrollment.link.hostID] = enrollment.link
        try persist()
    }

    public func remove(hostID: UUID) throws {
        if let link = links.removeValue(forKey: hostID) { Self.deleteIdentity(deviceID: link.deviceID) }
        try persist()
    }

    private func persist() throws {
        try JSONEncoder().encode(links).write(to: fileURL, options: .atomic)
    }

    fileprivate func credentials(for link: AdvancedRemoteLink) throws -> (Data, String, Data) {
        try Self.loadIdentity(deviceID: link.deviceID)
    }

    #if canImport(Security)
    private static func account(_ id: UUID) -> String { "advanced-link.\(id.uuidString)" }
    private static func saveIdentity(_ enrollment: AdvancedRemoteEnrollment) throws {
        let payload = try JSONEncoder().encode(IdentityPayload(pkcs12: enrollment.pkcs12, password: enrollment.password, serverCA: enrollment.serverCA))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.floeagent.remote-link", kSecAttrAccount as String: account(enrollment.link.deviceID)]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = payload
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw FloeError.internalError("Unable to store device identity (\(status))") }
    }
    private static func loadIdentity(deviceID: UUID) throws -> (Data, String, Data) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.floeagent.remote-link", kSecAttrAccount as String: account(deviceID), kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let payload = try? JSONDecoder().decode(IdentityPayload.self, from: data) else {
            throw FloeError.validationFailed("This device's advanced-link certificate is unavailable; pair it again over SSH")
        }
        return (payload.pkcs12, payload.password, payload.serverCA)
    }
    private static func deleteIdentity(deviceID: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.floeagent.remote-link", kSecAttrAccount as String: account(deviceID)] as CFDictionary)
    }
    #else
    private static func saveIdentity(_: AdvancedRemoteEnrollment) throws { throw FloeError.validationFailed("Device identities require Apple Security") }
    private static func loadIdentity(deviceID: UUID) throws -> (Data, String, Data) { throw FloeError.validationFailed("Device identities require Apple Security") }
    private static func deleteIdentity(deviceID: UUID) {}
    #endif

    private struct IdentityPayload: Codable { let pkcs12: Data; let password: String; let serverCA: Data }
}

#if canImport(Security)
private final class MutualTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pkcs12: Data, password: String, serverCA: Data
    init(pkcs12: Data, password: String, serverCA: Data) { self.pkcs12 = pkcs12; self.password = password; self.serverCA = serverCA }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate {
            var result: CFArray?
            let options = [kSecImportExportPassphrase as String: password]
            guard SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &result) == errSecSuccess,
                  let first = (result as? [[String: Any]])?.first,
                  let identityValue = first[kSecImportItemIdentity as String],
                  CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            // SecPKCS12Import documents this dictionary value as SecIdentity.
            // The Core Foundation type-id check above makes the bridge safe and
            // avoids an unchecked bit cast that can trap under optimizer changes.
            let identity = identityValue as! SecIdentity
            let chain = first[kSecImportItemCertChain as String] as? [SecCertificate]
            return completionHandler(.useCredential, URLCredential(identity: identity, certificates: chain, persistence: .forSession))
        }
        if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            let certificates = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            let matchesPinnedCA = certificates.contains { certificate in
                return SecCertificateCopyData(certificate) as Data == serverCA
            }
            return completionHandler(matchesPinnedCA ? .useCredential : .cancelAuthenticationChallenge, matchesPinnedCA ? URLCredential(trust: trust) : nil)
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
#endif

public actor AdvancedRemoteClient {
    private let store: AdvancedRemoteLinkStore
    public init(store: AdvancedRemoteLinkStore = .shared) { self.store = store }

    public func request(hostID: UUID, method: String, endpoint: String, queryPath: String? = nil, body: [String: String]? = nil) async throws -> Data {
        guard let link = await store.link(hostID: hostID) else { throw FloeError.notFound("Advanced remote link") }
        let credentials = try await store.credentials(for: link)
        guard var components = URLComponents(string: "https://\(link.endpoint):\(link.port)/\(endpoint)") else { throw FloeError.validationFailed("Invalid advanced-link endpoint") }
        if let queryPath { components.queryItems = [URLQueryItem(name: "path", value: queryPath)] }
        guard let url = components.url else { throw FloeError.validationFailed("Invalid advanced-link URL") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        #if canImport(Security)
        let delegate = MutualTLSDelegate(pkcs12: credentials.0, password: credentials.1, serverCA: credentials.2)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let (data, response) = try await session.data(for: request); session.finishTasksAndInvalidate()
        #else
        let (data, response) = try await URLSession.shared.data(for: request)
        #endif
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw FloeError.validationFailed("Advanced remote request was rejected") }
        return data
    }
}
