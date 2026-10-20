// SPDX-License-Identifier: MPL-2.0
#if canImport(Darwin)
import XCTest
import Foundation
@testable import FloeTransport

/// Pure origin/header contract for the production redirect policy. The
/// loopback suite proves the router wiring; this suite pins the closed
/// comparison and allowlist rules, including cases a plain HTTP fixture
/// cannot produce (HTTPS -> HTTP).
final class TransportRedirectPolicyOriginTests: XCTestCase {

    func testOriginComparisonNormalizesCaseTrailingDotAndDefaultPort() {
        let same = [
            ("https://Example.COM./a", "https://example.com/b"),
            ("https://example.com:443/a", "https://example.com/b"),
            ("http://example.com:80/a", "http://example.com/b"),
            ("http://127.0.0.1:8080/a", "http://127.0.0.1:8080/b"),
        ]
        for (previous, target) in same {
            let request = URLRequest(url: URL(string: target)!)
            XCTAssertEqual(TransportRedirectPolicy.sanitize(
                request, previousURL: URL(string: previous)), request,
                "\(previous) -> \(target) must stay same-origin")
        }
        let changed = [
            ("https://example.com/a", "https://example.com:444/b"),
            ("https://example.com/a", "https://www.example.com/b"),
            ("http://example.com/a", "https://example.com/b"),
        ]
        for (previous, target) in changed {
            var request = URLRequest(url: URL(string: target)!)
            request.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
            request.setValue("opaque", forHTTPHeaderField: "X-Provider-Custom")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let sanitized = TransportRedirectPolicy.sanitize(
                request, previousURL: URL(string: previous))
            XCTAssertNil(sanitized?.value(forHTTPHeaderField: "Authorization"),
                         "\(previous) -> \(target)")
            XCTAssertNil(sanitized?.value(forHTTPHeaderField: "X-Provider-Custom"),
                         "\(previous) -> \(target)")
            XCTAssertEqual(sanitized?.value(forHTTPHeaderField: "Accept"),
                           "application/json", "\(previous) -> \(target)")
        }
    }

    func testHTTPSDowngradeIsRefusedButConfiguredHTTPOriginsRemainAllowed() {
        var downgrade = URLRequest(url: URL(string: "http://example.com/target")!)
        downgrade.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        XCTAssertNil(TransportRedirectPolicy.sanitize(
            downgrade, previousURL: URL(string: "https://example.com/start")))
        // An explicitly HTTP origin is not a downgrade; cross-origin strip
        // still applies, same-origin remains untouched.
        XCTAssertNotNil(TransportRedirectPolicy.sanitize(
            downgrade, previousURL: URL(string: "http://other.example/start")))
        XCTAssertEqual(TransportRedirectPolicy.sanitize(
            downgrade, previousURL: URL(string: "http://example.com/start")),
            downgrade)
    }

    func testUnknownPreviousOriginSanitizesConservatively() {
        var request = URLRequest(url: URL(string: "http://example.com/target")!)
        request.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        request.setValue("opaque", forHTTPHeaderField: "X-Provider-Custom")
        let sanitized = TransportRedirectPolicy.sanitize(request, previousURL: nil)
        XCTAssertNil(sanitized?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sanitized?.value(forHTTPHeaderField: "X-Provider-Custom"))
    }

    func testNonHTTPRedirectTargetIsRefused() {
        var request = URLRequest(url: URL(string: "ftp://example.com/target")!)
        request.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        XCTAssertNil(TransportRedirectPolicy.sanitize(
            request, previousURL: URL(string: "https://example.com/start")))
        XCTAssertNil(TransportRedirectPolicy.sanitize(nil, previousURL: nil))
    }

    func testCrossOriginAllowlistDropsEveryCredentialAndOpaqueHeader() {
        var request = URLRequest(url: URL(string: "https://target.example/b")!)
        let dropped = [
            "Authorization": "Bearer x",
            "Proxy-Authorization": "Basic y",
            "x-api-key": "key",
            "api-key": "key2",
            "x-goog-api-key": "key3",
            "Cookie": "session=1",
            "X-Opaque-Custom": "opaque",
            "X-Request-Id": "id",
            "Referer": "https://origin.example/a",
            "User-Agent": "synthetic",
        ]
        for (name, value) in dropped {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let retained = [
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Accept-Language": "en",
            "Cache-Control": "no-cache",
            "Content-Type": "application/json",
            "Pragma": "no-cache",
            "Range": "bytes=0-1",
            "If-None-Match": "\"v1\"",
        ]
        for (name, value) in retained {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let sanitized = try! XCTUnwrap(TransportRedirectPolicy.sanitize(
            request, previousURL: URL(string: "https://origin.example/a")))
        for name in dropped.keys {
            XCTAssertNil(sanitized.value(forHTTPHeaderField: name), name)
        }
        for (name, value) in retained {
            XCTAssertEqual(sanitized.value(forHTTPHeaderField: name), value, name)
        }
    }
}
#endif
