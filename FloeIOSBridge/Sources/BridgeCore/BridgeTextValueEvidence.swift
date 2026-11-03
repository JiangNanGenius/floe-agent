import Foundation

/// Pure assessment of one append-only text operation. It never returns the
/// before/after/request strings; only an observation label, booleans and byte
/// counts. A verified append requires a trustworthy before value and the exact
/// expected after value.
public struct BridgeTextValueAssessment: Equatable, Sendable {
    public var observation: String
    public var appendVerified: Bool
    public var valueMatchesRequest: Bool
    public var valueUTF8Bytes: Int?
    public var expectedUTF8Bytes: Int?
    public var beforeTrusted: Bool

    public init(observation: String,
                appendVerified: Bool,
                valueMatchesRequest: Bool,
                valueUTF8Bytes: Int?,
                expectedUTF8Bytes: Int?,
                beforeTrusted: Bool) {
        self.observation = observation
        self.appendVerified = appendVerified
        self.valueMatchesRequest = valueMatchesRequest
        self.valueUTF8Bytes = valueUTF8Bytes
        self.expectedUTF8Bytes = expectedUTF8Bytes
        self.beforeTrusted = beforeTrusted
    }
}

/// The append-only truthfulness rule:
///
/// - A verified append requires `after == trustworthyBefore + request`.
/// - An empty trustworthy before plus `after == request` is a verified
///   empty-base append.
/// - An unchanged value is never an append, even when the before value already
///   equals the request (`before == request`, `after == request`). This is the
///   exact no-op counterexample: it must not pass via exact/suffix matching.
/// - A request-equal or suffix-equal result without the expected append is only
///   weaker evidence, never a verified append.
/// - If the before value is unavailable or untrusted, a request-equal result is
///   weaker evidence only.
public enum BridgeTextValueAssessor {
    public static func assess(beforeValue: String?,
                              beforeTrusted: Bool,
                              request: String,
                              afterValue: String?) -> BridgeTextValueAssessment {
        guard let after = afterValue else {
            return BridgeTextValueAssessment(
                observation: "unavailable",
                appendVerified: false,
                valueMatchesRequest: false,
                valueUTF8Bytes: nil,
                expectedUTF8Bytes: nil,
                beforeTrusted: beforeTrusted
            )
        }
        let afterBytes = after.utf8.count
        let matchesRequest = after == request ||
            (!request.isEmpty && after.hasSuffix(request))
        guard beforeTrusted, let before = beforeValue else {
            return BridgeTextValueAssessment(
                observation: matchesRequest
                    ? "matches-request-before-unavailable"
                    : "before-unavailable",
                appendVerified: false,
                valueMatchesRequest: matchesRequest,
                valueUTF8Bytes: afterBytes,
                expectedUTF8Bytes: nil,
                beforeTrusted: false
            )
        }
        let expected = before + request
        let expectedBytes = expected.utf8.count
        if after == expected {
            return BridgeTextValueAssessment(
                observation: before.isEmpty
                    ? "empty-base-append-verified"
                    : "append-verified",
                appendVerified: true,
                valueMatchesRequest: true,
                valueUTF8Bytes: afterBytes,
                expectedUTF8Bytes: expectedBytes,
                beforeTrusted: true
            )
        }
        if after == before, !before.isEmpty {
            // The field still holds exactly what it held before the call. Even
            // if that happens to equal the request (for example before/after
            // both "Floe" and request "Floe"), no append occurred.
            return BridgeTextValueAssessment(
                observation: "unchanged",
                appendVerified: false,
                valueMatchesRequest: matchesRequest,
                valueUTF8Bytes: afterBytes,
                expectedUTF8Bytes: expectedBytes,
                beforeTrusted: true
            )
        }
        if after == request {
            return BridgeTextValueAssessment(
                observation: "replacement-or-request-match",
                appendVerified: false,
                valueMatchesRequest: true,
                valueUTF8Bytes: afterBytes,
                expectedUTF8Bytes: expectedBytes,
                beforeTrusted: true
            )
        }
        if matchesRequest {
            return BridgeTextValueAssessment(
                observation: "suffix-coincidence",
                appendVerified: false,
                valueMatchesRequest: true,
                valueUTF8Bytes: afterBytes,
                expectedUTF8Bytes: expectedBytes,
                beforeTrusted: true
            )
        }
        return BridgeTextValueAssessment(
            observation: "differs",
            appendVerified: false,
            valueMatchesRequest: false,
            valueUTF8Bytes: afterBytes,
            expectedUTF8Bytes: expectedBytes,
            beforeTrusted: true
        )
    }
}
