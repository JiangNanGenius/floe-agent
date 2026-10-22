// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.app.Application

class RuntimeApplication : Application() {
    // Application-owned, never tied to an Activity or Binder connection.
    val kernel: RuntimeKernel by lazy { RuntimeKernel(this) }
}
