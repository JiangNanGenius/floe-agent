import Foundation

/// One brand, two independent credential and billing channels.
public struct MoonshotSearchOptions: Sendable, Equatable {
    public enum Channel: String, Sendable, CaseIterable { case payg, kimiCode }
    public let channel: Channel
    public let includeContent: Bool

    public init(options: [String: String]) throws {
        guard let channel = Channel(rawValue: options["interface"] ?? "payg") else {
            throw WebRetrievalError.invalidResponse("Choose Pay as you go or Kimi Code.")
        }
        let raw = options["includeContent"] ?? "false"
        guard raw == "true" || raw == "false" else {
            throw WebRetrievalError.invalidResponse("includeContent must be true or false.")
        }
        self.channel = channel
        self.includeContent = raw == "true"
    }

    public var endpoint: URL {
        URL(string: channel == .kimiCode
            ? "https://api.kimi.com/coding/v1/search"
            : "https://api.moonshot.cn/v1/tools/search")!
    }

    public func credentialAccount(providerID: UUID) -> String {
        WebSearchInstanceStore.instanceCredentialAccount(for: providerID) + ".moonshot." + channel.rawValue
    }

    public func validate(_ configuration: WebSearchProviderConfiguration) throws {
        guard configuration.kind == .moonshot,
              configuration.endpoint == nil || configuration.endpoint == endpoint,
              configuration.credentialAccount == credentialAccount(providerID: configuration.id) else {
            throw WebRetrievalError.invalidResponse("Moonshot credentials must belong to the selected channel and official endpoint.")
        }
    }

    public static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }

    public static let deviceID: String = {
        let key = "floe.moonshot.deviceID"
        if let value = UserDefaults.standard.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString
        // Request preparation may run off-main. Defaults changes also notify
        // SwiftUI settings observers, so persist on main without blocking a
        // network worker; the static value remains stable in this process.
        if Thread.isMainThread { UserDefaults.standard.set(value, forKey: key) }
        else { DispatchQueue.main.async { UserDefaults.standard.set(value, forKey: key) } }
        return value
    }()

    public static func addClientIdentity(to request: inout URLRequest) {
        request.setValue("FloeAgent/" + clientVersion, forHTTPHeaderField: "User-Agent")
        request.setValue("floe-agent-ios", forHTTPHeaderField: "X-Msh-Platform")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Msh-Version")
        request.setValue(deviceID, forHTTPHeaderField: "X-Msh-Device-Id")
        request.setValue(ProcessInfo.processInfo.operatingSystemVersionString, forHTTPHeaderField: "X-Msh-Os-Version")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Msh-Tool-Call-Id")
    }
}
