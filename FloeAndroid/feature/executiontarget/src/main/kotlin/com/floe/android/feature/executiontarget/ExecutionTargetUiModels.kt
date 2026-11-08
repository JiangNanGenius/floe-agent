// SPDX-License-Identifier: MPL-2.0
//
// C02 presentation values. These are parsed from the closed trusted-host
// wire and rendered by the sheet. No secret, remote absolute path or command
// text is represented.
package com.floe.android.feature.executiontarget

data class C02TargetUi(
    val taskID: String,
    val revision: Long,
    val kind: String,
    val environmentID: String,
    val projectID: String?,
    val workspaceID: String,
    val rootEpoch: Long,
    val provenance: String,
    val remoteHostID: String?,
    val remoteOS: String?,
    val remoteArchitecture: String?,
    val remoteGeneration: String?,
)

data class C02LocalEnvironmentUi(
    val id: String,
    val name: String?,
    val kind: String,
    val state: String,
    val requiresRebuild: Boolean,
)

data class C02RemoteHostUi(
    val id: String,
    val displayName: String,
    val isExecutionEnvironment: Boolean,
    val sshConfigured: Boolean,
)

data class C02WorkUi(
    val liveRuns: Int,
    val liveChildRuns: Int,
    val activeJobs: Int,
    val shellSessions: Int,
    val managedServices: Int,
    val unknownOutcomes: Int,
    val files: Int,
    val bytes: Long,
) {
    val hasLiveWork: Boolean
        get() = liveRuns + liveChildRuns + activeJobs + shellSessions +
            managedServices + unknownOutcomes > 0
}

data class C02DrainReceiptUi(
    val complete: Boolean,
    val timedOut: Boolean,
    val stoppedRuns: Int,
    val stoppedJobs: Int,
    val closedSessions: Int,
    val closedServices: Int,
    val unknownOutcomes: Int,
)

data class C02MigrationUi(
    val id: String,
    val taskID: String,
    val phase: String,
    val revision: Long,
    val cancellationRequested: Boolean,
    val affectedWork: C02WorkUi,
    val source: C02TargetUi,
    val destination: C02TargetUi,
    val failureCode: String?,
    val drainReceipt: C02DrainReceiptUi?,
)

data class C02HostKeyChallengeUi(
    val id: String,
    val taskID: String,
    val hostID: String,
    val address: String,
    val port: Int,
    val keyType: String,
    val fingerprintSHA256: String,
    val expectedFingerprintSHA256: String?,
    val kind: String,
    val expiresAt: String,
)

data class C02MigrationPreviewUi(
    val taskID: String,
    val source: C02TargetUi,
    val destination: C02TargetUi,
    val affectedWork: C02WorkUi,
    val requiresDrain: Boolean,
    val canCommit: Boolean,
    val challenge: C02HostKeyChallengeUi?,
    val generatedAt: String,
    val expiresAt: String,
)

data class C02TargetSnapshotUi(
    val taskID: String,
    val target: C02TargetUi?,
    val migration: C02MigrationUi?,
    val remoteExecutionAllowed: Boolean,
    val hasUsableLocalEnvironment: Boolean,
    val canCreateInitialTarget: Boolean,
    val localEnvironments: List<C02LocalEnvironmentUi>,
    val remoteHosts: List<C02RemoteHostUi>,
)

data class C02TargetBindingReceiptUi(
    val target: C02TargetUi,
    val migration: C02MigrationUi?,
)

internal data class ExecutionLocationChoice(
    val key: String,
    val kind: String,
    val environmentID: String?,
    val hostID: String?,
    val name: String?,
    val localKind: String?,
    val isCurrent: Boolean,
    val enabled: Boolean,
)

/** Presentation of the native catalog, including the current pinned location. */
internal object ExecutionLocationChoices {
    fun available(snapshot: C02TargetSnapshotUi): List<ExecutionLocationChoice> {
        val current = snapshot.target
        val local = snapshot.localEnvironments
            .filter { it.state == "active" && !it.requiresRebuild && it.kind in setOf("project", "session") }
            .sortedBy { if (it.kind == "project") 0 else 1 }
            .map { environment ->
                ExecutionLocationChoice(
                    key = "local:${environment.id}", kind = "localLinux",
                    environmentID = environment.id, hostID = null,
                    name = environment.name, localKind = environment.kind,
                    isCurrent = current?.kind == "localLinux" && current.environmentID == environment.id,
                    enabled = true,
                )
            }
        val remote = snapshot.remoteHosts
            .filter { it.isExecutionEnvironment && it.sshConfigured }
            .map { host ->
                ExecutionLocationChoice(
                    key = "ssh:${host.id}", kind = "ssh", environmentID = null,
                    hostID = host.id, name = host.displayName, localKind = null,
                    isCurrent = current?.kind == "ssh" && current.remoteHostID == host.id,
                    enabled = snapshot.remoteExecutionAllowed,
                )
            }
        return local + remote
    }

    fun initialKey(snapshot: C02TargetSnapshotUi): String {
        snapshot.target?.let { target ->
            // An unavailable pin is still the task's target. Do not select a
            // different machine just because the current one left the catalog.
            return if (target.kind == "ssh") "ssh:${target.remoteHostID}" else "local:${target.environmentID}"
        }
        val choices = available(snapshot).filter { it.enabled }
        // Match the host's session -> project fallback. A shared project
        // must not hide an existing but ambiguous task-session selection.
        val sessions = choices.filter { it.localKind == "session" }
        if (sessions.isNotEmpty()) return sessions.singleOrNull()?.key.orEmpty()
        val projects = choices.filter { it.localKind == "project" }
        if (projects.isNotEmpty()) return projects.singleOrNull()?.key.orEmpty()
        return choices.singleOrNull()?.key.orEmpty()
    }
}

data class ExecutionTargetUiState(
    val loading: Boolean = true,
    val taskID: String? = null,
    val snapshot: C02TargetSnapshotUi? = null,
    val preview: C02MigrationPreviewUi? = null,
    val busy: Boolean = false,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val retryable: Boolean = false,
    val challenge: C02HostKeyChallengeUi? = null,
    val notice: String? = null,
) {
    val currentTarget: C02TargetUi? get() = snapshot?.target
    val activeMigration: C02MigrationUi? get() = snapshot?.migration
}
