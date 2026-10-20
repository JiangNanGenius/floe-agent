// SPDX-License-Identifier: MPL-2.0
//
// DEBUG-ONLY product-UID sealed credential enrollment (no release backdoor).
//
// Purpose (MAIN_CLOUD_CREDENTIAL_REFERENCE_PREFLIGHT_20261020): let Main put
// a real provider credential into the ACTUAL product App UID's Android
// Keystore-backed CredentialStore WITHOUT the plaintext ever appearing in
// argv, logs, environment, clipboard or a fixture.
//
// Flow (all ciphertext-only on the device):
//   1. `begin` (in the product process via instrumentation targetContext)
//      creates a one-shot RSA-3072 AndroidKeyStore session and returns ONLY
//      the PUBLIC descriptor (public key + session metadata).
//   2. The host sealer (`FloeAndroid/scripts/seal-debug-credential.py`, run
//      with the key on protected stdin/fd) produces the sealed blob.
//   3. `import` (again in the product process) decrypts directly into the
//      CredentialStore instance the product gateway uses and wipes plaintext.
//
// Namespace/account identity is the PRODUCT one, never a QA invention:
//   * namespace = "keychainAccount"  (SecretGatewayDispatcher.STORE_NAMESPACE)
//   * model-provider account = "provider.<providerUUID>" (the deterministic
//     KeychainSecretStore account rule preserved on Android)
//   * reference = SecretGatewayNaming.opaqueReference(namespace:account:)
//     = "ref:v1:" + SHA-256("floe-android-secret:v1" U+001F namespace U+001F account)
//
// This object exists only in the debug variants of both flavors; it exports
// nothing to release builds and is not reachable from any exported component.
package com.floe.android.debugcredential

import android.content.Context
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.credentials.debug.DebugSealedEnrollment
import com.floe.android.credentials.debug.DebugEnrollmentException
import com.floe.android.credentials.debug.EnrollmentDescriptor
import com.floe.android.credentials.debug.EnrollmentImportResult
import java.io.File
import java.security.MessageDigest

object ProductCredentialEnrollment {

    /** The product gateway namespace (SecretGatewayDispatcher). */
    const val NAMESPACE = "keychainAccount"

    /** The Swift naming scheme + separator (SecretGatewayNaming). */
    private const val REFERENCE_SCHEME = "floe-android-secret:v1"
    private const val SEPARATOR = "\u001F"

    /** The deterministic account of one MODEL provider's secret.
     *
     * MUST byte-match the Swift `ConfigSecretIdentity.providerAccount`
     * (RuntimeFacadeConfigModels.swift): `"provider.\(providerID.uuidString)"`
     * where Swift's `uuidString` is the CANONICAL UPPERCASE 8-4-4-4-12 hex.
     * A strict UUID parse + uppercase (Locale.ROOT) reproduces it exactly;
     * a lowercase/tolerant spelling would mint a DIFFERENT opaque reference
     * and store the secret under the wrong account.
     */
    fun providerAccount(providerId: String): String {
        val canonical = java.util.UUID.fromString(providerId.trim())
            .toString()
            .uppercase(java.util.Locale.ROOT)
        return "provider.$canonical"
    }

    /** The exact opaque reference the vault/gateway resolves for an account. */
    fun opaqueReference(namespace: String, account: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("$REFERENCE_SCHEME$SEPARATOR$namespace$SEPARATOR$account"
                .toByteArray(Charsets.UTF_8))
        return "ref:v1:" + digest.joinToString("") { "%02x".format(it) }
    }

    /** Phase 1: create the session in the PRODUCT process. Returns the
     *  PUBLIC descriptor JSON (public key + metadata only). */
    fun begin(context: Context, providerId: String): String {
        val account = providerAccount(providerId)
        val reference = opaqueReference(NAMESPACE, account)
        val descriptor = DebugSealedEnrollment.begin(
            context = context,
            namespace = NAMESPACE,
            reference = reference,
        )
        return descriptorJson(descriptor)
    }

    /** Phase 3: import the sealed ciphertext file into the PRODUCT store. */
    @Throws(DebugEnrollmentException::class, java.io.IOException::class)
    suspend fun import(context: Context, sealedFile: File): EnrollmentImportResult {
        require(sealedFile.isFile) { "sealed_blob_missing" }
        val sealed = sealedFile.readBytes()
        return DebugSealedEnrollment.importSealed(context, sealed)
    }

    /** Phase 4 (verification): read the EXACT product store entry back and
     *  compare the SHA-256 digest supplied by the operator. Returns the
     *  observed byte count; throws on mismatch/missing. The secret itself is
     *  never printed or returned to the caller. */
    suspend fun verify(context: Context, providerId: String,
                       expectedSha256Hex: String): Int {
        val account = providerAccount(providerId)
        val reference = opaqueReference(NAMESPACE, account)
        val store = AndroidKeystoreCredentialStore.create(
            context.applicationContext ?: context, NAMESPACE)
        val value = store.read(reference) ?: throw IllegalStateException(
            "credential_missing")
        val digest = MessageDigest.getInstance("SHA-256").digest(value)
        val hex = digest.joinToString("") { "%02x".format(it) }
        value.fill(0)
        if (!hex.equals(expectedSha256Hex.trim().lowercase(), ignoreCase = true)) {
            throw IllegalStateException("credential_digest_mismatch")
        }
        return value.size.coerceAtLeast(0)
    }

    /** Debug cleanup: delete one synthetic enrollment entry by exact account
     *  (never a wildcard; used only for synthetic fixtures). */
    suspend fun deleteSynthetic(context: Context, providerId: String): Boolean {
        val account = providerAccount(providerId)
        val reference = opaqueReference(NAMESPACE, account)
        val store = AndroidKeystoreCredentialStore.create(
            context.applicationContext ?: context, NAMESPACE)
        val existing = store.read(reference)
        if (existing == null) return false
        existing.fill(0)
        store.delete(reference)
        return true
    }

    private fun descriptorJson(descriptor: EnrollmentDescriptor): String {
        val publicKeyB64 = android.util.Base64.encodeToString(
            descriptor.publicKeyDer, android.util.Base64.NO_WRAP)
        // EXACT sealer descriptor schema (closed field set; the account is
        // printed separately by the harness, never inside this document).
        return buildString {
            append("{\"protocolVersion\":").append(descriptor.protocolVersion)
            append(",\"sessionID\":\"").append(descriptor.sessionID).append('"')
            append(",\"packageName\":\"").append(descriptor.packageName).append('"')
            append(",\"namespace\":\"").append(descriptor.namespace).append('"')
            append(",\"reference\":\"").append(descriptor.reference).append('"')
            append(",\"expiresAtEpochMillis\":")
                .append(descriptor.expiresAtEpochMillis)
            append(",\"publicKeyDerBase64\":\"").append(publicKeyB64).append('"')
            append('}')
        }
    }
}
