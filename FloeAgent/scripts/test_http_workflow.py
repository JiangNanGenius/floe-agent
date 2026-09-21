#!/usr/bin/env python3
"""Exercise the actual Swift HTTP service against a local API, without WebKit.
macOS targeted check; iOS transport/UI qualification remains a separate gate.

The harness is compiled through the real SwiftPM module graph as an ephemeral
executable target that depends on the FloeExecution product, so
HTTPRequestService is built together with its actual FloeCore/FlooTools
dependencies instead of being fed to a bare single-file swiftc invocation.
The shared package scratch path (FloeAgent/.build) lets this reuse the modules
already compiled by the Qualification swift test step in CI.
"""
import http.server
import json
import pathlib
import subprocess
import tempfile
import threading
import sys


PACKAGE_ROOT = pathlib.Path(__file__).resolve().parents[1]


class Endpoint(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/form':
            self.respond(200, '<form action="/api/item" method="post"><input name="title"></form>', 'text/html')
        elif self.path == '/large':
            self.respond(200, 'x' * 8192)
        elif self.path == '/missing':
            self.respond(404, '{"error":"missing"}', 'application/json')
        else:
            self.respond(200, json.dumps({'cookie': self.headers.get('Cookie', ''), 'value': 42}), 'application/json')

    def do_PATCH(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.respond(200, json.dumps({'saved': body['title']}), 'application/json')

    def do_OPTIONS(self):
        self.respond(204, '')

    def respond(self, status, body, content_type='text/plain'):
        data = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Allow', 'GET, PATCH, OPTIONS')
        self.send_header('Link', '</api/item?page=2>; rel="next"')
        self.send_header('Retry-After', '3')
        self.send_header('Set-Cookie', 'test_session=private; Path=/')
        self.end_headers()
        self.wfile.write(data)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
threading.Thread(target=server.serve_forever, daemon=True).start()
harness = r'''
import Foundation
import FloeExecution

@main struct Check {
    static func main() async throws {
        let service = HTTPRequestService(allowsPrivateNetwork: true)
        let base = CommandLine.arguments[1]
        func request(_ path: String, _ method: String = "GET", _ body: String? = nil, cap: Int = 4096) async throws -> HTTPResponse {
            try await service.send(method: method, url: URL(string: base + path)!,
                headers: ["Content-Type": "application/json"], body: body.map { Data($0.utf8) },
                timeout: 5, maxResponseBytes: cap)
        }
        let html = try await request("/form")
        precondition(html.body.contains("action=\"/api/item\""))
        let saved = try await request("/api/item", "PATCH", "{\"title\":\"Floe\"}")
        precondition(saved.statusCode == 200 && saved.body.contains("Floe"))
        precondition(saved.finalURL == base + "/api/item")
        precondition(saved.headers["link"]?.contains("page=2") == true)
        precondition(saved.headers["retry-after"] == "3")
        precondition(saved.headers["set-cookie"] == nil)
        let read = try await request("/api/item")
        let json = try JSONSerialization.jsonObject(with: Data(read.body.utf8)) as! [String: Any]
        precondition(json["cookie"] as? String == "", "website cookies leaked between calls")
        let options = try await request("/api/item", "OPTIONS")
        precondition(options.statusCode == 204 && options.headers["allow"]?.contains("PATCH") == true)
        let missing = try await request("/missing")
        precondition(missing.statusCode == 404 && missing.body.contains("missing"))
        let large = try await request("/large", cap: 128)
        precondition(large.truncated && large.body.utf8.count == 128)
        if CommandLine.arguments.count > 2 {
            let secure = HTTPRequestService()
            let response = try await secure.send(method: "GET", url: URL(string: "https://example.com")!,
                headers: [:], body: nil, timeout: 20, maxResponseBytes: 16384)
            precondition(response.statusCode == 200 && response.body.contains("Example Domain"))
            precondition(response.finalURL?.hasPrefix("https://") == true)
            print("PASS: real public HTTPS with system certificate verification")
        }
        print("PASS: HTML endpoint discovery, PATCH JSON, OPTIONS, response headers, cookie isolation, HTTP failure body, bounded output; no browser")
    }
}
'''
# Ephemeral SwiftPM package whose executable target links the real
# FloeExecution product. A path dependency keeps the module graph identical to
# production: FloeExecution plus its FloeCore/FlooTools (and remaining)
# dependencies are compiled by SwiftPM rather than bypassed with single-file
# swiftc flags.
package_manifest = r'''
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FloeHTTPWorkflowCheck",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: %s)
    ],
    targets: [
        .executableTarget(
            name: "HTTPWorkflowCheck",
            dependencies: [
                .product(name: "FloeExecution", package: "FloeAgent")
            ],
            path: "Sources/HTTPWorkflowCheck",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
''' % json.dumps(str(PACKAGE_ROOT))
try:
    with tempfile.TemporaryDirectory(prefix='floe-http-check-') as root:
        root = pathlib.Path(root)
        source_dir = root / 'Sources' / 'HTTPWorkflowCheck'
        source_dir.mkdir(parents=True)
        (source_dir / 'Check.swift').write_text(harness)
        (root / 'Package.swift').write_text(package_manifest)
        # Build against the package's normal scratch directory so the modules
        # compiled by the earlier Qualification swift test step are reused;
        # it is gitignored and shared by every SwiftPM invocation in CI.
        scratch = PACKAGE_ROOT / '.build'
        swift = ['xcrun', 'swift']
        common = ['--package-path', str(root), '--scratch-path', str(scratch), '--jobs', '4']
        subprocess.run(swift + ['build'] + common + ['--product', 'HTTPWorkflowCheck'], check=True, timeout=2400)
        bin_path = subprocess.run(
            swift + ['build', '--show-bin-path'] + common,
            check=True, capture_output=True, text=True, timeout=120
        ).stdout.strip()
        binary = pathlib.Path(bin_path) / 'HTTPWorkflowCheck'
        subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}']
                       + (['--https'] if '--https' in sys.argv else []), check=True, timeout=45)
finally:
    server.shutdown()
    server.server_close()
