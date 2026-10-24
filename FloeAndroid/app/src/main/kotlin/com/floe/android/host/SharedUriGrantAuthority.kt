// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafSharedGrantBroker
import com.floe.android.safgateway.SafUriRef

/** The application-wide lifetime broker for all URI consumers. It does not
 * authorize IO, persist source records or replace live platform grant probes.
 */
internal object SharedUriGrantAuthority {
    val broker = SafSharedGrantBroker()
    fun <T> withExclusiveAuthority(block: () -> T): T = broker.withExclusiveAuthority(block)

    fun acquireRead(resolver: ContentResolver, uri: Uri, allowPersistence: Boolean = true): SafSharedGrantBroker.Lease =
        broker.acquire(SafUriRef(uri.toString()), SafAccessFlag.READ,
            isPersisted = {
                resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }
            },
            take = { if (allowPersistence) resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) },
            release = {
                if (resolver.persistedUriPermissions.none { it.uri == uri && it.isReadPermission }) true
                else runCatching {
                    resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }.isSuccess
            })
}
