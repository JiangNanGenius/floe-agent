// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notification

import java.util.UUID

/** Notification UUID serialization may differ from the native store's case.
 * Only an equivalent complete UUID can select the authoritative run key. */
internal object NotificationRunIdentity {
    fun resolve(requested: String, returned: String): String? {
        if (requested.length != 36 || returned.length != 36) return null
        val expected = runCatching { UUID.fromString(requested) }.getOrNull() ?: return null
        val actual = runCatching { UUID.fromString(returned) }.getOrNull() ?: return null
        return returned.takeIf { actual == expected }
    }
}
