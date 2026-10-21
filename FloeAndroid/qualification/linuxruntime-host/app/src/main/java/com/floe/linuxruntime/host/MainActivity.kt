// SPDX-License-Identifier: MPL-2.0
//
// Minimal qualification host UI. All self-tests run on a background thread;
// the final structured report is written to both internal files and the
// app-specific external directory so Main can `adb pull` it without run-as.

package com.floe.linuxruntime.host

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.File

class MainActivity : Activity() {

    private lateinit var logView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        val runButton = Button(this).apply { text = "Run Linux-runtime self-test" }
        logView = TextView(this).apply {
            textSize = 12f
            setPadding(24, 16, 24, 16)
        }
        val scroll = ScrollView(this).apply { addView(logView) }
        root.addView(runButton)
        root.addView(
            scroll,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            ),
        )
        setContentView(root)

        runButton.setOnClickListener {
            runButton.isEnabled = false
            logView.text = ""
            appendLine("self-test started on ${java.util.Date()}")
            Thread {
                val runner = SelfTestRunner(this)
                val report = runner.runAll(linuxOnly = intent.getStringExtra("scope") == "linux") { line ->
                    runOnUiThread { appendLine(line) }
                }
                val internal = File(filesDir, "selftest-report.json")
                val external = File(getExternalFilesDir(null), "selftest-report.json")
                internal.writeText(report.toString(2))
                external.parentFile?.mkdirs()
                external.writeText(report.toString(2))
                runOnUiThread {
                    appendLine("REPORT(internal): ${internal.absolutePath}")
                    appendLine("REPORT(external): ${external.absolutePath}")
                    appendLine("self-test finished")
                    runButton.isEnabled = true
                }
            }.apply { isDaemon = true }.start()
        }
        // Fixed, local-only qualification. This flag never accepts a command,
        // path or arbitrary code and does not unlock or alter the device.
        if (savedInstanceState == null && intent.getBooleanExtra("autorun", false)) {
            runButton.performClick()
        }
    }

    private fun appendLine(line: String) {
        logView.append(line + "\n")
    }
}
