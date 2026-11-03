// SPDX-License-Identifier: MPL-2.0
//
// C03 App-owned voice coordinator.
//
// It is the ONE owner of the system recognizer, the system TTS engine, the
// additive Swift `floe.voice/7` client and the retained read-aloud/transcription
// coroutines. Construction is data-only. System engines are created on the
// main thread; all cloud work runs on the host IO dispatcher and is cancelled
// by explicit user stop, foreground loss, conversation retirement, root
// retirement and epoch replacement.
//
// No provider secret, auth header, model URL or raw audio ever enters this
// class. Cloud selection is a non-secret provider/model pair; the Swift domain
// resolves the existing provider secret reference at call time.
package com.floe.android.host.voice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

enum class C03StartOutcome {
    ACCEPTED,
    PERMISSION_REQUIRED,
    BUSY,
    UNAVAILABLE,
    INVALID_OWNER,
}

interface C03DictationSink {
    fun onPartial(text: String)
    fun onFinal(text: String)
    fun onFailure(failure: C03VoiceFailure)
    fun onCancelled()
}

/** Bounded sentence-aware text splitter; never drops authored text. */
internal object C03TextChunker {
    fun split(text: String, maxCharacters: Int = 1_800): List<String> {
        val clean = text.replace("\r\n", "\n").trim()
        if (clean.isEmpty()) return emptyList()
        if (clean.length <= maxCharacters) return listOf(clean)
        val result = ArrayList<String>()
        val current = StringBuilder()
        fun flush() {
            val value = current.toString().trim()
            if (value.isNotEmpty()) result += value
            current.setLength(0)
        }
        var index = 0
        while (index < clean.length) {
            val character = clean[index]
            current.append(character)
            val boundary = character == '\n' ||
                character == '。' || character == '！' || character == '？' ||
                character == '!' || character == '?' ||
                (character == '.' && (index + 1 >= clean.length ||
                    clean[index + 1].isWhitespace() || clean[index + 1] == '\n'))
            if (boundary && current.length >= maxCharacters / 2) flush()
            if (current.length >= maxCharacters) {
                val snapshot = current.toString()
                val lastSpace = snapshot.lastIndexOf(' ')
                if (lastSpace >= maxCharacters / 2) {
                    val remainder = snapshot.substring(lastSpace + 1)
                    current.setLength(0)
                    current.append(snapshot.substring(0, lastSpace))
                    flush()
                    current.append(remainder)
                } else {
                    flush()
                }
            }
            index++
        }
        flush()
        return if (result.isEmpty()) listOf(clean) else result
    }
}

