// SPDX-License-Identifier: MPL-2.0
//
// C02 trusted-host values. Parsed from the closed `floe.target/19` wire.
// No secret, remote absolute path or command text is represented here.
package com.floe.android.host.executiontarget

import com.floe.android.bridge.SwiftCore
import com.floe.android.feature.executiontarget.C02DrainReceiptUi
import com.floe.android.feature.executiontarget.C02HostKeyChallengeUi
import com.floe.android.feature.executiontarget.C02LocalEnvironmentUi
import com.floe.android.feature.executiontarget.C02MigrationPreviewUi
import com.floe.android.feature.executiontarget.C02MigrationUi
import com.floe.android.feature.executiontarget.C02RemoteHostUi
import com.floe.android.feature.executiontarget.C02TargetBindingReceiptUi
import com.floe.android.feature.executiontarget.C02TargetSnapshotUi
import com.floe.android.feature.executiontarget.C02TargetUi
import com.floe.android.feature.executiontarget.C02WorkUi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull

internal const val C02_TARGET_VERSION = 19
internal const val C02_TARGET_SCHEMA = "floe.target/19"

internal fun interface C02TargetTransport {
    fun exchange(request: String): String
}

internal object SwiftC02TargetTransport : C02TargetTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal class C02TargetFailure(
    val code: String,
    override val message: String,
    val retryable: Boolean = false,
    val challenge: C02HostKeyChallengeUi? = null,
) : Exception(message)

internal object C02TargetJson {
    val json = Json { ignoreUnknownKeys = true; isLenient = false }

    fun parse(value: String): C02TargetUi =
        parseTarget(json.parseToJsonElement(value).jsonObject)

    fun parseTarget(obj: JsonObject): C02TargetUi = C02TargetUi(
        taskID = obj.requiredString("taskID"),
        revision = obj.requiredLong("revision"),
        kind = obj.requiredString("kind"),
        environmentID = obj.requiredString("environmentID"),
        projectID = obj.stringOrNull("projectID"),
        workspaceID = obj.requiredString("workspaceID"),
        rootEpoch = obj.requiredLong("rootEpoch"),
        provenance = obj.requiredString("provenance"),
        remoteHostID = obj.stringOrNull("remoteHostID"),
        remoteOS = obj.stringOrNull("remoteOS"),
        remoteArchitecture = obj.stringOrNull("remoteArchitecture"),
        remoteGeneration = obj.stringOrNull("remoteGeneration"),
    )

    fun parseWork(obj: JsonObject?): C02WorkUi = C02WorkUi(
        liveRuns = obj?.intOrZero("liveRuns") ?: 0,
        liveChildRuns = obj?.intOrZero("liveChildRuns") ?: 0,
        activeJobs = obj?.intOrZero("activeJobs") ?: 0,
        shellSessions = obj?.intOrZero("shellSessions") ?: 0,
        managedServices = obj?.intOrZero("managedServices") ?: 0,
        unknownOutcomes = obj?.intOrZero("unknownOutcomes") ?: 0,
        files = obj?.intOrZero("files") ?: 0,
        bytes = obj?.longOrZero("bytes") ?: 0L,
    )

    fun parseMigration(obj: JsonObject): C02MigrationUi = C02MigrationUi(
        id = obj.requiredString("id"),
        taskID = obj.requiredString("taskID"),
        phase = obj.requiredString("phase"),
        revision = obj.requiredLong("revision"),
        cancellationRequested = obj.booleanOrFalse("cancellationRequested"),
        affectedWork = parseWork(obj.objectOrNull("affectedWork")),
        source = parseTarget(obj.requiredObject("source")),
        destination = parseTarget(obj.requiredObject("destination")),
        failureCode = obj.stringOrNull("failureCode"),
        drainReceipt = obj.objectOrNull("drainReceipt")?.let(::parseDrainReceipt),
    )

    fun parseDrainReceipt(obj: JsonObject): C02DrainReceiptUi = C02DrainReceiptUi(
        complete = obj.booleanOrFalse("complete"),
        timedOut = obj.booleanOrFalse("timedOut"),
        stoppedRuns = obj.intOrZero("stoppedRuns"),
        stoppedJobs = obj.intOrZero("stoppedJobs"),
        closedSessions = obj.intOrZero("closedSessions"),
        closedServices = obj.intOrZero("closedServices"),
        unknownOutcomes = obj.intOrZero("unknownOutcomes"),
    )

