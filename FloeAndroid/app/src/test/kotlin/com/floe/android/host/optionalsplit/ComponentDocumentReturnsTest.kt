// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.optionalsplit

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class ComponentDocumentReturnsTest {
    private val first = "00000000-0000-0000-0000-000000000001"
    private val second = "00000000-0000-0000-0000-000000000002"
    private val task = "10000000-0000-0000-0000-000000000001"
    private val workspace = "20000000-0000-0000-0000-000000000001"
    private fun fixture(body: (File) -> Unit) {
        val root = Files.createTempDirectory("floe-component-return-").toFile()
        try { body(root) } finally { root.deleteRecursively() }
    }
    private fun store(root: File, process: String = first) = ComponentDocumentReturns(root, 65, process) { 1000 }

    @Test fun installationRestartReturnsOnlyToFreshlyRevalidatedWorkspace() = fixture { root ->
        val initial = store(root)
        initial.prepare("cadpreview", task, workspace, "example.stl")
        initial.arm("cadpreview", 42)
        assertNull(initial.candidate { true })
        val restarted = store(root, second)
        val record = requireNotNull(restarted.candidate { it == "cadpreview" })
        assertTrue(restarted.beginRestore(record))
        assertFalse(restarted.consume(record, task, second))
        assertTrue(restarted.isCurrent(record.id))
        assertTrue(restarted.consume(record, task, workspace))
        assertNull(store(root).candidate { true })
    }

    @Test fun explicitNavigationClearsPersistedAndInFlightReturn() = fixture { root ->
        val userFile = File(root, "user.stl").apply { writeText("USER") }
        val initial = store(root)
        initial.prepare("cadpreview", task, workspace, "user.stl")
        initial.arm("cadpreview", 42)
        val restarted = store(root, second)
        val record = requireNotNull(restarted.candidate { true })
        restarted.beginRestore(record)
        restarted.clear()
        assertFalse(restarted.consume(record, task, workspace))
        assertNull(store(root).candidate { true })
        assertEquals("USER", userFile.readText())
    }

    @Test fun oldSessionCancellationCannotDisarmNewDocument() = fixture { root ->
        val initial = store(root)
        initial.prepare("cadpreview", task, workspace, "old.stl")
        initial.arm("cadpreview", 42)
        initial.prepare("cadpreview", task, workspace, "new.stl")
        initial.arm("cadpreview", 43)
        initial.disarm("cadpreview", 42)
        assertEquals("new.stl", store(root, second).candidate { true }?.path)
        initial.disarm("cadpreview", 43)
        assertNull(store(root, second).candidate { true })
    }

    @Test fun settingsInstallAndDeadCancelledPreparationCannotReviveADocument() = fixture { root ->
        store(root).arm("officepreview", 42)
        assertNull(store(root, second).candidate { true })
        val initial = store(root)
        initial.prepare("officepreview", task, workspace, "example.docx")
        val restarted = store(root, second)
        restarted.arm("officepreview", 43)
        assertNull(restarted.candidate { true })
        assertNull(store(root).candidate { true })
    }

    @Test fun newSelectionFencesPreviouslyAdmittedReturn() = fixture { root ->
        val initial = store(root)
        initial.prepare("cadpreview", task, workspace, "old.stl")
        initial.arm("cadpreview", 42)
        val restarted = store(root, second)
        val old = requireNotNull(restarted.candidate { true })
        restarted.prepare("officepreview", task, workspace, "new.docx")
        assertFalse(restarted.beginRestore(old))
        restarted.discard(old.id)
        restarted.arm("officepreview", 43)
        assertEquals("new.docx", store(root).candidate { true }?.path)
    }
}
