// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.restart

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.UUID

internal object RestartTestSupport {
    const val NAMESPACE = "qa.restart"
    const val REFERENCE = "qa.restart.durable"
    val PAYLOAD: ByteArray = "Floe durable restart payload 2026-10-18 中文".toByteArray(StandardCharsets.UTF_8)
    val PROCESS_TOKEN: String = UUID.randomUUID().toString()

    fun phase(): String? = InstrumentationRegistry.getArguments().getString("floeRestartPhase")

    fun tokenFile(context: Context): File =
        File(File(context.noBackupFilesDir, "floe-qa-restart"), "process-token.txt")
}
