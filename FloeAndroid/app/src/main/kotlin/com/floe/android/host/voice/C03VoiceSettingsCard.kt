// SPDX-License-Identifier: MPL-2.0
@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)

package com.floe.android.host.voice

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeChoiceOption
import com.floe.android.design.FloeFormChoiceField
import com.floe.android.design.FloeFormTextField
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSwitchRow
import com.floe.android.design.FloeText
import com.floe.android.design.FloeValueRow
import io.github.robinpcrd.cupertino.section.SectionItem

/**
 * Reachable Settings surface. The host is the Application-owned coordinator;
 * null is an honest unavailable state (never a fake local engine).
 *
 * All mutable text fields are non-secret. The API key is never shown or
 * edited here: selecting an existing configured provider/model is the only
 * cloud setup step, and its credential is resolved by the native domain.
 */
@Composable
fun C03VoiceSettingsCard(
    host: C03VoiceHost?,
    modifier: Modifier = Modifier,
) {
    if (host == null) {
        FloeSettingsSectionCard(C03Strings.t("Voice", "语音"), modifier) {
            SectionItem(title = {
                FloeText(
                    C03Strings.t(
                        "Voice is unavailable until the App runtime is ready.",
                        "应用运行时就绪后可使用语音功能。",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            })
        }
        return
    }
    val snapshot by host.state.collectAsState()
    val settings = snapshot.settings
    var ttsExpanded by remember { mutableStateOf(false) }
    var systemVoiceExpanded by remember { mutableStateOf(false) }
    var asrExpanded by remember { mutableStateOf(false) }
    var cloudInputExpanded by remember { mutableStateOf(false) }
    var cloudInputLanguageDraft by remember(settings.cloudInput.language) {
        mutableStateOf(settings.cloudInput.language.orEmpty())
    }
    var voiceDraft by remember(settings.cloudOutput.providerID, settings.cloudOutput.modelID) {
        mutableStateOf(settings.cloudOutput.voiceID)
    }
    var languageDraft by remember(settings.cloudOutput.language) {
        mutableStateOf(settings.cloudOutput.language.orEmpty())
    }
    var transcriptionLanguageDraft by remember(settings.transcriptionLanguage) {
        mutableStateOf(settings.transcriptionLanguage.orEmpty())
    }

    FloeSettingsSectionCard(C03Strings.t("Voice", "语音"), modifier) {
        SectionItem(title = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(
                    C03Strings.t("Input", "输入"),
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.label,
                )
                FloeSegmented(
                    options = listOf(
                        C03Strings.t("System", "系统"),
                        C03Strings.t("Cloud", "云端"),
                    ),
                    selectedIndex = if (settings.inputEngine == C03VoiceEngine.CLOUD) 1 else 0,
                    onSelect = { index ->
                        host.updateSettings {
                            it.copy(
                                inputEngine = if (index == 1) {
                                    C03VoiceEngine.CLOUD
                                } else {
                                    C03VoiceEngine.SYSTEM
                                },
                            )
                        }
                    },
                )
            }
        })

        when (settings.inputEngine) {
            C03VoiceEngine.SYSTEM -> {
                FloeValueRow(
                    C03Strings.t("Recognition", "识别"),
                    if (snapshot.recognizerAvailable) {
                        C03Strings.t("System recognizer available", "系统识别可用")
                    } else {
                        C03Strings.t("No system recognizer", "无系统识别服务")
                    },
                )
            }
            C03VoiceEngine.CLOUD -> {
                if (!snapshot.capabilities.cloudReady) {
                    FloeValueRow(
                        C03Strings.t("Cloud status", "云端状态"),
                        if (snapshot.capabilities.needsCoreUpdate) {
                            C03Strings.t("App core update required", "需要更新应用核心")
                        } else {
                            C03Strings.t("Configure a provider first", "请先配置提供商")
                        },
                    )
                }
                val inputModels = snapshot.capabilities.asrModels
                if (inputModels.isEmpty()) {
                    FloeValueRow(
                        C03Strings.t("Cloud model", "云端模型"),
                        C03Strings.t("No configured model", "尚无已配置模型"),
                    )
                } else {
                    FloeFormChoiceField(
                        label = C03Strings.t("Cloud model", "云端模型"),
                        options = inputModels.map {
                            FloeChoiceOption(
                                it.key,
                                "${it.providerName} · ${it.displayName.ifBlank { it.remoteModelID }}",
                            )
                        },
                        selectedKey = settings.cloudInput
                            .takeIf { it.configured }
                            ?.let { "${it.providerID}|${it.modelID}" },
                        expanded = cloudInputExpanded,
                        onExpandedChange = { cloudInputExpanded = it },
                        enabled = snapshot.capabilities.cloudReady,
                        onSelect = { key ->
                            val choice = inputModels.firstOrNull { it.key == key }
                            if (choice != null) {
                                host.updateSettings {
                                    it.copy(
                                        cloudInput = it.cloudInput.copy(
                                            providerID = choice.providerID,
                                            modelID = choice.modelID,
                                        ),
                                    )
                                }
                            }
                        },
                    )
                }
                if (settings.cloudInput.configured) {
                    FloeValueRow(
                        C03Strings.t("Credential", "凭据"),
                        if (snapshot.cloudInputCredentialReady) {
                            C03Strings.t("Configured", "已配置")
                        } else {
                            C03Strings.t("Missing for this model", "此模型缺少凭据")
                        },
                    )
                }
                FloeFormTextField(
                    label = C03Strings.t("Language hint (optional)", "语言提示（可选）"),
                    value = cloudInputLanguageDraft,
                    onValueChange = {
                        cloudInputLanguageDraft = it.take(64)
                        host.updateSettings { current ->
                            current.copy(
                                cloudInput = current.cloudInput.copy(
                                    language = cloudInputLanguageDraft
                                        .takeIf { value -> value.isNotBlank() },
                                ),
                            )
                        }
                    },
                    enabled = snapshot.capabilities.cloudReady,
                )
                FloeText(
                    C03Strings.t(
                        "Records one short utterance, then transcribes it. It is not a continuous stream.",
                        "只录制一段短语音后转写，不会持续监听。",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        FloeValueRow(
            C03Strings.t("Microphone", "麦克风"),
            if (snapshot.microphonePermissionGranted) {
                C03Strings.t("Allowed", "已允许")
            } else {
                C03Strings.t("Not allowed", "未允许")
            },
            onClick = if (!snapshot.microphonePermissionGranted) {
                { host.requestMicrophonePermission() }
            } else {
                null
            },
        )

        SectionItem(title = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(
                    C03Strings.t("Output", "朗读"),
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.label,
                )
                FloeSegmented(
                    options = listOf(
                        C03Strings.t("System", "系统"),
                        C03Strings.t("Cloud", "云端"),
                    ),
                    selectedIndex = if (settings.outputEngine == C03VoiceEngine.CLOUD) 1 else 0,
                    onSelect = { index ->
                        host.updateSettings {
                            it.copy(
                                outputEngine = if (index == 1) {
                                    C03VoiceEngine.CLOUD
                                } else {
                                    C03VoiceEngine.SYSTEM
                                },
                            )
                        }
                    },
                )
            }
        })

        when (settings.outputEngine) {
            C03VoiceEngine.SYSTEM -> {
                FloeValueRow(
                    C03Strings.t("Engine status", "引擎状态"),
                    C03Strings.ttsStatus(snapshot.ttsAvailability),
                )
                if (snapshot.ttsEngineName != null) {
                    FloeValueRow(
                        C03Strings.t("Installed engine", "已安装引擎"),
                        snapshot.ttsEngineName.orEmpty().take(80),
                    )
                }
                if (snapshot.ttsAvailability == C03TtsAvailability.SERVICE_MISSING ||
                    snapshot.ttsAvailability == C03TtsAvailability.INIT_FAILED ||
                    snapshot.ttsAvailability == C03TtsAvailability.UNCONFIGURED
                ) {
                    FloeValueRow(
                        C03Strings.t("Action", "操作"),
                        C03Strings.t(
                            "Install or configure a system TTS engine in Android settings.",
                            "请在 Android 设置中安装或配置系统语音引擎。",
                        ),
                    )
                }
                val voices = snapshot.systemVoices
                if (voices.isEmpty()) {
                    FloeValueRow(
                        C03Strings.t("System voice", "系统声音"),
                        C03Strings.t("Engine default", "引擎默认"),
                    )
                } else {
                    FloeFormChoiceField(
                        label = C03Strings.t("System voice", "系统声音"),
                        options = voices.map {
                            FloeChoiceOption(it.name, "${it.displayName} · ${it.locale}")
                        },
                        selectedKey = settings.systemVoiceName,
                        expanded = systemVoiceExpanded,
                        onExpandedChange = { systemVoiceExpanded = it },
                        enabled = snapshot.ttsAvailability == C03TtsAvailability.READY,
                        onSelect = { name ->
                            val voice = voices.firstOrNull { it.name == name }
                            host.updateSettings {
                                it.copy(
                                    systemVoiceName = name,
                                    systemVoiceLocale = voice?.locale,
                                )
                            }
                        },
                    )
                }
                FloeSegmented(
                    options = listOf("0.75×", "1.0×", "1.25×", "1.5×"),
                    selectedIndex = rateIndex(settings.rate),
                    onSelect = { index ->
                        host.updateSettings { it.copy(rate = RATES[index]) }
                    },
                )
                FloeSegmented(
                    options = listOf(
                        C03Strings.t("Low", "低"),
                        C03Strings.t("Normal", "标准"),
                        C03Strings.t("High", "高"),
                    ),
                    selectedIndex = pitchIndex(settings.pitch),
                    onSelect = { index ->
                        host.updateSettings { it.copy(pitch = PITCHES[index]) }
                    },
                )
            }
            C03VoiceEngine.CLOUD -> {
                if (!snapshot.capabilities.cloudReady) {
                    FloeValueRow(
                        C03Strings.t("Cloud status", "云端状态"),
                        if (snapshot.capabilities.needsCoreUpdate) {
                            C03Strings.t("App core update required", "需要更新应用核心")
                        } else {
                            C03Strings.t("Configure a provider first", "请先配置提供商")
                        },
                    )
                }
                if (settings.cloudOutput.configured) {
                    FloeValueRow(
                        C03Strings.t("Credential", "凭据"),
                        if (snapshot.cloudOutputCredentialReady) {
                            C03Strings.t("Configured", "已配置")
                        } else {
                            C03Strings.t("Missing for this model", "此模型缺少凭据")
                        },
                    )
                }
                val ttsModels = snapshot.capabilities.ttsModels
                if (ttsModels.isEmpty()) {
                    FloeValueRow(
                        C03Strings.t("Cloud voice", "云端声音"),
                        C03Strings.t("No configured model", "尚无已配置模型"),
                    )
                } else {
                    FloeFormChoiceField(
                        label = C03Strings.t("Cloud model", "云端模型"),
                        options = ttsModels.map {
                            FloeChoiceOption(
                                it.key,
                                "${it.providerName} · ${it.displayName.ifBlank { it.remoteModelID }}",
                            )
                        },
                        selectedKey = settings.cloudOutput
                            .takeIf { it.configured }
                            ?.let { "${it.providerID}|${it.modelID}" },
                        expanded = ttsExpanded,
                        onExpandedChange = { ttsExpanded = it },
                        enabled = snapshot.capabilities.cloudReady,
                        onSelect = { key ->
                            val choice = ttsModels.firstOrNull { it.key == key }
                            if (choice != null) {
                                host.updateSettings {
                                    it.copy(
                                        cloudOutput = it.cloudOutput.copy(
                                            providerID = choice.providerID,
                                            modelID = choice.modelID,
                                        ),
                                    )
                                }
                            }
                        },
                    )
                }
                FloeFormTextField(
                    label = C03Strings.t("Voice ID", "声音 ID"),
                    value = voiceDraft,
                    onValueChange = {
                        voiceDraft = it.take(200)
                        host.updateSettings { current ->
                            current.copy(cloudOutput = current.cloudOutput.copy(voiceID = voiceDraft))
                        }
                    },
                    enabled = snapshot.capabilities.cloudReady,
                )
                FloeFormTextField(
                    label = C03Strings.t("Language hint (optional)", "语言提示（可选）"),
                    value = languageDraft,
                    onValueChange = {
                        languageDraft = it.take(64)
                        host.updateSettings { current ->
                            current.copy(
                                cloudOutput = current.cloudOutput.copy(
                                    language = languageDraft.takeIf { value -> value.isNotBlank() },
                                ),
                            )
                        }
                    },
                    enabled = snapshot.capabilities.cloudReady,
                )
                FloeSegmented(
                    options = listOf("0.75×", "1.0×", "1.25×", "1.5×"),
                    selectedIndex = rateIndex(settings.cloudOutput.rate),
                    onSelect = { index ->
                        host.updateSettings {
                            it.copy(
                                rate = RATES[index],
                                cloudOutput = it.cloudOutput.copy(rate = RATES[index]),
                            )
                        }
                    },
                )
                SectionItem(title = {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeCapsuleAction(
                            C03Strings.t("Test voice", "测试声音"),
                            onClick = {
                                host.speak(
                                    C03Strings.t(
                                        "This is a Floe voice test.",
                                        "这是 Floe 语音测试。",
                                    ),
                                    C03VoiceOwner(),
                                )
                            },
                            enabled = snapshot.capabilities.cloudReady &&
                                settings.cloudOutput.configured &&
                                settings.cloudOutput.voiceID.isNotBlank(),
                        )
                        if (snapshot.output == C03SpeechOutputState.PREPARING ||
                            snapshot.output == C03SpeechOutputState.SPEAKING
                        ) {
                            FloeActivityIndicator()
                        }
                        FloeCapsuleAction(
                            C03Strings.t("Stop", "停止"),
                            onClick = { host.stopSpeaking() },
                            enabled = snapshot.output == C03SpeechOutputState.PREPARING ||
                                snapshot.output == C03SpeechOutputState.SPEAKING,
                        )
                    }
                })
            }
        }

        FloeText(
            C03Strings.t("Media transcription", "媒体转写"),
            style = Floe.typography.bodyEmphasized,
            color = Floe.colors.label,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
        )
        val asrModels = snapshot.capabilities.asrModels
        if (asrModels.isEmpty()) {
            FloeValueRow(
                C03Strings.t("Transcription model", "转写模型"),
                C03Strings.t("No configured model", "尚无已配置模型"),
            )
        } else {
            FloeFormChoiceField(
                label = C03Strings.t("Transcription model", "转写模型"),
                options = asrModels.map {
                    FloeChoiceOption(
                        it.key,
                        "${it.providerName} · ${it.displayName.ifBlank { it.remoteModelID }}",
                    )
                },
                selectedKey = if (!settings.transcriptionProviderID.isNullOrBlank() &&
                    !settings.transcriptionModelID.isNullOrBlank()
                ) {
                    "${settings.transcriptionProviderID}|${settings.transcriptionModelID}"
                } else {
                    null
                },
                expanded = asrExpanded,
                onExpandedChange = { asrExpanded = it },
                enabled = snapshot.capabilities.cloudReady,
                onSelect = { key ->
                    val choice = asrModels.firstOrNull { it.key == key }
                    if (choice != null) {
                        host.updateSettings {
                            it.copy(
                                transcriptionProviderID = choice.providerID,
                                transcriptionModelID = choice.modelID,
                            )
                        }
                    }
                },
            )
        }
        FloeFormTextField(
            label = C03Strings.t("Transcription language (optional)", "转写语言（可选）"),
            value = transcriptionLanguageDraft,
            onValueChange = {
                transcriptionLanguageDraft = it.take(64)
                host.updateSettings { current ->
                    current.copy(
                        transcriptionLanguage = transcriptionLanguageDraft
                            .takeIf { value -> value.isNotBlank() },
                    )
                }
            },
            enabled = snapshot.capabilities.cloudReady,
        )
        FloeSwitchRow(
            title = C03Strings.t(
                "Replace previous transcribed captions",
                "替换此前的自动转写字幕",
            ),
            checked = settings.replaceTranscribedCaptions,
            onCheckedChange = { checked ->
                host.updateSettings { it.copy(replaceTranscribedCaptions = checked) }
            },
            caption = C03Strings.t(
                "Manual captions are always preserved.",
                "手动添加的字幕始终保留。",
            ),
        )
        FloeValueRow(
            C03Strings.t("Chunk limit", "分片上限"),
            "${snapshot.capabilities.maxChunkBytes / (1024L * 1024L)} MiB",
        )
        FloeText(
            C03Strings.t(
                "Long audio is decoded into sequential PCM16 WAV chunks; each upload stays below the provider limit. The system recognizer is never used for long files.",
                "长音频会解码为连续的 PCM16 WAV 分片，每次上传都低于提供商上限；长文件不会使用系统识别器。",
            ),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
        )

        snapshot.lastError?.let { failure ->
            FloeValueRow(
                C03Strings.t("Last issue", "最近问题"),
                C03Strings.error(failure),
            )
        }
        if (snapshot.settingsUnreadable) {
            FloeValueRow(
                C03Strings.t("Settings", "设置"),
                C03Strings.t(
                    "Saved voice settings could not be read. Defaults are shown; the old data is preserved and will not be overwritten.",
                    "已保存的语音设置无法读取。当前显示默认值；旧数据会保留且不会被覆盖。",
                ),
            )
        }
    }
}

private fun rateIndex(rate: Double): Int {
    val value = if (rate.isFinite()) rate else 1.0
    return RATES.indices.minByOrNull { kotlin.math.abs(RATES[it] - value) } ?: 1
}

private fun pitchIndex(pitch: Double): Int {
    val value = if (pitch.isFinite()) pitch else 0.0
    return PITCHES.indices.minByOrNull { kotlin.math.abs(PITCHES[it] - value) } ?: 1
}

private val RATES = doubleArrayOf(0.75, 1.0, 1.25, 1.5)
private val PITCHES = doubleArrayOf(-3.0, 0.0, 3.0)

/** Bounded bilingual copy helper until Main adds shared string resources. */
internal object C03Strings {
    fun t(english: String, chinese: String): String =
        if (C03Locale.isChinese()) chinese else english

    fun ttsStatus(value: C03TtsAvailability): String = when (value) {
        C03TtsAvailability.READY -> t("Ready", "就绪")
        C03TtsAvailability.SERVICE_MISSING -> t("No TTS service installed", "未安装语音引擎")
        C03TtsAvailability.INIT_FAILED -> t("TTS initialization failed", "语音引擎初始化失败")
        C03TtsAvailability.MISSING_VOICE -> t("Voice not installed", "声音未安装")
        C03TtsAvailability.UNCONFIGURED -> t("Language data missing", "缺少语言数据")
        C03TtsAvailability.FAILURE -> t("Engine failure", "引擎故障")
        C03TtsAvailability.UNINITIALIZED -> t("Starting", "正在启动")
    }

    fun error(failure: C03VoiceFailure): String = when (failure.code) {
        C03VoiceErrorCode.PERMISSION_REQUIRED ->
            t("Microphone permission is required.", "需要麦克风权限。")
        C03VoiceErrorCode.UNCONFIGURED ->
            t("Choose a configured model first.", "请先选择已配置的模型。")
        C03VoiceErrorCode.CREDENTIAL_MISSING ->
            t("The selected provider has no saved credential.", "所选提供商尚未保存凭据。")
        C03VoiceErrorCode.TRANSPORT_UNAVAILABLE ->
            t("Cloud transport is not available yet.", "云端传输尚不可用。")
        C03VoiceErrorCode.AUTHENTICATION ->
            t("The provider rejected the saved credential.", "提供商拒绝了已保存的凭据。")
        C03VoiceErrorCode.QUOTA_OR_RATE_LIMITED ->
            t("The provider quota or rate limit was reached.", "已达到提供商配额或速率限制。")
        C03VoiceErrorCode.NETWORK ->
            t("The network request failed.", "网络请求失败。")
        C03VoiceErrorCode.CANCELLED ->
            t("Cancelled.", "已取消。")
        C03VoiceErrorCode.STALE_REVISION ->
            t("The project changed. Reload it before trying again.", "项目已更改，请重新加载后再试。")
        C03VoiceErrorCode.SESSION_REQUIRED ->
            t("The media editor session ended.", "媒体编辑会话已结束。")
        C03VoiceErrorCode.FILE_TOO_LARGE ->
            t(
                "The audio exceeds the bounded transcoding limit.",
                "音频超出受限的转码上限。",
            )
        C03VoiceErrorCode.UNSUPPORTED_MEDIA ->
            t("This media file has no supported audio.", "该媒体文件没有受支持的音频。")
        C03VoiceErrorCode.CODEC_UNAVAILABLE ->
            t("This device cannot decode the audio track.", "此设备无法解码该音轨。")
        C03VoiceErrorCode.NEEDS_TIMING ->
            t(
                "The provider returned text without real segment timing; no subtitles were written.",
                "提供商只返回文本，没有真实分段计时；未写入字幕。",
            )
        C03VoiceErrorCode.EMPTY_TRANSCRIPT ->
            t("No speech was recognized.", "未识别到语音。")
        C03VoiceErrorCode.TIMEOUT ->
            t("The request timed out.", "请求超时。")
        C03VoiceErrorCode.NEEDS_CORE_UPDATE ->
            t("Update the App core to use cloud speech.", "请更新应用核心以使用云端语音。")
        C03VoiceErrorCode.INVALID_SELECTION ->
            t("The selected voice or language is not usable.", "所选声音或语言不可用。")
        else -> t("The voice request could not be completed.", "语音请求未能完成。")
    }
}
