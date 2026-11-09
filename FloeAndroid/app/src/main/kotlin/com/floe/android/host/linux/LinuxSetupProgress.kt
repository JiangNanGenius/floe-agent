// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

/** Presentation of real install counters; never an overall synthetic completion percentage. */
enum class LinuxSetupStage {
    COMPONENT_FILE, COMPONENT_INSTALL, PREFLIGHT, DOWNLOAD, VERIFY, EXTRACT, PUBLISH, CONFIGURE;
    companion object {
        fun fromWire(value: String): LinuxSetupStage = when (value) {
            "download" -> DOWNLOAD
            "verify_archive" -> VERIFY
            "extract" -> EXTRACT
            "publish" -> PUBLISH
            "configure" -> CONFIGURE
            else -> PREFLIGHT
        }
    }
}

data class LinuxSetupProgress(
    val stage: LinuxSetupStage,
    val bytes: Long,
    val total: Long,
    val entries: Long = 0,
    val extractedBytes: Long = 0,
    val bytesPerSecond: Long? = null,
) {
    val transfer: Boolean get() = stage == LinuxSetupStage.DOWNLOAD || stage == LinuxSetupStage.COMPONENT_FILE
    val percent: Int? get() = if (transfer && total > 0)
        ((bytes.toDouble() / total) * 100).toInt().coerceIn(0, 100) else null
}

/** Five-second measured rate, reset on stage changes/restarts; no wall-clock dependence. */
internal class LinuxSetupProgressMeter {
    private data class Sample(val time: Long, val bytes: Long)
    private var stage: LinuxSetupStage? = null
    private val samples = ArrayDeque<Sample>()
    fun sample(next: LinuxSetupStage, bytes: Long, total: Long, now: Long,
        entries: Long = 0, extractedBytes: Long = 0): LinuxSetupProgress {
        val done = bytes.coerceAtLeast(0)
        if (stage != next || samples.lastOrNull()?.let { now < it.time || done < it.bytes } == true) {
            samples.clear(); stage = next
        }
        val transfer = next == LinuxSetupStage.DOWNLOAD || next == LinuxSetupStage.COMPONENT_FILE
        if (!transfer) samples.clear()
        else {
            if (samples.lastOrNull()?.time == now) samples.removeLast()
            samples.addLast(Sample(now, done))
            while (samples.size > 2 && now - samples.elementAt(1).time >= 5_000) samples.removeFirst()
            while (samples.size > 32) samples.removeFirst()
        }
        val first = samples.firstOrNull()
        val rate = first?.takeIf { now - it.time >= 500 }?.let {
            (((done - it.bytes).toDouble() * 1_000) / (now - it.time)).toLong().coerceAtLeast(0)
        }
        return LinuxSetupProgress(next, done, total.takeIf { it > 0 } ?: -1,
            entries.coerceAtLeast(0), extractedBytes.coerceAtLeast(0), rate)
    }
}
