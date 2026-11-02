// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import org.json.JSONObject

/** Resolve one authenticated metadata request, never re-submit its operation.
 * Queue acceptance is not the requested metadata. Poll only the original receipt;
 * cancellation closes the caller's connection without stopping foreign work.
 */
internal object RuntimeMetadataRead {
    suspend fun read(
        operation: String,
        payload: JSONObject = JSONObject(),
        timeoutMillis: Long = 8_000,
        exchange: (String, JSONObject, String) -> JSONObject,
    ): JSONObject {
        require(operation in setOf("environment.list", "install.status"))
        require(timeoutMillis > 0)
        return withTimeout(timeoutMillis) {
            val requestID = UUID.randomUUID().toString()
            fun result(envelope: JSONObject): JSONObject {
                check(envelope.optBoolean("ok")) { "metadataExchangeFailed" }
                return envelope.getJSONObject("result")
            }
            currentCoroutineContext().ensureActive()
            var receipt = result(exchange(operation, payload, requestID))
            // Some installed runtimes answer a cached install snapshot directly.
            if (!receipt.has("state")) return@withTimeout receipt
            while (true) {
                check(receipt.optString("requestID") == requestID) { "metadataReceiptMismatch" }
                when (receipt.getString("state")) {
                    "completed" -> return@withTimeout receipt.getJSONObject("result")
                    "queued", "running" -> Unit
                    else -> error("metadataRequestUnsettled")
                }
                delay(25)
                currentCoroutineContext().ensureActive()
                receipt = result(exchange("request.status",
                    JSONObject().put("requestID", requestID), UUID.randomUUID().toString()))
            }
            @Suppress("UNREACHABLE_CODE")
            error("metadataRequestUnsettled")
        }
    }
}