    fun parseChallenge(obj: JsonObject): C02HostKeyChallengeUi = C02HostKeyChallengeUi(
        id = obj.requiredString("id"),
        taskID = obj.requiredString("taskID"),
        hostID = obj.requiredString("hostID"),
        address = obj.requiredString("address"),
        port = obj.intOrZero("port"),
        keyType = obj.requiredString("keyType"),
        fingerprintSHA256 = obj.requiredString("fingerprintSHA256"),
        expectedFingerprintSHA256 = obj.stringOrNull("expectedFingerprintSHA256"),
        kind = obj.requiredString("kind"),
        expiresAt = obj.requiredString("expiresAt"),
    )

    fun parseSnapshot(obj: JsonObject): C02TargetSnapshotUi = C02TargetSnapshotUi(
        taskID = obj.requiredString("taskID"),
        target = obj.objectOrNull("target")?.let(::parseTarget),
        migration = obj.objectOrNull("migration")?.let(::parseMigration),
        remoteExecutionAllowed = obj.booleanOrFalse("remoteExecutionAllowed"),
        hasUsableLocalEnvironment = obj.booleanOrFalse("hasUsableLocalEnvironment"),
        canCreateInitialTarget = obj.booleanOrFalse("canCreateInitialTarget"),
        localEnvironments = obj.arrayOrEmpty("localEnvironments").mapNotNull {
            (it as? JsonObject)?.let(::parseLocalEnvironment)
        },
        remoteHosts = obj.arrayOrEmpty("remoteHosts").mapNotNull {
            (it as? JsonObject)?.let(::parseRemoteHost)
        },
    )

    fun parsePreview(obj: JsonObject): C02MigrationPreviewUi = C02MigrationPreviewUi(
        taskID = obj.requiredString("taskID"),
        source = parseTarget(obj.requiredObject("source")),
        destination = parseTarget(obj.requiredObject("destination")),
        affectedWork = parseWork(obj.objectOrNull("affectedWork")),
        requiresDrain = obj.booleanOrFalse("requiresDrain"),
        canCommit = obj.booleanOrFalse("canCommit"),
        challenge = obj.objectOrNull("challenge")?.let(::parseChallenge),
        generatedAt = obj.requiredString("generatedAt"),
        expiresAt = obj.requiredString("expiresAt"),
    )

    private fun parseLocalEnvironment(obj: JsonObject) = C02LocalEnvironmentUi(
        id = obj.requiredString("id"),
        name = obj.stringOrNull("name"),
        kind = obj.requiredString("kind"),
        state = obj.requiredString("state"),
        requiresRebuild = obj.booleanOrFalse("requiresRebuild"),
    )

    private fun parseRemoteHost(obj: JsonObject) = C02RemoteHostUi(
        id = obj.requiredString("id"),
        displayName = obj.requiredString("displayName"),
        isExecutionEnvironment = obj.booleanOrFalse("isExecutionEnvironment"),
        sshConfigured = obj.booleanOrFalse("sshConfigured"),
    )
}

internal fun JsonObject.stringOrNull(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull

internal fun JsonObject.requiredString(key: String): String =
    stringOrNull(key) ?: throw C02TargetFailure("malformedResponse", "Missing $key")

internal fun JsonObject.longOrZero(key: String): Long =
    (this[key] as? JsonPrimitive)?.longOrNull ?: 0L

internal fun JsonObject.requiredLong(key: String): Long =
    (this[key] as? JsonPrimitive)?.longOrNull
        ?: throw C02TargetFailure("malformedResponse", "Missing $key")

internal fun JsonObject.intOrZero(key: String): Int =
    (this[key] as? JsonPrimitive)?.intOrNull ?: 0

internal fun JsonObject.booleanOrFalse(key: String): Boolean =
    (this[key] as? JsonPrimitive)?.booleanOrNull ?: false

internal fun JsonObject.objectOrNull(key: String): JsonObject? =
    this[key]?.takeUnless { it is JsonNull } as? JsonObject

internal fun JsonObject.requiredObject(key: String): JsonObject =
    objectOrNull(key) ?: throw C02TargetFailure("malformedResponse", "Missing $key")

internal fun JsonObject.arrayOrEmpty(key: String): List<JsonElement> =
    (this[key] as? kotlinx.serialization.json.JsonArray) ?: emptyList()