class C03VoiceHost(
    private val context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val currentEpoch: () -> Long?,
    private val transport: C03VoiceTransport = SwiftC03VoiceTransport,
) {
    private val appContext = context.applicationContext
    private val legacySettings by lazy { C03LegacyVoiceSettingsReader(appContext) }
    private val cloud = C03CloudSpeechClient(transport, ioDispatcher)
    private val recognizer = C03SystemSpeechRecognizer(appContext)
    private var settingsRevision = 0L
    private val stateLock = Any()
    private val _state = MutableStateFlow(C03VoiceSnapshot())
    val state: StateFlow<C03VoiceSnapshot> = _state
    private val _permissionRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val permissionRequests: SharedFlow<Unit> = _permissionRequests
    private val _transcription = MutableStateFlow<C03TranscriptionState>(C03TranscriptionState.Idle)
    val transcription: StateFlow<C03TranscriptionState> = _transcription

    private var started = false
    private var loadJob: Job? = null
    private var capabilityJob: Job? = null
    private var settingsApplyJob: Job? = null
    private var dictationSink: C03DictationSink? = null
    private var dictationOwner: C03VoiceOwner? = null
    private var dictationEpoch = 0L
    private var pendingPermissionOwner: C03VoiceOwner? = null
    private var dictationResetJob: Job? = null
    private var cloudDictationJob: Job? = null
    private var cloudRecorder: C03CloudMicrophoneRecorder? = null
    private var cloudUtteranceStaging: C03UtteranceStaging? = null
    private var cloudUtteranceOperation: String? = null
    private var cloudStopRequested = false

    private var outputJob: Job? = null
    private var outputOwner: C03VoiceOwner? = null
    private var outputGeneration = 0L
    private var currentSynthesisOperation: String? = null
    private var systemChunks: List<String> = emptyList()
    private var systemChunkIndex = 0
    private var cloudChunks: List<String> = emptyList()
    private var cloudChunkIndex = 0
    private var cloudPlayer: C03CloudAudioPlayer? = null

    private var transcriptionJob: Job? = null
    private var currentTranscriptionOperation: String? = null
    private var activeTranscriptionContext: C03MediaProjectContext? = null
    private var activeTranscriptionStaging: String? = null
    private var activeChunker: C03AudioChunker? = null

    private val systemTts = C03SystemTextToSpeech(appContext) { availability, engine, voices ->
        update { current ->
            current.copy(
                ttsAvailability = availability,
                ttsEngineName = engine,
                systemVoices = voices,
            )
        }
    }

    fun start() {
        if (started) return
        started = true
        systemTts.initialize()
        refreshPermission()
        reloadSettings()
    }

    /** A new accepted root generation re-reads canonical settings. */
    fun onRootChanged() {
        if (!started) return
        cancelDictation(notify = true)
        cancelTranscription()
        stopSpeaking()
        reloadSettings()
    }

    private fun reloadSettings() {
        loadJob?.cancel()
        loadJob = scope.launch(ioDispatcher) {
            val epoch = currentEpoch()
            val canonical = try {
                cloud.loadSettings(epoch)
            } catch (_: C03VoiceFailure) {
                null
            }
            val canonicalSettings = canonical?.settings
            if (canonical != null && canonical.found) {
                if (canonical.unreadable || canonicalSettings == null) {
                    // Preserve an unreadable canonical row byte-for-byte. No
                    // automatic migration or save is allowed to overwrite it.
                    settingsRevision = canonical.revision
                    update { current ->
                        current.copy(
                            settings = C03VoiceSettings.DEFAULT,
                            settingsUnreadable = true,
                        )
                    }
                } else {
                    val loaded = requireNotNull(canonicalSettings)
                    settingsRevision = canonical.revision
                    update { current ->
                        current.copy(
                            settings = loaded,
                            settingsUnreadable = false,
                        )
                    }
                }
                configureSystemTts()
                refreshCapabilities()
                return@launch
            }
            // Canonical row absent (or the core is not installed yet). A
            // present legacy document is adopted ONLY when it decodes fully.
            val legacy = runCatching { legacySettings.load() }.getOrNull()
            val legacySettingsValue = legacy?.settings
            if (legacySettingsValue != null && epoch != null) {
                try {
                    val saved = cloud.saveSettings(legacySettingsValue, 0L, epoch)
                    settingsRevision = saved.revision
                    update { current ->
                        current.copy(settings = saved.settings, settingsUnreadable = false)
                    }
                    configureSystemTts()
                    refreshCapabilities()
                    return@launch
                } catch (failure: C03VoiceFailure) {
                    update { current ->
                        current.copy(lastError = failure)
                    }
                }
            }
            if (legacySettingsValue != null) {
                // Canonical persistence is not live yet; keep the decoded
                // choice in RAM only, never in a second persistent registry.
                update { current ->
                    current.copy(settings = legacySettingsValue, settingsUnreadable = false)
                }
            } else {
                update { current ->
                    current.copy(
                        settings = C03VoiceSettings.DEFAULT,
                        settingsUnreadable = legacy?.unreadable == true,
                    )
                }
            }
            configureSystemTts()
            refreshCapabilities()
        }
    }

    /** App foreground is REAL MainActivity resume/pause, never a guessed flag. */
    fun onAppForegroundChanged(active: Boolean) {
        if (!active) {
            cancelDictation(notify = true)
            stopSpeaking()
        }
        refreshPermission()
    }

    fun refreshPermission() {
        val granted = if (Build.VERSION.SDK_INT >= 23) {
            appContext.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        update { current ->
            current.copy(
                recognizerAvailable = recognizer.isAvailable(),
                microphonePermissionGranted = granted,
            )
        }
    }

    fun onMicrophonePermissionResult(granted: Boolean) {
        refreshPermission()
        val owner = pendingPermissionOwner
        pendingPermissionOwner = null
        if (!granted) {
            update { current ->
                current.copy(
                    dictation = C03DictationState.PERMISSION_REQUIRED,
                    lastError = C03VoiceFailure(
                        C03VoiceErrorCode.PERMISSION_REQUIRED,
                        "microphonePermissionDenied",
                    ),
                )
            }
            dictationSink?.onFailure(
                C03VoiceFailure(C03VoiceErrorCode.PERMISSION_REQUIRED, "microphonePermissionDenied"),
            )
            dictationSink = null
            return
        }
        if (owner != null && dictationSink != null && state.value.dictation ==
            C03DictationState.PERMISSION_REQUIRED
        ) {
            startDictation(owner, dictationSink!!)
        }
    }

    fun updateSettings(transform: (C03VoiceSettings) -> C03VoiceSettings) {
        if (state.value.settingsUnreadable) {
            // Never overwrite a document we could not read or a future schema.
            update { current ->
                current.copy(
                    lastError = C03VoiceFailure(
                        C03VoiceErrorCode.INVALID_SELECTION,
                        "settingsUnreadable",
                    ),
                )
            }
            return
        }
        val next = transform(state.value.settings).normalized()
        update { current -> current.copy(settings = next, lastError = null) }
        settingsApplyJob?.cancel()
        settingsApplyJob = scope.launch(ioDispatcher) {
            delay(250L)
            val epoch = currentEpoch()
            if (epoch == null) {
                update { current ->
                    current.copy(
                        lastError = C03VoiceFailure(
                            C03VoiceErrorCode.CORE_UNAVAILABLE,
                            "rootRetired",
                            retryable = true,
                        ),
                    )
                }
                return@launch
            }
            try {
                val saved = cloud.saveSettings(next, settingsRevision, epoch)
                settingsRevision = saved.revision
                update { current ->
                    current.copy(settings = saved.settings, settingsUnreadable = false)
                }
                configureSystemTts()
                refreshCapabilities()
            } catch (failure: C03VoiceFailure) {
                update { current -> current.copy(lastError = failure) }
                if (failure.code == C03VoiceErrorCode.STALE_REVISION) {
                    // The canonical row is authoritative; re-read it instead
                    // of retrying a blind overwrite.
                    reloadSettings()
                }
            }
        }
    }

    fun requestMicrophonePermission() {
        _permissionRequests.tryEmit(Unit)
    }

    fun startDictation(owner: C03VoiceOwner, sink: C03DictationSink): C03StartOutcome {
        val epoch = currentEpoch() ?: 0L
        if (epoch <= 0L) {
            return C03StartOutcome.UNAVAILABLE
        }
        if (state.value.dictation == C03DictationState.LISTENING ||
            state.value.dictation == C03DictationState.FINALIZING
        ) {
            return C03StartOutcome.BUSY
        }
        if (!state.value.microphonePermissionGranted) {
            pendingPermissionOwner = owner
            dictationSink = sink
            update { current ->
                current.copy(
                    dictation = C03DictationState.PERMISSION_REQUIRED,
                    lastError = null,
                )
            }
            requestMicrophonePermission()
            return C03StartOutcome.PERMISSION_REQUIRED
        }
        val settings = state.value.settings.normalized()
        val rejection = C03VoiceInputGate.rejection(
            settings = settings,
            owner = owner,
            microphoneGranted = true,
            capabilities = state.value.capabilities,
        )
        if (rejection != null) {
            update { current ->
                current.copy(
                    dictation = C03DictationState.FAILED,
                    lastError = rejection,
                )
            }
            sink.onFailure(rejection)
            scheduleDictationReset()
            return if (rejection.code == C03VoiceErrorCode.INVALID_SELECTION) {
                C03StartOutcome.INVALID_OWNER
            } else {
                C03StartOutcome.UNAVAILABLE
            }
        }
        dictationOwner = owner
        dictationEpoch = epoch
        dictationSink = sink
        dictationResetJob?.cancel()
        cloudStopRequested = false
        update { current ->
            current.copy(
                dictation = C03DictationState.LISTENING,
                partialText = "",
                lastError = null,
            )
        }
        return when (settings.inputEngine) {
            C03VoiceEngine.SYSTEM -> startSystemDictation(epoch)
            C03VoiceEngine.CLOUD -> startCloudDictation(epoch, owner)
        }
    }

    private fun startSystemDictation(epoch: Long): C03StartOutcome {
        val started = recognizer.start(
            languageTag = state.value.settings.inputLanguage,
            partialResults = true,
            listener = object : C03DictationListener {
                override fun onListening() = Unit

                override fun onPartial(text: String) {
                    if (!isCurrentDictation(epoch)) return
                    update { current -> current.copy(partialText = text.take(4_000)) }
                    dictationSink?.onPartial(text)
                }

                override fun onFinal(text: String) {
                    if (!isCurrentDictation(epoch)) {
                        update { current -> current.copy(dictation = C03DictationState.CANCELLED) }
                        dictationSink?.onCancelled()
                        scheduleDictationReset()
                        return
                    }
                    update { current ->
                        current.copy(
                            dictation = C03DictationState.COMPLETED,
                            partialText = text,
                            lastError = null,
                        )
                    }
                    dictationSink?.onFinal(text)
                    scheduleDictationReset()
                }

                override fun onFailure(failure: C03VoiceFailure) {
                    if (!isCurrentDictation(epoch)) return
                    update { current ->
                        current.copy(
                            dictation = C03DictationState.FAILED,
                            lastError = failure,
                        )
                    }
                    dictationSink?.onFailure(failure)
                    scheduleDictationReset()
                }

                override fun onCancelled() {
                    if (!isCurrentDictation(epoch)) return
                    update { current ->
                        current.copy(dictation = C03DictationState.CANCELLED)
                    }
                    dictationSink?.onCancelled()
                    scheduleDictationReset()
                }
            },
        )
        if (!started) {
            // The adapter already delivered exactly one typed onFailure for
            // this real start failure; do not emit a duplicate terminal.
            return C03StartOutcome.UNAVAILABLE
        }
        return C03StartOutcome.ACCEPTED
    }

    private fun startCloudDictation(
        epoch: Long,
        owner: C03VoiceOwner,
    ): C03StartOutcome {
        cloudDictationJob?.cancel()
        cloudDictationJob = scope.launch(ioDispatcher) {
            var staging: C03UtteranceStaging? = null
            var utteranceOperation: String? = null
            try {
                val begin = cloud.beginUtterance(owner, epoch)
                staging = begin
                cloudUtteranceStaging = begin
                val recorder = C03CloudMicrophoneRecorder(appContext)
                cloudRecorder = recorder
                if (cloudStopRequested) recorder.stop()
                recorder.capture(begin.path)
                if (!isCurrentDictation(epoch)) return@launch
                update { current -> current.copy(dictation = C03DictationState.FINALIZING) }
                val settings = state.value.settings
                val operation = cloud.startUtterance(
                    staging = begin,
                    selection = settings.cloudInput,
                    language = settings.cloudInput.language ?: settings.inputLanguage,
                    owner = owner,
                    epoch = epoch,
                )
                utteranceOperation = operation
                cloudUtteranceOperation = operation
                val text = awaitUtteranceText(operation, epoch)
                if (!isCurrentDictation(epoch)) return@launch
                if (text.isBlank()) {
                    throw C03VoiceFailure(C03VoiceErrorCode.EMPTY_TRANSCRIPT, "emptyTranscript")
                }
                update { current ->
                    current.copy(
                        dictation = C03DictationState.COMPLETED,
                        partialText = text.take(8_000),
                        lastError = null,
                    )
                }
                dictationSink?.onFinal(text)
                scheduleDictationReset()
            } catch (cancelled: CancellationException) {
                if (isCurrentDictation(epoch)) {
                    update { current -> current.copy(dictation = C03DictationState.CANCELLED) }
                    dictationSink?.onCancelled()
                    scheduleDictationReset()
                }
                throw cancelled
            } catch (failure: C03VoiceFailure) {
                if (isCurrentDictation(epoch)) {
                    update { current ->
                        current.copy(
                            dictation = C03DictationState.FAILED,
                            lastError = failure,
                        )
                    }
                    dictationSink?.onFailure(failure)
                    scheduleDictationReset()
                }
            } finally {
                cloudRecorder = null
                if (cloudUtteranceStaging === staging) cloudUtteranceStaging = null
                if (cloudUtteranceOperation == utteranceOperation) {
                    cloudUtteranceOperation = null
                }
                staging?.path?.let { path -> runCatching { java.io.File(path).delete() } }
            }
        }
        return C03StartOutcome.ACCEPTED
    }

    private suspend fun awaitUtteranceText(operation: String, epoch: Long): String {
        val deadline = System.currentTimeMillis() + UTTERANCE_TIMEOUT_MILLIS
        while (System.currentTimeMillis() < deadline) {
            if (!isCurrentDictation(epoch)) {
                throw CancellationException("superseded")
            }
            val status = cloud.transcriptionStatus(operation)
            when (status.state) {
                C03CloudOperationState.RUNNING -> delay(150L)
                C03CloudOperationState.COMPLETED ->
                    return cloud.transcriptionText(operation)
                C03CloudOperationState.CANCELLED ->
                    throw C03VoiceFailure(C03VoiceErrorCode.CANCELLED, "cancelled")
                C03CloudOperationState.FAILED ->
                    throw status.failure ?: C03VoiceFailure(
                        C03VoiceErrorCode.PROVIDER_REJECTED,
                        "utteranceFailed",
                    )
            }
        }
        runCatching { cloud.cancelTranscription(operation) }
        throw C03VoiceFailure(C03VoiceErrorCode.TIMEOUT, "utteranceTimeout", retryable = true)
    }

    private fun isCurrentDictation(epoch: Long): Boolean =
        dictationEpoch == epoch &&
            currentEpoch() == epoch &&
            state.value.dictation != C03DictationState.CANCELLED

    fun stopDictation() {
        if (state.value.dictation != C03DictationState.LISTENING) return
        update { current -> current.copy(dictation = C03DictationState.FINALIZING) }
        if (state.value.settings.inputEngine == C03VoiceEngine.CLOUD) {
            cloudStopRequested = true
            cloudRecorder?.stop()
        } else {
            recognizer.stop()
        }
    }

    fun cancelDictation(notify: Boolean = true) {
        if (state.value.dictation == C03DictationState.LISTENING ||
            state.value.dictation == C03DictationState.FINALIZING ||
            state.value.dictation == C03DictationState.PERMISSION_REQUIRED
        ) {
            val sink = dictationSink
            dictationSink = null
            dictationOwner = null
            dictationEpoch = 0L
            pendingPermissionOwner = null
            dictationResetJob?.cancel()
            recognizer.cancel()
            cloudRecorder?.cancel()
            cloudRecorder = null
            cloudDictationJob?.cancel()
            cloudDictationJob = null
            cloudStopRequested = false
            val operation = cloudUtteranceOperation
            cloudUtteranceOperation = null
            if (operation != null) {
                scope.launch(ioDispatcher) {
                    runCatching { cloud.cancelTranscription(operation) }
                }
            }
            cloudUtteranceStaging?.path?.let { path ->
                runCatching { java.io.File(path).delete() }
            }
            cloudUtteranceStaging = null
            update { current -> current.copy(dictation = C03DictationState.CANCELLED) }
            if (notify) sink?.onCancelled()
        }
    }

    fun cancelForConversation(conversationID: String) {
        if (dictationOwner?.conversationID == conversationID) cancelDictation(notify = true)
        if (outputOwner?.conversationID == conversationID) stopSpeaking()
    }

    fun speak(text: String, owner: C03VoiceOwner): Boolean {
        val clean = text.trim()
        if (clean.isEmpty()) return false
        if (currentEpoch() == null) return false
        val settings = state.value.settings.normalized()
        when (settings.outputEngine) {
            C03VoiceEngine.SYSTEM -> {
                if (state.value.ttsAvailability != C03TtsAvailability.READY) {
                    update { current ->
                        current.copy(
                            output = C03SpeechOutputState.FAILED,
                            lastError = C03VoiceFailure(
                                C03VoiceErrorCode.UNCONFIGURED,
                                "systemTtsUnavailable",
                            ),
                        )
                    }
                    return false
                }
                val chunks = C03TextChunker.split(clean, 3_500)
                if (chunks.isEmpty()) return false
                stopSpeaking()
                outputOwner = owner
                outputGeneration++
                systemChunks = chunks
                systemChunkIndex = 0
                update { current ->
                    current.copy(
                        output = C03SpeechOutputState.PREPARING,
                        lastError = null,
                    )
                }
                return speakNextSystemChunk(outputGeneration)
            }
            C03VoiceEngine.CLOUD -> {
                val selection = settings.cloudOutput
                if (!state.value.capabilities.cloudReady || !selection.configured) {
                    update { current ->
                        current.copy(
                            output = C03SpeechOutputState.FAILED,
                            lastError = C03VoiceFailure(
                                C03VoiceErrorCode.UNCONFIGURED,
                                "cloudTtsNotConfigured",
                            ),
                        )
                    }
                    return false
                }
                if (state.value.capabilities.choiceFor(selection)?.credentialConfigured != true) {
                    update { current ->
                        current.copy(
                            output = C03SpeechOutputState.FAILED,
                            lastError = C03VoiceFailure(
                                C03VoiceErrorCode.CREDENTIAL_MISSING,
                                "cloudTtsCredentialMissing",
                            ),
                        )
                    }
                    return false
                }
                val chunks = C03TextChunker.split(clean, state.value.capabilities.maxTextCharacters)
                if (chunks.isEmpty()) return false
                stopSpeaking()
                val generation = ++outputGeneration
                outputOwner = owner
                cloudChunks = chunks
                cloudChunkIndex = 0
                update { current ->
                    current.copy(
                        output = C03SpeechOutputState.PREPARING,
                        lastError = null,
                    )
                }
                outputJob = scope.launch { runCloudReadAloud(generation, owner) }
                return true
            }
        }
    }

    fun stopSpeaking() {
        outputGeneration++
        outputJob?.cancel()
        outputJob = null
        systemChunks = emptyList()
        cloudChunks = emptyList()
        val operation = currentSynthesisOperation
        currentSynthesisOperation = null
        if (operation != null) {
            scope.launch(ioDispatcher) {
                runCatching { cloud.cancelSynthesis(operation) }
            }
        }
        systemTts.stop()
        cloudPlayer?.let { player ->
            scope.launch(Dispatchers.Main.immediate) { player.stop() }
        }
        cloudPlayer = null
        outputOwner = null
        update { current ->
            if (current.output == C03SpeechOutputState.PREPARING ||
                current.output == C03SpeechOutputState.SPEAKING
            ) {
                current.copy(output = C03SpeechOutputState.CANCELLED)
            } else {
                current
            }
        }
    }

    private fun speakNextSystemChunk(generation: Long): Boolean {
        if (generation != outputGeneration) return false
        val chunk = systemChunks.getOrNull(systemChunkIndex) ?: run {
            update { current -> current.copy(output = C03SpeechOutputState.COMPLETED) }
            outputOwner = null
            return true
        }
        val settings = state.value.settings
        val configured = configureSystemTts()
        if (configured != null) {
            update { current ->
                current.copy(
                    output = C03SpeechOutputState.FAILED,
                    lastError = configured,
                )
            }
            return false
        }
        val result = systemTts.speak(
            text = chunk,
            rate = settings.rate,
            pitchSemitones = settings.pitch,
            listener = object : C03TtsListener {
                override fun onStarted(utteranceID: String) {
                    if (generation == outputGeneration) {
                        update { current -> current.copy(output = C03SpeechOutputState.SPEAKING) }
                    }
                }

                override fun onCompleted(utteranceID: String) {
                    if (generation != outputGeneration) return
                    systemChunkIndex++
                    speakNextSystemChunk(generation)
                }

                override fun onFailed(utteranceID: String, failure: C03VoiceFailure) {
                    if (generation != outputGeneration) return
                    update { current ->
                        current.copy(
                            output = C03SpeechOutputState.FAILED,
                            lastError = failure,
                        )
                    }
                    outputOwner = null
                }

                override fun onCancelled(utteranceID: String) {
                    if (generation != outputGeneration) return
                    update { current -> current.copy(output = C03SpeechOutputState.CANCELLED) }
                    outputOwner = null
                }
            },
        )
        return when (result) {
            is C03TtsSpeakResult.Started -> true
            is C03TtsSpeakResult.Failure -> {
                update { current ->
                    current.copy(
                        output = C03SpeechOutputState.FAILED,
                        lastError = result.failure,
                    )
                }
                false
            }
        }
    }

    private suspend fun runCloudReadAloud(generation: Long, owner: C03VoiceOwner) {
        try {
            while (true) {
                if (generation != outputGeneration) return
                val chunk = cloudChunks.getOrNull(cloudChunkIndex) ?: break
                val operation = cloud.startSynthesis(
                    text = chunk,
                    selection = state.value.settings.cloudOutput,
                    owner = owner,
                )
                currentSynthesisOperation = operation
                val status = pollSynthesis(operation, generation)
                if (status.state != C03CloudOperationState.COMPLETED) {
                    throw status.failure ?: C03VoiceFailure(
                        C03VoiceErrorCode.PROVIDER_REJECTED,
                        "ttsNotCompleted",
                    )
                }
                currentSynthesisOperation = null
                val path = status.audioPath
                    ?: throw C03VoiceFailure(C03VoiceErrorCode.INVALID_RESPONSE, "missingAudio")
                val player = withContext(Dispatchers.Main.immediate) {
                    C03CloudAudioPlayer(appContext)
                }
                cloudPlayer = player
                update { current -> current.copy(output = C03SpeechOutputState.PREPARING) }
                withContext(Dispatchers.Main.immediate) {
                    player.play(path) {
                        if (generation == outputGeneration) {
                            update { current -> current.copy(output = C03SpeechOutputState.SPEAKING) }
                        }
                    }
                }
                if (generation != outputGeneration) return
                cloudPlayer = null
                scope.launch(ioDispatcher) { cloud.releaseSynthesis(operation) }
                cloudChunkIndex++
            }
            if (generation == outputGeneration) {
                update { current -> current.copy(output = C03SpeechOutputState.COMPLETED) }
                outputOwner = null
            }
        } catch (cancelled: CancellationException) {
            if (generation == outputGeneration) {
                update { current -> current.copy(output = C03SpeechOutputState.CANCELLED) }
            }
            throw cancelled
        } catch (failure: C03VoiceFailure) {
            if (generation == outputGeneration) {
                update { current ->
                    current.copy(
                        output = C03SpeechOutputState.FAILED,
                        lastError = failure,
                    )
                }
                outputOwner = null
            }
        } catch (_: Throwable) {
            if (generation == outputGeneration) {
                update { current ->
                    current.copy(
                        output = C03SpeechOutputState.FAILED,
                        lastError = C03VoiceFailure(
                            C03VoiceErrorCode.INTERNAL,
                            "ttsPlaybackFailed",
                        ),
                    )
                }
                outputOwner = null
            }
        }
    }

    private suspend fun pollSynthesis(operation: String, generation: Long): C03TtsStatus {
        val deadline = System.currentTimeMillis() + SYNTHESIS_TIMEOUT_MILLIS
        while (System.currentTimeMillis() < deadline) {
            if (generation != outputGeneration) throw CancellationException("superseded")
            val status = cloud.synthesisStatus(operation)
            when (status.state) {
                C03CloudOperationState.RUNNING -> {
                    delay(150L)
                }
                else -> return status
            }
        }
        runCatching { cloud.cancelSynthesis(operation) }
        return C03TtsStatus(
            state = C03CloudOperationState.FAILED,
            progress = 0.0,
            audioPath = null,
            sampleRate = state.value.capabilities.ttsSampleRate,
            durationSeconds = null,
            failure = C03VoiceFailure(C03VoiceErrorCode.TIMEOUT, "ttsTimeout", retryable = true),
        )
    }

    suspend fun transcribeAndWrite(
        projectID: String,
        sessionToken: String,
        storageKind: String,
        workspaceID: String?,
        originKind: String?,
        originOwnerID: String?,
        originEnvironmentID: String?,
        expectedRevision: Long,
        assetID: String,
    ): C03SubtitleReceipt {
        val settings = state.value.settings.normalized()
        if (!settings.transcriptionConfigured) {
            throw C03VoiceFailure(C03VoiceErrorCode.UNCONFIGURED, "transcriptionNotConfigured")
        }
        val epoch = currentEpoch() ?: throw C03VoiceFailure(
            C03VoiceErrorCode.CORE_UNAVAILABLE,
            "rootNotLive",
            retryable = true,
        )
        val media = C03MediaProjectContext(
            projectID = projectID,
            sessionToken = sessionToken,
            storageKind = storageKind,
            workspaceID = workspaceID,
            originKind = originKind,
            originOwnerID = originOwnerID,
            originEnvironmentID = originEnvironmentID,
            expectedRevision = expectedRevision,
            assetID = assetID,
        )
        val selection = C03CloudVoiceSelection(
            providerID = settings.transcriptionProviderID,
            modelID = settings.transcriptionModelID,
            language = settings.transcriptionLanguage,
        )
        val owner = C03VoiceOwner(
            taskID = originOwnerID,
            environmentID = originEnvironmentID,
            projectID = projectID,
        )
        val plan = try {
            cloud.planTranscription(
                media = media,
                selection = selection,
                language = settings.transcriptionLanguage,
                owner = owner,
                epoch = epoch,
            )
        } catch (failure: C03VoiceFailure) {
            _transcription.value = C03TranscriptionState.Failed(failure)
            throw failure
        }
        activeTranscriptionContext = media
        activeTranscriptionStaging = plan.stagingPath
        currentTranscriptionOperation = plan.operationID
        _transcription.value = C03TranscriptionState.Running(0.0)
        val chunker = C03AudioChunker()
        activeChunker = chunker
        val operation = plan.operationID
        try {
            val budgetMillis = transcriptionBudgetMillis(plan.estimatedChunks)
            val segmentCount = withTimeoutOrNull(budgetMillis) {
                var chunkCount = 0
                chunker.extract(
                    sourcePath = plan.sourcePath,
                    stagingPath = plan.stagingPath,
                    chunkLimitBytes = plan.chunkLimitBytes,
                ) { chunk ->
                    chunkCount = chunk.index + 1
                    cloud.applyChunk(
                        operationID = operation,
                        chunkIndex = chunk.index,
                        sourceStartSeconds = chunk.sourceStartSeconds,
                        sourceDurationSeconds = chunk.durationSeconds,
                        sampleRate = chunk.sampleRate,
                        channels = chunk.channels,
                    )
                    val estimated = plan.estimatedChunks.coerceAtLeast(chunkCount)
                    _transcription.value = C03TranscriptionState.Running(
                        (chunkCount.toDouble() / estimated.toDouble()).coerceIn(0.0, 0.95),
                    )
                }
                cloud.finishTranscription(
                    operationID = operation,
                    totalChunks = chunkCount,
                    sourceDurationSeconds = plan.durationSeconds,
                )
            } ?: throw C03VoiceFailure(
                C03VoiceErrorCode.TIMEOUT,
                "transcriptionTimeout",
                retryable = true,
            )
            if (segmentCount <= 0) {
                throw C03VoiceFailure(C03VoiceErrorCode.EMPTY_TRANSCRIPT, "emptyTranscript")
            }
            val receipt = cloud.writeSubtitles(
                operationID = operation,
                media = media,
                expectedRevision = expectedRevision,
                replaceTranscribed = settings.replaceTranscribedCaptions,
            )
            _transcription.value = C03TranscriptionState.Completed(receipt)
            return receipt
        } catch (cancelled: CancellationException) {
            chunker.cancel()
            runCatching { cloud.cancelTranscription(operation) }
            _transcription.value = C03TranscriptionState.Cancelled
            throw cancelled
        } catch (failure: C03VoiceFailure) {
            chunker.cancel()
            runCatching { cloud.cancelTranscription(operation) }
            _transcription.value = C03TranscriptionState.Failed(failure)
            throw failure
        } finally {
            if (activeChunker === chunker) activeChunker = null
            if (currentTranscriptionOperation == operation) {
                currentTranscriptionOperation = null
                activeTranscriptionContext = null
            }
            if (activeTranscriptionStaging == plan.stagingPath) {
                activeTranscriptionStaging = null
            }
            runCatching { java.io.File(plan.stagingPath).deleteRecursively() }
        }
    }

    private fun transcriptionBudgetMillis(estimatedChunks: Int): Long =
        (15L * 60L * 1_000L + estimatedChunks.toLong() * 4L * 60L * 1_000L)
            .coerceAtMost(6L * 60L * 60L * 1_000L)

    fun cancelTranscription() {
        val operation = currentTranscriptionOperation
        currentTranscriptionOperation = null
        activeTranscriptionContext = null
        activeChunker?.cancel()
        activeChunker = null
        val staging = activeTranscriptionStaging
        activeTranscriptionStaging = null
        _transcription.value = C03TranscriptionState.Cancelled
        if (operation != null) {
            scope.launch(ioDispatcher) { runCatching { cloud.cancelTranscription(operation) } }
        }
        staging?.let { path -> runCatching { java.io.File(path).deleteRecursively() } }
    }

    private suspend fun readAllSegments(operation: String): List<C03TimedSegment> {
        val result = ArrayList<C03TimedSegment>()
        var offset = 0
        val limit = 200
        val max = state.value.capabilities.maxSegments
        while (offset < max) {
            val page = cloud.transcriptionPage(operation, offset, minOf(limit, max - offset))
            if (page.segments.isEmpty()) break
            result += page.segments
            val previousOffset = offset
            offset = page.nextOffset
            if (offset <= previousOffset) break
            if (result.size >= max) break
        }
        return result.take(max)
    }

    suspend fun prepareForRootStop(): Boolean {
        cancelDictation(notify = true)
        withContext(Dispatchers.Main.immediate) {
            stopSpeaking()
            recognizer.destroy()
            systemTts.shutdown()
        }
        cancelTranscription()
        // A false result (bridge timeout/unavailable core) is an honest
        // pending drain: the native actor still owns the provider task and
        // staging, so the root stop keeps this generation and can retry after
        // the task really settles. An absent/older v7 channel has no v7
        // operation to drain and reports true below.
        return cloud.cancelAll()
    }

    fun shutdown() {
        cancelDictation(notify = true)
        stopSpeaking()
        cancelTranscription()
        scope.launch(ioDispatcher) { runCatching { cloud.cancelAll() } }
        scope.launch(Dispatchers.Main.immediate) {
            recognizer.destroy()
            systemTts.shutdown()
        }
    }

    private fun configureSystemTts(): C03VoiceFailure? = runCatching {
        val settings = state.value.settings
        systemTts.configure(settings.systemVoiceLocale ?: settings.inputLanguage, settings.systemVoiceName)
    }.getOrElse { null }

    private fun scheduleDictationReset() {
        dictationResetJob?.cancel()
        dictationResetJob = scope.launch {
            delay(350L)
            val current = state.value.dictation
            if (current == C03DictationState.COMPLETED ||
                current == C03DictationState.FAILED ||
                current == C03DictationState.CANCELLED
            ) {
                update { value ->
                    value.copy(dictation = C03DictationState.IDLE, partialText = "")
                }
                dictationOwner = null
                dictationSink = null
                dictationEpoch = 0L
            }
        }
    }

    private fun update(transform: (C03VoiceSnapshot) -> C03VoiceSnapshot) {
        synchronized(stateLock) {
            _state.value = transform(_state.value)
        }
    }

    private suspend fun refreshCapabilities() {
        if (!started) return
        try {
            val capabilities = cloud.capabilities()
            update { current ->
                current.copy(
                    capabilities = capabilities,
                    coreVersion = C03CloudSpeechClient.VERSION,
                )
            }
        } catch (failure: C03VoiceFailure) {
            update { current ->
                current.copy(
                    capabilities = C03VoiceCapabilities(
                        cloudReady = false,
                        transportReady = false,
                        needsCoreUpdate = failure.code == C03VoiceErrorCode.NEEDS_CORE_UPDATE,
                    ),
                )
            }
        }
    }

    companion object {
        const val SYNTHESIS_TIMEOUT_MILLIS = 180_000L
        const val TRANSCRIPTION_TIMEOUT_MILLIS = 15L * 60L * 1_000L
        const val UTTERANCE_TIMEOUT_MILLIS = 120_000L
    }
}
