// SPDX-License-Identifier: MPL-2.0
//
// Application-owned C05 Desktop Assist settings controller. Swift remains the
// credential-vault and OCR authority; this controller only owns the trusted
// `floe.desktopassist/22` client, the App-scoped lifetime and the RAM-only
// editor. A save/delete operation is never cancelled mid-flight while it may
// still have committed at the vault.

package com.floe.android.host.desktopassist

import com.floe.android.feature.desktopassist.DesktopAssistActions
import com.floe.android.feature.desktopassist.DesktopAssistCardUi
import com.floe.android.feature.desktopassist.DesktopAssistEditorUi
import com.floe.android.feature.desktopassist.DesktopAssistKinds
import com.floe.android.feature.desktopassist.DesktopAssistNotice
import com.floe.android.feature.desktopassist.DesktopAssistUiState
import com.floe.android.host.remote.C05RemoteFailure
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class C05DesktopAssistSettingsController(
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val currentNativeEpoch: () -> Long?,
    private val client: DesktopAssistHostPort = C05DesktopAssistClient(),
) : DesktopAssistActions {
    private val _state = MutableStateFlow(DesktopAssistUiState())
    val state: StateFlow<DesktopAssistUiState> = _state.asStateFlow()

    private val lock = Any()
    private var activeJob: Job? = null
    private var stopped = false
    private var loadedEpoch: Long = 0L

    fun ensureLoaded() {
        val epoch = liveEpoch() ?: return
        synchronized(lock) {
            if (stopped || loadedEpoch == epoch) return
        }
        refresh()
    }

    override fun refresh() {
        val epoch = liveEpoch() ?: run {
            _state.update { it.copy(loading = false, error = "runtimeUnavailable") }
            return
        }
        launchOperation {
            _state.update { it.copy(loading = true, error = null) }
            val cards = withContext(ioDispatcher) { client.listCards(epoch) }
            val hosts = withContext(ioDispatcher) { client.listHosts(epoch) }
            val qualified = withContext(ioDispatcher) { client.ocrStatus(epoch) }
            synchronized(lock) { loadedEpoch = epoch }
            _state.update {
                it.copy(
                    loading = false,
                    loaded = true,
                    cards = cards,
                    hosts = hosts,
                    linuxShellQualified = qualified,
                    error = null,
                )
            }
        }
    }

    override fun beginCreate() {
        synchronized(lock) {
            if (stopped || _state.value.saving) return
            _state.update {
                it.copy(
                    editor = DesktopAssistEditorUi(
                        editorID = UUID.randomUUID().toString(),
                        cardID = null,
                        label = "",
                        kind = DesktopAssistKinds.WEBSITE_PASSWORD,
                        hostID = null,
                        hasExistingSecret = false,
                        reference = null,
                    ),
                    notice = null,
                )
            }
        }
    }

    override fun beginEdit(cardID: String) {
        synchronized(lock) {
            if (stopped || _state.value.saving) return
            val card: DesktopAssistCardUi = _state.value.cards
                .firstOrNull { it.id == cardID } ?: return
            _state.update {
                it.copy(
                    editor = DesktopAssistEditorUi(
                        editorID = UUID.randomUUID().toString(),
                        cardID = card.id,
                        label = card.label,
                        kind = card.kind,
                        hostID = card.hostID,
                        hasExistingSecret = true,
                        reference = card.reference,
                    ),
                    notice = null,
                )
            }
        }
    }

    override fun dismissEditor() {
        synchronized(lock) {
            if (_state.value.saving) return
            _state.update { it.copy(editor = null) }
        }
    }

    override fun dismissNotice() {
        _state.update { it.copy(notice = null) }
    }

    override fun save(
        editorID: String,
        label: String,
        kind: String,
        hostID: String?,
        secret: String,
    ) {
        val editor = _state.value.editor?.takeIf { it.editorID == editorID } ?: return
        val trimmed = label.trim()
        val bytes = secret.toByteArray(Charsets.UTF_8)
        val keepExisting = editor.cardID != null && editor.hasExistingSecret && bytes.isEmpty()
        if (trimmed.isEmpty() || trimmed.length > 200 ||
            kind !in DesktopAssistKinds.all ||
            (!keepExisting && bytes.isEmpty()) || bytes.size > 4_096
        ) {
            bytes.fill(0)
            _state.update {
                if (it.editor?.editorID == editorID) {
                    it.copy(notice = DesktopAssistNotice.INVALID)
                } else {
                    it
                }
            }
            return
        }
        val epoch = liveEpoch()
        if (epoch == null) {
            bytes.fill(0)
            _state.update { it.copy(notice = DesktopAssistNotice.UNAVAILABLE) }
            return
        }
        val cardID = editor.cardID
        val secretText = secret
        bytes.fill(0)
        val accepted = launchOperation {
            _state.update { it.copy(saving = true, notice = null) }
            try {
                if (cardID == null) {
                    withContext(ioDispatcher) {
                        client.createCard(epoch, trimmed, kind, secretText, hostID)
                    }
                } else {
                    withContext(ioDispatcher) {
                        client.updateCard(
                            epoch = epoch,
                            id = cardID,
                            label = trimmed,
                            secret = if (keepExisting) null else secretText,
                        )
                    }
                }
                val cards = withContext(ioDispatcher) { client.listCards(epoch) }
                _state.update {
                    it.copy(
                        saving = false,
                        editor = null,
                        cards = cards,
                        notice = DesktopAssistNotice.SAVED,
                    )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: C05RemoteFailure) {
                _state.update {
                    it.copy(
                        saving = false,
                        notice = if (
                            failure.code == "invalidSecret" ||
                            failure.code == "desktopAssistCardKindInvalid" ||
                            failure.code == "desktopAssistCardLabelInvalid" ||
                            failure.code == "desktopAssistCredentialTooLarge"
                        ) {
                            DesktopAssistNotice.INVALID
                        } else {
                            DesktopAssistNotice.UNAVAILABLE
                        },
                    )
                }
            } catch (_: Exception) {
                _state.update {
                    it.copy(saving = false, notice = DesktopAssistNotice.UNAVAILABLE)
                }
            }
        }
        if (!accepted) {
            _state.update { it.copy(notice = DesktopAssistNotice.UNAVAILABLE) }
        }
    }

    override fun delete(cardID: String) {
        val epoch = liveEpoch() ?: run {
            _state.update { it.copy(notice = DesktopAssistNotice.UNAVAILABLE) }
            return
        }
        launchOperation {
            _state.update { it.copy(saving = true, notice = null) }
            try {
                withContext(ioDispatcher) { client.deleteCard(epoch, cardID) }
                val cards = withContext(ioDispatcher) { client.listCards(epoch) }
                _state.update {
                    it.copy(
                        saving = false,
                        editor = null,
                        cards = cards,
                        notice = DesktopAssistNotice.DELETED,
                    )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                _state.update {
                    it.copy(saving = false, notice = DesktopAssistNotice.UNAVAILABLE)
                }
            }
        }
    }

    private fun liveEpoch(): Long? = currentNativeEpoch()?.takeIf { it > 0 }

    private fun launchOperation(action: suspend () -> Unit): Boolean = synchronized(lock) {
        if (stopped || activeJob != null) return false
        val job = scope.launch(ioDispatcher, start = CoroutineStart.LAZY) {
            action()
        }
        activeJob = job
        job.invokeOnCompletion {
            synchronized(lock) {
                if (activeJob === job) activeJob = null
            }
        }
        job.start()
        true
    }

    internal suspend fun stop() {
        val job = synchronized(lock) {
            stopped = true
            _state.update { it.copy(editor = null, saving = false, notice = null) }
            activeJob
        }
        // A physical vault write/delete is drained, never reported cancelled
        // while it may still commit.
        job?.join()
    }
}
