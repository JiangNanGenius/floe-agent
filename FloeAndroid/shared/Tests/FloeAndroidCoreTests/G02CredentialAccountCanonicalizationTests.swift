// SPDX-License-Identifier: MPL-2.0
//
// Cross-language identity proof for the debug product-credential enrollment:
// the Swift product path and the Kotlin debug helper MUST derive the SAME
// provider account and opaque gateway reference. The fixed UUID contains
// A-F hex letters so a lowercase/uppercase defect cannot hide behind an
// all-digit fixture (the Kotlin side asserts the identical constants in
// ProductCredentialEnrollmentIdentityTest).
import XCTest
import Foundation
@testable import FloeAndroidCore

final class G02CredentialAccountCanonicalizationTests: XCTestCase {

    func testProviderAccountUsesCanonicalUppercaseUUID() throws {
        let id = try XCTUnwrap(UUID(uuidString: "7f3c1a52-9d4e-4c11-8a2b-2f6c8e5d1b70"))
        XCTAssertEqual(ConfigSecretIdentity.providerAccount(providerID: id),
                       "provider.7F3C1A52-9D4E-4C11-8A2B-2F6C8E5D1B70")
    }

    func testOpaqueReferenceMatchesKotlinEnrollmentConstant() throws {
        let id = try XCTUnwrap(UUID(uuidString: "7f3c1a52-9d4e-4c11-8a2b-2f6c8e5d1b70"))
        let account = ConfigSecretIdentity.providerAccount(providerID: id)
        XCTAssertEqual(
            SecretGatewayNaming.opaqueReference(namespace: "keychainAccount",
                                                account: account),
            "ref:v1:2f65616838e9ebb2a3aa6dae6425a80dcc827e8aa0301e63552a4f21218d797c")
    }
}
