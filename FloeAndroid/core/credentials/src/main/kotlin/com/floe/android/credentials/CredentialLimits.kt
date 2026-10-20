// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

/** Public bounds shared by the adapter, callers and QA tooling. */
object CredentialLimits {
    /** Opaque references are ASCII and at most this many characters. */
    const val MAX_REFERENCE_CHARS = 128

    /** Namespaces are ASCII and at most this many characters. */
    const val MAX_NAMESPACE_CHARS = 64

    /** Largest accepted plaintext credential, in bytes. */
    const val MAX_SECRET_BYTES = 65_536

    /**
     * Largest accepted on-disk envelope: header + IV + ciphertext (including
     * the 16-byte GCM tag). Keep in sync with the envelope codec.
     */
    const val MAX_ENVELOPE_BYTES = 6 + 12 + MAX_SECRET_BYTES + 16
}
