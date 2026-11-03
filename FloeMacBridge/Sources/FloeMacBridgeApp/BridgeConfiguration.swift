#if os(macOS)
import Foundation

/// Opens an official download in the browser. Never executes a setup script,
/// installs software or treats an installed Kimi CU as a live connection.
enum BridgeConfiguration {
    static let kimiCUManifestURL = URL(string: "https://cdn.kimi.com/kimi-computer-use/latest/version.json")!
    static let kimiCUDocumentationURL = URL(string: "https://www.kimi.com/code/docs/en/customization/plugins.html#kimi-computer-use")!

    static func kimiCUDownloadURL(from data: Data, intel: Bool) throws -> URL {
        struct Manifest: Decodable {
            struct App: Decodable { let url: String }
            let version: String
            let app: App
            let app_x86_64: App
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let version = manifest.version
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              let url = URL(string: intel ? manifest.app_x86_64.url : manifest.app.url),
              url.scheme == "https", url.host == "cdn.kimi.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil,
              url.path == "/kimi-computer-use/\(version)/\(intel ? "KimiCU-x86_64.app.zip" : "KimiCU.app.zip")"
        else { throw URLError(.unsupportedURL) }
        return url
    }
    static func latestKimiCUDownloadURL() async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: ManifestRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: kimiCUManifestURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == kimiCUManifestURL else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        #if arch(x86_64)
        return try kimiCUDownloadURL(from: data, intel: true)
        #else
        return try kimiCUDownloadURL(from: data, intel: false)
        #endif
    }
    private final class ManifestRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url == kimiCUManifestURL ? request : nil)
        }
    }
}
#endif
