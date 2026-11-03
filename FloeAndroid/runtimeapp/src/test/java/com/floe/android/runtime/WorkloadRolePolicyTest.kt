// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import com.floe.android.linuxruntime.supervision.WorkloadAdmission
import org.junit.Assert.assertEquals
import org.junit.Test

/** Original PipeJobPolicy role assertions, in their real declaring module. */
class WorkloadRolePolicyTest {
    @Test fun `the concurrent pool includes both service slots and one shared execution slot`() {
        assertEquals(5, WorkloadAdmission.concurrent.maxConcurrent)
        assertEquals(2, WorkloadRole.SERVICE.maximumConcurrent)
        assertEquals(3, WorkloadRole.entries
            .filter { it != WorkloadRole.SERVICE }
            .sumOf { it.maximumConcurrent } - 1) // Agent + Run share one slot
    }
}
