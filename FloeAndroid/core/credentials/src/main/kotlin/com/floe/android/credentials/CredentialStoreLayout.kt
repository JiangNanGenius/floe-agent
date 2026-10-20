// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

import android.content.Context
import java.io.File

/**
 * On-device layout. Everything lives under `noBackupFilesDir`, which the
 * platform excludes from Android Auto Backup and device-to-device transfer.
 * Namespace and record names are opaque SHA-256 identifiers.
 */
internal object CredentialStoreLayout {
    const val ROOT_DIRECTORY = "floe-credentials"
    const val RECORD_SUFFIX = ".cred"

    fun root(context: Context): File = File(context.noBackupFilesDir, ROOT_DIRECTORY)

    fun namespaceDirectory(context: Context, namespace: String): File =
        File(root(context), CredentialReferenceCodec.namespaceId(namespace))

    fun recordFile(context: Context, namespace: String, reference: String): File =
        File(
            namespaceDirectory(context, namespace),
            CredentialReferenceCodec.recordId(namespace, reference) + RECORD_SUFFIX,
        )

    fun keyAlias(namespace: String, reference: String): String =
        CredentialReferenceCodec.keyAlias(namespace, reference)
}
