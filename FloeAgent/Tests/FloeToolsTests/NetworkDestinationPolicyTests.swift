import XCTest
@testable import FloeTools

/// Regression coverage for the SSRF destination boundary and the narrow
/// fake-IP tunnel repair for fixed built-in search provider hosts
/// (Build240 feedback: api.bochaai.com / wsa.tencentcloudapi.com rejected
/// under a fake-IP VPN, 54 ms failures).
final class NetworkDestinationPolicyTests: XCTestCase {

    // MARK: - IPv4 classification

    func testPublicIPv4Literals() {
        for literal in ["1.1.1.1", "8.8.8.8", "192.1.1.1", "172.15.0.1", "172.32.0.1",
                        "100.63.0.1", "100.128.0.1", "198.17.0.1", "198.20.0.1", "203.1.1.1"] {
            XCTAssertEqual(NetworkDestinationPolicy.classify(literal), .publicAddress, literal)
        }
    }

    func testTransientTunnelIPv4Range() {
        // RFC 2544 benchmark block = the standard fake-IP pool.
        XCTAssertEqual(NetworkDestinationPolicy.classify("198.18.0.1"), .transientTunnel)
        XCTAssertEqual(NetworkDestinationPolicy.classify("198.18.128.9"), .transientTunnel)
        XCTAssertEqual(NetworkDestinationPolicy.classify("198.19.255.255"), .transientTunnel)
    }

    func testNonPublicIPv4Ranges() {
        for literal in ["0.0.0.0", "10.0.0.1", "127.0.0.1", "100.64.0.1", "100.127.0.1",
                        "169.254.1.1", "169.254.169.254", "172.16.0.1", "172.31.255.255",
                        "192.0.0.1", "192.0.255.255", "192.168.1.1",
                        "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1"] {
            XCTAssertEqual(NetworkDestinationPolicy.classify(literal), .nonPublic, literal)
        }
    }

    func testInvalidIPv4LiteralsAreFailClosed() {
        XCTAssertEqual(NetworkDestinationPolicy.classify("not-an-ip"), .nonPublic)
        XCTAssertEqual(NetworkDestinationPolicy.classify("999.1.1.1"), .nonPublic)
        XCTAssertEqual(NetworkDestinationPolicy.classify(""), .nonPublic)
    }

    // MARK: - IPv6 classification

    func testPublicIPv6Literals() {
        XCTAssertEqual(NetworkDestinationPolicy.classify("2606:4700:4700::1111"), .publicAddress)
        XCTAssertEqual(NetworkDestinationPolicy.classify("2001:4860:4860::8888"), .publicAddress)
    }

    func testNonPublicIPv6Ranges() {
        for literal in ["::", "::1", "fc00::1", "fd12::1", "fe80::1",
                        "ff02::1", "2001:db8::1"] {
            XCTAssertEqual(NetworkDestinationPolicy.classify(literal), .nonPublic, literal)
        }
    }

    func testIPv4MappedIPv6InheritsIPv4Class() {
        XCTAssertEqual(NetworkDestinationPolicy.classify("::ffff:1.1.1.1"), .publicAddress)
        XCTAssertEqual(NetworkDestinationPolicy.classify("::ffff:198.18.0.1"), .transientTunnel)
        XCTAssertEqual(NetworkDestinationPolicy.classify("::ffff:10.0.0.1"), .nonPublic)
        XCTAssertEqual(NetworkDestinationPolicy.classify("::ffff:169.254.169.254"), .nonPublic)
    }

    // MARK: - validate with injected DNS conditions

    private func validate(
        host: String,
        allowTransient: Bool,
        addresses: [String]
    ) throws {
        try NetworkDestinationPolicy.validate(
            host: host,
            allowTransientTunnel: allowTransient,
            resolve: { _ in addresses }
        )
    }

    func testPublicProviderResolvesToPublicIPs() throws {
        XCTAssertNoThrow(try validate(host: "api.bochaai.com", allowTransient: true,
                                      addresses: ["104.18.0.1"]))
        XCTAssertNoThrow(try validate(host: "api.bochaai.com", allowTransient: false,
                                      addresses: ["104.18.0.1"]))
    }

