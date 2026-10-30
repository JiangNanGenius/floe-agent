// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.network

import com.floe.android.host.LocalNetworkAccessBroker

/**
 * Forwards a pump-reported `permissionRequired` to the EXISTING Application
 * LAN broker/guidance surface. There is no duplicate permission store,
 * launcher or Manifest entry here: the broker re-reads
 * `ACCESS_LOCAL_NETWORK` from the platform at the user's explicit action and
 * owns the dialog/recovery flow.
 *
 * The pump already returned the typed `permissionRequired` observation to the
 * Agent; this only surfaces guidance so the user can grant and retry the SAME
 * tool call with a fresh request. No ticket is replayed, no target path or
 * query is carried, and `targetHost == null` (status/wifiScan) leaves the
 * prompt to Main's existing host permission surface.
 */
internal fun NetworkPermissionRequest.surfaceWithExistingBroker(
    broker: LocalNetworkAccessBroker?,
) {
    val host = targetHost ?: return
    broker?.noteBlockedConnect(
        serverId = "network-tool:$operationID",
        endpoint = "https://$host",
    )
}
