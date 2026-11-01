// SPDX-License-Identifier: MPL-2.0
//
// C02 client for the reserved trusted-host `floe.target/19` channel. Every
// request is built from trusted IDs and explicit UI choices; no secret,
// model text or remote path is ever sent or retained.
package com.floe.android.host.executiontarget

import com.floe.android.feature.executiontarget.C02MigrationPreviewUi
import com.floe.android.feature.executiontarget.C02MigrationUi
import com.floe.android.feature.executiontarget.C02TargetBindingReceiptUi
import com.floe.android.feature.executiontarget.C02TargetSnapshotUi
import com.floe.android.feature.executiontarget.C02TargetUi
import java.util.UUID
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.parseToJsonElement
import kotlinx.serialization.json.put

internal class C02TargetClient(
    private val transport: C02TargetTransport = SwiftC02TargetTransport,
) {
    fun snapshot(taskID: String): C02TargetSnapshotUi {
        val response = exchange("c02.target.snapshot") { put("taskID", taskID) }
        return C02TargetJson.parseSnapshot(response)
    }

    fun initialize(
        taskID: String,
        kind: String,
        environmentID: String?,
        hostID: String?,
    ): C02TargetUi {
        val response = exchange("c02.target.initialize") {
            put("taskID", taskID)
            put("destination", destination(kind, environmentID, hostID))
        }
        return C02TargetJson.parseTarget(response.requiredObject("target"))
    }

    fun checkMigration(
        taskID: String,
        expectedRevision: Long,
        kind: String,
        environmentID: String?,
        hostID: String?,
    ): C02MigrationPreviewUi {
        val response = exchange("c02.target.checkMigration") {
            put("taskID", taskID)
            put("expectedRevision", expectedRevision)
            put("destination", destination(kind, environmentID, hostID))
        }
        return C02TargetJson.parsePreview(response)
    }

    fun beginMigration(
        taskID: String,
        expectedRevision: Long,
        kind: String,
        environmentID: String?,
        hostID: String?,
        drainTimeoutSeconds: Int = 30,
    ): C02TargetBindingReceiptUi {
        val response = exchange("c02.target.beginMigration") {
            put("taskID", taskID)
            put("expectedRevision", expectedRevision)
            put("destination", destination(kind, environmentID, hostID))
            put("drainTimeoutSeconds", drainTimeoutSeconds)
        }
        return C02TargetBindingReceiptUi(
            target = C02TargetJson.parseTarget(response.requiredObject("target")),
            migration = response.objectOrNull("migration")?.let(C02TargetJson::parseMigration),
        )
    }

    fun migration(taskID: String): C02MigrationUi? {
        val response = exchange("c02.target.migration") { put("taskID", taskID) }
        return response.objectOrNull("migration")?.let(C02TargetJson::parseMigration)
    }

    fun cancelMigration(taskID: String, expectedRevision: Long): C02MigrationUi? {
        val response = exchange("c02.target.cancelMigration") {
            put("taskID", taskID)
            put("expectedRevision", expectedRevision)
        }
        return response.objectOrNull("migration")?.let(C02TargetJson::parseMigration)
    }

    fun approveHostKey(
        taskID: String,
        challengeID: String,
        accept: Boolean,
        replaceChanged: Boolean,
        expectedFingerprint: String?,
    ) {
        exchange("c02.target.approveHostKey") {
            put("taskID", taskID)
            put("challengeID", challengeID)
            put("accept", accept)
            put("replaceChanged", replaceChanged)
            if (expectedFingerprint != null) put("expectedFingerprint", expectedFingerprint)
        }
    }

    private fun destination(
        kind: String,
        environmentID: String?,
        hostID: String?,
    ): JsonObject = buildJsonObject {
        put("kind", kind)
        put("explicitUserChoice", true)
        if (environmentID != null) put("environmentID", environmentID)
        if (hostID != null) put("remoteHostID", hostID)
    }

    private fun exchange(
        operation: String,
        payload: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit,
    ): JsonObject {
        val request = buildJsonObject {
            put("version", C02_TARGET_VERSION)
            put("schema", C02_TARGET_SCHEMA)
            put("operation", operation)
            put("requestID", UUID.randomUUID().toString())
            this.payload()
        }
        val raw = transport.exchange(request.toString())
        val response = runCatching { C02TargetJson.json.parseToJsonElement(raw).jsonObject }
            .getOrElse {
                throw C02TargetFailure("malformedResponse", "The target reply was unreadable.")
            }
        if ((response["ok"] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull != "true") {
            val challenge = response.objectOrNull("challenge")
                ?.let(C02TargetJson::parseChallenge)
            throw C02TargetFailure(
                code = response.stringOrNull("code") ?: "targetFailure",
                message = response.stringOrNull("message") ?: "The execution target operation failed.",
                retryable = response.booleanOrFalse("retryable"),
                challenge = challenge,
            )
        }
        return response
    }
}
