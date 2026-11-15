// SPDX-License-Identifier: MPL-2.0
import Foundation
import WebKit
import FloeGameCore

@MainActor
final class GameArtifactSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "floe-game"
    private let package: GameWebArtifactPackage
    /// Exact stable origin host for this package's trusted storage identity.
    private let originHost: String
    private struct Read { let id: UUID; let task: Task<Data, any Error> }
    private var reads: [ObjectIdentifier: Read] = [:]
    private var active = false

    init(package: GameWebArtifactPackage, originHost: String) {
        self.package = package
        self.originHost = originHost
    }
    func activate() { active = true }
    func cancelReads() -> [Task<Data, any Error>] {
        active = false
        let pending = Array(reads.values); reads.removeAll()
        pending.forEach { $0.task.cancel() }
        return pending.map(\.task)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            guard active, let url = urlSchemeTask.request.url,
                  url.scheme == Self.scheme, url.host == originHost,
                  url.user == nil, url.password == nil, url.port == nil, url.path.hasPrefix("/") else {
                throw GameProjectError.invalidArtifact
            }
            let path = try GameRelativePath(String(url.path.dropFirst()))
            let key = ObjectIdentifier(urlSchemeTask), id = UUID(), package = package
            let task = Task.detached { try package.readResource(path) }
            reads[key] = .init(id: id, task: task)
            Task { [weak self] in
                guard let self else { task.cancel(); return }
                do {
                    var bytes = try await task.value
                    guard active, reads[key]?.id == id else { return }
                    let mime = GameWebArtifactPackage.mimeType(for: path)
                    if mime == "text/html" {
                        let csp = GameWebRuntimePolicy(engine: package.prepared.engine).contentSecurityPolicy
                        let prefix = "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
                        bytes = Data(prefix.utf8) + bytes
                    }
                    var headers = ["Content-Type": mime, "Content-Length": String(bytes.count),
                        "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*", "Accept-Ranges": "bytes",
                        "Permissions-Policy": "geolocation=(), camera=(), microphone=(), accelerometer=(), gyroscope=(), magnetometer=()"]
                    var status = 200
                    // Match the encoded build file without decompressing on the
                    // main actor. Uncompressed/Unity decompression-fallback files
                    // have no Content-Encoding header.
                    if path.value.hasSuffix(".br") { headers["Content-Encoding"] = "br" }
                    if path.value.hasSuffix(".gz") { headers["Content-Encoding"] = "gzip" }
                    if let range = urlSchemeTask.request.value(forHTTPHeaderField: "Range") {
                        let selected = try Self.byteRange(range, count: bytes.count)
                        let lower = selected.lowerBound, upper = selected.upperBound - 1
                        headers["Content-Range"] = "bytes \(lower)-\(upper)/\(bytes.count)"
                        bytes = bytes.subdata(in: lower..<(upper + 1)); headers["Content-Length"] = String(bytes.count); status = 206
                    }
                    guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { throw GameProjectError.invalidArtifact }
                    urlSchemeTask.didReceive(response)
                    // Bounded delivery chunks; no executable or host-file endpoint is exposed.
                    for start in stride(from: 0, to: bytes.count, by: 65_536) {
                        urlSchemeTask.didReceive(bytes.subdata(in: start..<min(start + 65_536, bytes.count)))
                    }
                    urlSchemeTask.didFinish(); reads.removeValue(forKey: key)
                } catch {
                    guard active, reads[key]?.id == id else { return }
                    reads.removeValue(forKey: key)
                    urlSchemeTask.didFailWithError(error)
                }
            }
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        reads.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.task.cancel()
    }

    static func byteRange(_ header: String, count: Int) throws -> Range<Int> {
        guard count > 0, header.hasPrefix("bytes="), !header.contains(",") else { throw GameProjectError.invalidArtifact }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw GameProjectError.invalidArtifact }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { throw GameProjectError.invalidArtifact }
            return max(0, count - suffix)..<count
        }
        guard let lower = Int(parts[0]), lower >= 0, lower < count else { throw GameProjectError.invalidArtifact }
        let upper = parts[1].isEmpty ? count - 1 : (Int(parts[1]) ?? -1)
        guard upper >= lower else { throw GameProjectError.invalidArtifact }
        return lower..<(min(upper, count - 1) + 1)
    }
}