    func testFakeIPAcceptedOnlyWhenTransientAllowed() {
        // Pinned provider under fake-IP VPN: relaxation granted.
        XCTAssertNoThrow(try validate(host: "api.bochaai.com", allowTransient: true,
                                      addresses: ["198.18.0.1"]))
        // Default strict path rejects the same answer.
        XCTAssertThrowsError(try validate(host: "api.bochaai.com", allowTransient: false,
                                          addresses: ["198.18.0.1"])) { error in
            XCTAssertEqual(error as? NetworkDestinationError, .privateTarget("api.bochaai.com"))
        }
        // An unpinned host never gets the relaxation even if its name resolves
        // into the fake pool.
        XCTAssertThrowsError(try validate(host: "random.example.org", allowTransient: false,
                                          addresses: ["198.18.0.1"])) { error in
            XCTAssertEqual(error as? NetworkDestinationError, .privateTarget("random.example.org"))
        }
    }

    func testTransientRelaxationDoesNotAdmitPrivateRanges() {
        // The repair covers only 198.18/15. Loopback, RFC1918, link-local and
        // cloud-metadata addresses must still be rejected, pinned host or not.
        for address in ["10.0.0.1", "127.0.0.1", "169.254.169.254",
                        "192.168.1.1", "172.16.0.1", "100.64.0.1", "0.0.0.0"] {
            XCTAssertThrowsError(try validate(host: "api.bochaai.com", allowTransient: true,
                                              addresses: [address])) { error in
                XCTAssertEqual(error as? NetworkDestinationError,
                               .privateTarget("api.bochaai.com"), address)
            }
        }
    }

    func testAllResolvedAddressesAreChecked() {
        // One public + one fake address: strict rejects; relaxed accepts.
        XCTAssertNoThrow(try validate(host: "api.bochaai.com", allowTransient: true,
                                      addresses: ["1.1.1.1", "198.18.0.1"]))
        XCTAssertThrowsError(try validate(host: "api.bochaai.com", allowTransient: false,
                                          addresses: ["1.1.1.1", "198.18.0.1"]))
        // A private address anywhere in the answer set fails even when relaxed.
        XCTAssertThrowsError(try validate(host: "api.bochaai.com", allowTransient: true,
                                          addresses: ["1.1.1.1", "198.18.0.1", "10.0.0.1"]))
    }

    func testResolutionFailureIsFailClosed() {
        XCTAssertThrowsError(try NetworkDestinationPolicy.validate(
            host: "api.bochaai.com", allowTransientTunnel: true,
            resolve: { _ in throw NetworkDestinationError.resolutionFailed("api.bochaai.com") }
        )) { error in
            XCTAssertEqual(error as? NetworkDestinationError,
                           .resolutionFailed("api.bochaai.com"))
        }
        XCTAssertThrowsError(try NetworkDestinationPolicy.validate(
            host: "api.bochaai.com", allowTransientTunnel: true,
            resolve: { _ in [] }
        )) { error in
            XCTAssertEqual(error as? NetworkDestinationError,
                           .resolutionFailed("api.bochaai.com"))
        }
    }

    // MARK: - Live resolver (systemResolve)

    func testSystemResolveRendersNumericLoopbackAsNonPublic() throws {
        // Exercises the live getaddrinfo/getnameinfo path without DNS: numeric
        // input resolves locally on both Darwin and Glibc, and every rendered
        // literal must still classify as non-public (fail closed).
        let addresses = try NetworkDestinationPolicy.systemResolve("127.0.0.1")
        XCTAssertFalse(addresses.isEmpty)
        for address in addresses {
            XCTAssertEqual(NetworkDestinationPolicy.classify(address), .nonPublic, address)
        }
    }

    // MARK: - Redirect revalidation (redirects are strictly revalidated)

    func testPrivateRedirectDestinationsBlocked() {
        // A redirect is a new destination and is revalidated strictly:
        // fake-IP answers are not honored and private targets abort redirect.
        for target in ["10.0.0.1", "127.0.0.1", "169.254.169.254",
                       "192.168.0.1", "198.18.0.1", "198.19.0.1"] {
            XCTAssertThrowsError(try validate(host: target, allowTransient: false,
                                              addresses: [target]), target)
        }
    }
}
