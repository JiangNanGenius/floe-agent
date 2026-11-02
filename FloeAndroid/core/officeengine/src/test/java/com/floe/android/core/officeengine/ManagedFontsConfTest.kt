package com.floe.android.core.officeengine

import org.junit.Assert.*
import org.junit.Test

class ManagedFontsConfTest {
    @Test fun preservesBuiltinDirectoriesAndEscapesPath() {
        val original = "<fontconfig><dir>/system/fonts</dir></fontconfig>"
        val next = OfficePayloadBootstrap.withManagedFonts(original, "/data/floe/a&b")
        assertTrue(next.contains("<dir>/system/fonts</dir>"))
        assertTrue(next.contains("<dir>/data/floe/a&amp;b</dir>"))
    }
    @Test fun replacesPreviousSnapshotWithoutAccumulatingInactiveFonts() {
        val first = OfficePayloadBootstrap.withManagedFonts("<fontconfig></fontconfig>", "/data/fonts/old")
        val next = OfficePayloadBootstrap.withManagedFonts(first, "/data/fonts/new")
        assertFalse(next.contains("/data/fonts/old"))
        assertTrue(next.contains("/data/fonts/new"))
    }
    @Test fun refusesBrokenExistingManagedBlock() {
        assertThrows(IllegalArgumentException::class.java) {
            OfficePayloadBootstrap.withManagedFonts("<fontconfig><!-- Floe managed fonts begin --></fontconfig>", "/data/fonts")
        }
    }
}
