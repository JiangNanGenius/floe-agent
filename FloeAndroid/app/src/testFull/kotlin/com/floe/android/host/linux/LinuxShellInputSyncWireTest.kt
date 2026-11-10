// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import com.floe.android.runtimeipc.RuntimeWire
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class LinuxShellInputSyncWireTest {
    @Test fun liveResourceRequestCrossesTheClosedWireAndRetainsCoreIdentities() {
        val project = "AAAAAAAA-0000-0000-0000-000000000001"
        val run = "BBBBBBBB-0000-0000-0000-000000000002"
        val payload = JSONObject().put("projectID", project).put("runID", run)
        // This is the actual caller's operation token, not a mock transport.
        val encoded = RuntimeWire.encode("workspace.syncInputs", payload)
        val request = RuntimeWire.decode(encoded)
        assertEquals("workspace.syncInputs", request.operation)
        assertEquals(project to run, LinuxShellPump.syncInputsRequest(request.payload, 7))
    }
}
