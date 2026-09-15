// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
#if canImport(Security)
import Security

/// Evaluates a full server chain without fetching arbitrary issuer URLs on
/// the RDP worker. A configured pin is an exact leaf-DER SHA-256 identity.
public enum RDPCertificateTrust {
    public struct Evaluation: Sendable, Hashable {
        public let accepted: Bool
        public let fingerprintSHA256: String
        public let subject: String
        public let reason: String
    }

    public static func evaluate(pem: Data, hostname: String, pinnedSHA256: String?) -> Evaluation {
        let rejected = Evaluation(accepted: false, fingerprintSHA256: "", subject: "", reason: "Invalid certificate chain")
        guard !hostname.isEmpty, pem.count <= 256 * 1024,
              let text = String(data: pem, encoding: .utf8) else { return rejected }
        let blocks = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
        guard !blocks.isEmpty, blocks.count <= 16 else { return rejected }
        var certificates: [SecCertificate] = []
        var leafDER: Data?
        for block in blocks {
            guard let end = block.range(of: "-----END CERTIFICATE-----") else { return rejected }
            let body = block[..<end.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
            guard let der = Data(base64Encoded: body), !der.isEmpty, der.count <= 64 * 1024,
                  let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return rejected }
            if leafDER == nil { leafDER = der }
            certificates.append(certificate)
        }
        guard let leafDER, let leaf = certificates.first else { return rejected }
        let fingerprint = FloeDigest.sha256Hex(leafDER)
        let subject = String((SecCertificateCopySubjectSummary(leaf) as String? ?? hostname).prefix(256))
        if let pin = pinnedSHA256, !pin.isEmpty {
            let normalized = pin.lowercased().replacingOccurrences(of: ":", with: "")
            let valid = normalized.count == 64 && normalized.allSatisfy { $0.isHexDigit && $0.isASCII }
            let matches = valid && normalized == fingerprint
            return Evaluation(accepted: matches, fingerprintSHA256: fingerprint, subject: subject,
                              reason: matches ? "Matches the approved certificate" : "The server certificate differs from the approved fingerprint")
        }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
              let trust else { return rejected }
        SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        let accepted = SecTrustEvaluateWithError(trust, &error)
        return Evaluation(accepted: accepted, fingerprintSHA256: fingerprint, subject: subject,
                          reason: accepted ? "Trusted by the system" : "Certificate confirmation is required")
    }
}
#endif
