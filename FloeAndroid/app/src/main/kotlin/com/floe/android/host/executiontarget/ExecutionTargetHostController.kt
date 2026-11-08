// SPDX-License-Identifier: MPL-2.0
//
// C02 Application-owned execution-target controller.
//
// Owns only the trusted-host client calls and immutable projections. The
// Swift domain/store is the authority for pinning, entry validation, explicit
// migration, CAS and the drain gate. The controller never invents a target,
// never retries a migration and never treats a remote disconnect as a stop.
package com.floe.android.host.executiontarget

import com.floe.android.feature.executiontarget.C02HostKeyChallengeUi
import com.floe.android.feature.executiontarget.C02MigrationPreviewUi
import com.floe.android.feature.executiontarget.C02MigrationUi
import com.floe.android.feature.executiontarget.C02TargetUi
import com.floe.android.feature.executiontarget.ExecutionTargetUiState
import com.floe.android.host.RuntimeHost
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong

class ExecutionTargetHostController internal constructor(
    private val host: RuntimeHost,
    private val client: C02TargetClient = C02TargetClient(),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mutable = MutableStateFlow(ExecutionTargetUiState())
    val state: StateFlow<ExecutionTargetUiState> = mutable.asStateFlow()
    private var job: Job? = null
    private val requestSerial = AtomicLong()

    @Synchronized
    fun load(taskID: String) {
        val request = beginRequest()
        if (!admitted()) {
            mutable.value = ExecutionTargetUiState(
                loading = false,
                taskID = taskID,
                errorCode = "runtime_unavailable",
                errorMessage = null,
            )
            return
        }
        if (host.conversations.entryFor(taskID)?.isTemporary == true) {
            mutable.value = ExecutionTargetUiState(
                loading = false,
                taskID = taskID,
                errorCode = "temporaryTaskRefused",
            )
            return
        }
        val epoch = host.nativeRootEpoch() ?: run {
            mutable.value = ExecutionTargetUiState(
                loading = false, taskID = taskID, errorCode = "runtime_unavailable",
            )
            return
        }
        val generation = host.commandClient.generation()
        mutable.value = (if (mutable.value.taskID == taskID) mutable.value else ExecutionTargetUiState()).copy(
            loading = true, taskID = taskID, errorCode = null,
            errorMessage = null, preview = null, notice = null,
            busy = false, retryable = false, challenge = null,
        )
        job = scope.launch(host.ioDispatcher) {
            val result = runCatching { client.snapshot(taskID) }
            withCurrent(epoch, generation, taskID, request) {
                result.onSuccess { snapshot ->
                    mutable.value = mutable.value.copy(
                        loading = false,
                        snapshot = snapshot,
                        errorCode = null,
                        errorMessage = null,
                        retryable = false,
                    )
                }.onFailure { failure ->
                    mutable.value = mutable.value.copy(
                        loading = false,
                        errorCode = failure.codeOrNull() ?: "targetUnavailable",
                        errorMessage = failure.message,
                        retryable = (failure as? C02TargetFailure)?.retryable == true,
                        challenge = (failure as? C02TargetFailure)?.challenge,
                    )
                }
            }
        }
    }

    @Synchronized
    fun refresh() {
        val taskID = mutable.value.taskID ?: return
        load(taskID)
    }

    @Synchronized
    fun initialize(
        kind: String,
        environmentID: String?,
        remoteHostID: String?,
    ) {
        val taskID = mutable.value.taskID ?: return
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        val request = beginRequest()
        mutable.value = mutable.value.copy(busy = true, errorCode = null, errorMessage = null)
        job = scope.launch(host.ioDispatcher) {
            val result = runCatching {
                client.initialize(taskID, kind, environmentID, remoteHostID)
            }
            withCurrent(epoch, generation, taskID, request) {
                result.onSuccess {
                    mutable.value = mutable.value.copy(busy = false, notice = "targetSet")
                    job = null
                    load(taskID)
                }.onFailure {
                    mutable.value = mutable.value.copy(
                        busy = false,
                        errorCode = it.codeOrNull() ?: "targetSetFailed",
                        errorMessage = it.message,
                        challenge = (it as? C02TargetFailure)?.challenge,
                        retryable = (it as? C02TargetFailure)?.retryable == true,
                    )
                }
            }
        }
    }

    @Synchronized
    fun checkMigration(
        kind: String,
        environmentID: String?,
        remoteHostID: String?,
    ) {
        val taskID = mutable.value.taskID ?: return
        val snapshot = mutable.value.snapshot ?: return
        val target = snapshot.target ?: return
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        val request = beginRequest()
        mutable.value = mutable.value.copy(
            busy = true, preview = null, errorCode = null,
            errorMessage = null, challenge = null,
        )
        job = scope.launch(host.ioDispatcher) {
            val result = runCatching {
                client.checkMigration(
                    taskID = taskID,
                    expectedRevision = target.revision,
                    kind = kind,
                    environmentID = environmentID,
                    hostID = remoteHostID,
                )
            }
            withCurrent(epoch, generation, taskID, request) {
                result.onSuccess { preview ->
                    mutable.value = mutable.value.copy(
                        busy = false, preview = preview, challenge = preview.challenge,
                        errorCode = null, errorMessage = null,
                    )
                }.onFailure {
                    mutable.value = mutable.value.copy(
                        busy = false,
                        errorCode = it.codeOrNull() ?: "checkFailed",
                        errorMessage = it.message,
                        retryable = (it as? C02TargetFailure)?.retryable == true,
                        challenge = (it as? C02TargetFailure)?.challenge,
                    )
                }
            }
        }
    }

    @Synchronized
    fun beginMigration(
        kind: String,
        environmentID: String?,
        remoteHostID: String?,
    ) {
        val taskID = mutable.value.taskID ?: return
        val snapshot = mutable.value.snapshot ?: return
        val target = snapshot.target ?: return
        val preview = mutable.value.preview ?: run {
            mutable.value = mutable.value.copy(errorCode = "checkRequired")
            return
        }
        if (!previewBelongsToTask(preview, taskID, target.revision)) {
            mutable.value = mutable.value.copy(errorCode = "stalePreview")
            return
        }
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        val request = beginRequest()
        mutable.value = mutable.value.copy(busy = true, errorCode = null, errorMessage = null)
        job = scope.launch(host.ioDispatcher) {
            val result = runCatching {
                client.beginMigration(
                    taskID = taskID,
                    expectedRevision = target.revision,
                    kind = kind,
                    environmentID = environmentID,
                    hostID = remoteHostID,
                )
            }
            withCurrent(epoch, generation, taskID, request) {
                result.onSuccess {
                    mutable.value = mutable.value.copy(
                        busy = false, preview = null, challenge = null, notice = "moved",
                    )
                    job = null
                    load(taskID)
                }.onFailure {
                    mutable.value = mutable.value.copy(
                        busy = false,
                        errorCode = it.codeOrNull() ?: "moveFailed",
                        errorMessage = it.message,
                        retryable = (it as? C02TargetFailure)?.retryable == true,
                        challenge = (it as? C02TargetFailure)?.challenge,
                    )
                }
            }
        }
    }

    @Synchronized
    fun cancelMigration() {
        val taskID = mutable.value.taskID ?: return
        val migration = mutable.value.snapshot?.migration ?: return
        if (migration.phase == "committed" || migration.phase == "completed") return
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        val request = beginRequest()
        mutable.value = mutable.value.copy(busy = true, errorCode = null)
        job = scope.launch(host.ioDispatcher) {
            val result = runCatching {
                client.cancelMigration(taskID, migration.revision)
            }
            withCurrent(epoch, generation, taskID, request) {
                result.onSuccess {
                    mutable.value = mutable.value.copy(busy = false, notice = "moveCancelled")
                    job = null
                    load(taskID)
                }.onFailure {
                    mutable.value = mutable.value.copy(
                        busy = false,
                        errorCode = it.codeOrNull() ?: "cancelFailed",
                        errorMessage = it.message,
                    )
                }
            }
        }
    }

    @Synchronized
    fun approveHostKey(
        challengeID: String,
        accept: Boolean,
        replaceChanged: Boolean,
        expectedFingerprint: String?,
    ) {
        val taskID = mutable.value.taskID ?: return
        val epoch = host.nativeRootEpoch() ?: return
        val generation = host.commandClient.generation()
        val request = beginRequest()
        mutable.value = mutable.value.copy(busy = true, errorCode = null)
        job = scope.launch(host.ioDispatcher) {
            val result = runCatching {
                client.approveHostKey(
                    taskID = taskID,
                    challengeID = challengeID,
                    accept = accept,
                    replaceChanged = replaceChanged,
                    expectedFingerprint = expectedFingerprint,
                )
            }
            withCurrent(epoch, generation, taskID, request) {
                result.onSuccess {
                    mutable.value = mutable.value.copy(
                        busy = false, challenge = null, notice = if (accept) "hostTrusted" else "hostRejected",
                    )
                }.onFailure {
                    mutable.value = mutable.value.copy(
                        busy = false,
                        errorCode = it.codeOrNull() ?: "hostKeyFailed",
                        errorMessage = it.message,
                    )
                }
            }
        }
    }

    @Synchronized
    fun clearPreview() {
        mutable.value = mutable.value.copy(preview = null)
    }

    @Synchronized
    fun dismissError() {
        mutable.value = mutable.value.copy(
            errorCode = null, errorMessage = null, retryable = false,
        )
    }

    @Synchronized
    fun dismissNotice() {
        mutable.value = mutable.value.copy(notice = null)
    }

    @Synchronized
    fun release() {
        beginRequest()
    }

    private fun admitted(): Boolean =
        host.nativeRootEpoch() != null && host.readiness.value.storeReady

    private fun beginRequest(): Long {
        val request = requestSerial.incrementAndGet()
        job?.cancel()
        job = null
        return request
    }

    private fun withCurrent(
        epoch: Long, generation: Long, taskID: String, request: Long, settle: () -> Unit,
    ) = synchronized(this) {
        if (current(epoch, generation, taskID, request)) settle()
    }

    private fun current(epoch: Long, generation: Long, taskID: String, request: Long): Boolean =
        requestSerial.get() == request && mutable.value.taskID == taskID &&
            host.nativeRootEpoch() == epoch && host.commandClient.generation() == generation

    private fun previewBelongsToTask(
        preview: C02MigrationPreviewUi,
        taskID: String,
        revision: Long,
    ): Boolean = preview.taskID.equals(taskID, ignoreCase = true) && preview.source.revision == revision
}

private fun Throwable.codeOrNull(): String? = (this as? C02TargetFailure)?.code
