// SPDX-License-Identifier: MPL-2.0
//
// Health Connect permission-rationale surface required by Android 14+.
// It only explains the granular read-only use; all permission requests still
// go through the system Health Connect permission contract from the System
// Services screen.

package com.floe.android.host.systemservices

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.floe.android.feature.systemservices.R

class HealthConnectRationaleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val density = resources.displayMetrics.density
        val padding = (24 * density).toInt()
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.START
            setPadding(padding, padding, padding, padding)
        }
        column.addView(
            TextView(this).apply {
                text = getString(R.string.system_services_health_rationale_title)
                textSize = 22f
            },
        )
        column.addView(
            TextView(this).apply {
                text = getString(R.string.system_services_health_rationale_body)
                textSize = 16f
                setLineSpacing(0f, 1.25f)
                setPadding(0, padding / 2, 0, 0)
            },
        )
        setContentView(ScrollView(this).apply { addView(column) })
    }
}
