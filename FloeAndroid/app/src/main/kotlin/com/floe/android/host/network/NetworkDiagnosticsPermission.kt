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
 * query is carried, and `targetHost == null` (status/wifiScan, mDNS-only
 * lanDiscover) leaves the prompt to Main's existing host permission surface.
 * A subnet `lanDiscover` hint is the network address, and a speedTest hint is
 * the explicit endpoint host; both are display/guidance only and never grant
 * permission or substitute for the service's own target policy.
 */
internal fun NetworkPermissionRequest.surfaceWithExistingBroker(
    broker: LocalNetworkAccessBroker?,
) {
    // A LAN browse/scan has a human label but not necessarily a connectable
    // endpoint; speedTest supplies an explicit HTTPS host. Neither value is
    // dispatched: the broker's serverId is only the guidance identity.
    val endpoint = targetLabel
        ?: targetHost?.let { "https://$it" }
        ?: return
    broker?.noteBlockedConnect(
        serverId = "network-tool:$operationID",
        endpoint = endpoint,
    )
}
