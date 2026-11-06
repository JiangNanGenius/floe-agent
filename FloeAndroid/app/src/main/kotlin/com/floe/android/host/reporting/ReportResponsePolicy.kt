// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.reporting

import org.json.JSONObject

internal object ReportResponsePolicy {
    fun rejectionCode(status: Int, body: String): String {
        if (status == 409 && body.toByteArray(Charsets.UTF_8).size <= 8192 &&
            runCatching { JSONObject(body).optString("code") == "client_update_required" }.getOrDefault(false))
            return "client_update_required"
        return "http_$status"
    }
}
