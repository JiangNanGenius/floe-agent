// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import com.floe.android.host.linux.RuntimeComponentMatch
import com.floe.android.runtimeipc.RuntimeConnection
import com.floe.android.runtimeipc.RuntimeWire
import com.floe.android.schedule.TaskScheduleEnvironmentChoice
import com.floe.android.schedule.TaskScheduleEnvironmentProvider
import com.floe.android.schedule.TaskScheduleEnvironmentResult
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import org.json.JSONObject

/**
 * G07.3B: the ONE Application-owned authority reader for scheduled-task
 * environment selection.
 *
 * The project/session environment registry lives in the distinct-UID runtime
 * component and is reachable only through the signed runtime IPC
 * `environment.list` operation. This class performs exactly one bounded,
 * off-main read per request over the EXISTING authenticated
 * [RuntimeConnection], after the SAME app-upgrade component gate the readiness
 * ingress uses. It never reads host files, never lists a shell, never caches a
 * "successful empty" answer, and never treats a failure as an authoritative
 * empty list:
 *
 *  * a stale/foreign runtime component is refused BEFORE any connection or
 *    peer identity is committed (the Alpha20 stale-component poison bug);
 *  * protocol, runtime process identity, installed rootfs receipt and peer
 *    signer/UID facts must all be live; any failure returns a typed
 *    [TaskScheduleEnvironmentResult.Unavailable];
 *  * an authority reply that is malformed (or has rows but none parseable)
 *    is unavailable, not an empty environment list;
 *  * the accepted Root epoch is re-checked after the read, so a generation
 *    replacement can never publish rows into a newer root.
 *
 * The returned rows are metadata only (id/name/kind/owner/state/rebuild/
 * backend/parent). The native `G073ScheduleEnvironmentOwnership` gate still
 * proves that the selected PROJECT environment is owned by the frozen
 * workspace before any scheduled launch, so this reader grants nothing.
 */
internal class RuntimeScheduleEnvironmentProvider(
    context: Context,
    private val currentNativeEpoch: () -> Long?,
    private val componentRefusal: () -> String? = {
        RuntimeComponentMatch.refusal(context.applicationContext)
    },
) : TaskScheduleEnvironmentProvider {
    private val appContext = context.applicationContext

    override suspend fun environments(): TaskScheduleEnvironmentResult =
        withContext(Dispatchers.IO) {
            val epoch = currentNativeEpoch()?.takeIf { it > 0L }
                ?: return@withContext TaskScheduleEnvironmentResult.Unavailable(
                    "runtimeUnavailable")
            val component = try {
                componentRefusal()
            } catch (_: Throwable) {
                "componentUnavailable"
            }
            if (component != null) {
                return@withContext TaskScheduleEnvironmentResult.Unavailable(component)
            }
            try {
                RuntimeConnection(appContext).use { client ->
                    client.connect().get(
                        ScheduleEnvironmentAdmission.CONNECT_TIMEOUT_SECONDS,
                        TimeUnit.SECONDS,
                    )
                    val proof = client.currentPeerProof()
                    val ownUid = android.os.Process.myUid()
                    val status = result(client.exchange("status"))
                    val install = result(client.exchange("install.status"))
                    val refusal = ScheduleEnvironmentAdmission.refusal(
                        componentRefusal = null,
                        protocol = status.optInt("protocol", -1),
                        expectedProtocol = RuntimeWire.VERSION,
                        identity = ScheduleEnvironmentAdmission.processIdentity(
                            status.optInt("runtimePid", -1),
                            status.optString("runtimeBootToken"),
                        ),
                        installPhase = install.optString("phase"),
                        rootfsReceiptDigest = install.optString("rootfsReceiptDigest"),
                        peerWellFormed = proof?.wellFormed(ownUid) == true,
                        peerUid = proof?.peerUid ?: -1,
                        ownUid = ownUid,
                    )
                    if (refusal != null) {
                        return@use TaskScheduleEnvironmentResult.Unavailable(refusal)
                    }
                    val list = result(client.exchange("environment.list"))
                    // New-scope epoch fence: never publish a snapshot read
                    // for a root generation that was retired mid-read.
                    if (currentNativeEpoch() != epoch) {
                        return@use TaskScheduleEnvironmentResult.Unavailable("superseded")
                    }
                    ScheduleEnvironmentWire.parse(list.toString())
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                TaskScheduleEnvironmentResult.Unavailable("runtimeUnavailable")
            }
        }

    private fun result(envelope: JSONObject): JSONObject {
        if (!envelope.optBoolean("ok")) error("exchange_failed")
        return envelope.optJSONObject("result") ?: error("exchange_missing_result")
    }
}

/**
 * Pure, testable admission and parsing decisions of
 * [RuntimeScheduleEnvironmentProvider]. Production supplies live facts from
 * the authenticated connection; JVM tests pin every refusal and malformed
 * input without Android/JNI.
 */
internal object ScheduleEnvironmentAdmission {
    const val CONNECT_TIMEOUT_SECONDS = 15L
    const val INSTALL_PHASE = "installed"

    /** The runtime process generation token, derived only when BOTH the pid
     *  and a 32-hex boot nonce were reported (same shape the readiness
     *  ingress requires; never a free-form accepted string). */
    fun processIdentity(pid: Int, bootToken: String): String? {
        if (pid <= 0 || !Regex("^[0-9a-f]{32}$").matches(bootToken)) return null
        return "runtime:pid$pid:gen$bootToken".take(128)
    }

    fun isHex64(value: String?): Boolean =
        value != null && value.length == 64 && value.all { it in "0123456789abcdef" }

    /**
     * Returns null only when the exact-build component, wire protocol,
     * runtime process identity, installed rootfs receipt and peer
     * signer/UID proof are ALL live. Every branch is a closed token; there
     * is no "assume healthy" path.
     */
    fun refusal(
        componentRefusal: String?,
        protocol: Int,
        expectedProtocol: Int,
        identity: String?,
        installPhase: String?,
        rootfsReceiptDigest: String?,
        peerWellFormed: Boolean,
        peerUid: Int,
        ownUid: Int,
    ): String? = when {
        componentRefusal != null -> componentRefusal
        protocol != expectedProtocol -> "engineProtocolUnsupported"
        identity.isNullOrEmpty() -> "engineIdentityUnreported"
        installPhase != INSTALL_PHASE -> "rootfsUnverified"
        !isHex64(rootfsReceiptDigest) -> "rootfsUnverified"
        !peerWellFormed || peerUid < 0 || peerUid == ownUid -> "peerUnverified"
        else -> null
    }
}

/**
 * Bounded parser for the runtime `environment.list` result object
 * (`{baseRevision, environments:[...]}`). Metadata-only fields are passed
 * through; unknown kinds/states and oversized identifiers are dropped rather
 * than coerced. A reply with rows but no parseable row is malformed (NOT an
 * empty success), while a genuinely empty authority list stays available.
 */
internal object ScheduleEnvironmentWire {
    const val MAX_ROWS = 100
    private val KINDS = setOf("project", "session", "template", "shared")

    fun parse(raw: String): TaskScheduleEnvironmentResult {
        val root = try {
            Json.parseToJsonElement(raw) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: return TaskScheduleEnvironmentResult.Unavailable("metadataMalformed")
        val array = root["environments"] as? JsonArray
            ?: return TaskScheduleEnvironmentResult.Unavailable("metadataMalformed")
        if (array.isEmpty()) {
            return TaskScheduleEnvironmentResult.Available(emptyList())
        }
        val rows = ArrayList<TaskScheduleEnvironmentChoice>(minOf(array.size, MAX_ROWS))
        for (index in 0 until minOf(array.size, MAX_ROWS)) {
            val item = array[index] as? JsonObject ?: continue
            val id = item.string("id")
                ?.takeIf { it.length in 1..128 && '\u0000' !in it } ?: continue
            val kind = item.string("kind")?.takeIf { it in KINDS } ?: continue
            val state = item.string("state")?.takeIf { it.length in 1..32 } ?: continue
            val requiresRebuild = (item["requiresRebuild"] as? JsonPrimitive)
                ?.booleanOrNull ?: continue
            rows.add(
                TaskScheduleEnvironmentChoice(
                    id = id,
                    name = item.string("name")?.takeCodePoints(120).orEmpty(),
                    kind = kind,
                    ownerID = item.string("ownerID")?.takeIf { it.length <= 128 },
                    state = state,
                    requiresRebuild = requiresRebuild,
                    executionBackend = item.string("executionBackend")
                        ?.takeIf { it.length in 1..32 },
                    parentID = item.string("parentID")?.takeIf { it.length <= 128 },
                ),
            )
        }
        return if (rows.isEmpty()) {
            TaskScheduleEnvironmentResult.Unavailable("metadataMalformed")
        } else {
            TaskScheduleEnvironmentResult.Available(rows)
        }
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)
            ?.takeIf { it.isString }
            ?.contentOrNull
            ?.takeIf { it.isNotEmpty() }

    /** Bounded display-only truncation at whole code points, never inside a
     *  surrogate pair (a split pair would emit malformed UTF-8 later). */
    private fun String.takeCodePoints(max: Int): String {
        if (codePointCount(0, length) <= max) return this
        return substring(0, offsetByCodePoints(0, max))
    }
}
