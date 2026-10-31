package com.floe.android.linuxruntime.rootfs

import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.util.Properties
import org.junit.Assert.*
import org.junit.Test

class LinuxRootfsMaterializerTest {
    private fun fixture(test: (Path, Path, Path) -> Unit) {
        val home = Files.createTempDirectory("floe-rootfs-contract-").toRealPath()
        try {
            val layer = Files.createDirectory(home.resolve("layer"))
            val base = Files.createDirectory(home.resolve("base"))
            Files.createDirectories(base.resolve("usr/bin"))
            Files.writeString(base.resolve("usr/bin/base-tool"), "base")
            test(home, layer, base)
        } finally {
            Files.walk(home).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) } }
        }
    }
    private fun plan(layer: Path, base: Path) = LinuxRootfsMaterializer.Plan("test-env", "base-1", layer.toFile(), listOf(layer.toFile(), base.toFile()))

    @Test fun publishesAtOriginalLayerAndReusesActualWrites() = fixture { _, layer, base ->
        Files.writeString(layer.resolve("manifest.json"), "authority metadata")
        Files.createDirectories(layer.resolve("usr/bin"))
        Files.writeString(layer.resolve("usr/bin/own-tool"), "override")
        val materializer = LinuxRootfsMaterializer()
        assertFalse(materializer.prepare(plan(layer, base)) { false }.reused)
        assertEquals("base", Files.readString(layer.resolve("usr/bin/base-tool")))
        assertEquals("override", Files.readString(layer.resolve("usr/bin/own-tool")))
        assertEquals("authority metadata", Files.readString(layer.resolve("manifest.json")))
        Files.delete(layer.resolve("usr/bin/base-tool"))
        assertTrue(materializer.prepare(plan(layer, base)) { false }.reused)
        assertFalse(Files.exists(layer.resolve("usr/bin/base-tool")))
    }

    @Test fun cancellationAndBudgetFailureLeaveOriginalLayer() = fixture { _, layer, base ->
        Files.writeString(layer.resolve("original"), "keep")
        assertThrows(InterruptedException::class.java) {
            LinuxRootfsMaterializer().prepare(plan(layer, base)) { true }
        }
        assertThrows(IllegalStateException::class.java) {
            LinuxRootfsMaterializer(maxBytes = 2).prepare(plan(layer, base)) { false }
        }
        assertEquals("keep", Files.readString(layer.resolve("original")))
        assertFalse(Files.exists(layer.resolve(".floe-linux-rootfs-v1")))
    }

    @Test fun preservesAbsoluteGuestSymlinkWithoutFollowingIt() = fixture { _, layer, base ->
        Files.createSymbolicLink(base.resolve("bin"), Path.of("/usr/bin"))
        LinuxRootfsMaterializer().prepare(plan(layer, base)) { false }
        assertTrue(Files.isSymbolicLink(layer.resolve("bin")))
        assertEquals(Path.of("/usr/bin"), Files.readSymbolicLink(layer.resolve("bin")))
    }

    @Test fun preservesExecutableAndStickyModes() = fixture { _, layer, base ->
        Files.setAttribute(base.resolve("usr/bin/base-tool"), "unix:mode", 0x1ED) // 0755
        Files.createDirectory(base.resolve("tmp"))
        Files.setAttribute(base.resolve("tmp"), "unix:mode", 0x3FF) // 01777
        LinuxRootfsMaterializer().prepare(plan(layer, base)) { false }
        assertEquals(0x1ED, (Files.getAttribute(layer.resolve("usr/bin/base-tool"), "unix:mode") as Int) and 0xFFF)
        assertEquals(0x3FF, (Files.getAttribute(layer.resolve("tmp"), "unix:mode") as Int) and 0xFFF)
    }

    @Test fun durabilityBarrierReceivesTheControlledStageAndRunsOnce() = fixture { _, layer, base ->
        var calls = 0
        var stageWasDirectory = false
        var stageName = ""
        var stageParent: Path? = null
        val result = LinuxRootfsMaterializer(durabilityBarrier = { stage ->
            calls++
            // Observe DURING the callback: successful publication moves the
            // stage to the registry path, so it no longer exists afterwards.
            stageWasDirectory = Files.isDirectory(stage, NOFOLLOW_LINKS)
            stageName = stage.fileName.toString()
            stageParent = stage.parent
        }).prepare(plan(layer, base)) { false }
        assertFalse(result.reused)
        assertEquals(1, calls)
        assertTrue(stageWasDirectory)
        assertTrue(stageName.startsWith(".floe-rootfs-"))
        assertTrue(stageName.endsWith(".stage"))
        assertEquals(layer.parent, stageParent)
        assertEquals("base", Files.readString(layer.resolve("usr/bin/base-tool")))
        assertTrue(Files.exists(layer.resolve(".floe-linux-rootfs-v1")))
    }

    @Test fun progressReportsCopyBarrierAndPublicationWithRealCounts() = fixture { _, layer, base ->
        val phases = mutableListOf<LinuxRootfsMaterializer.Phase>()
        val entries = mutableListOf<Long>()
        val bytes = mutableListOf<Long>()
        LinuxRootfsMaterializer(progress = { value ->
            phases.add(value.phase)
            entries.add(value.entries)
            bytes.add(value.bytes)
        }).prepare(plan(layer, base)) { false }
        assertEquals(listOf(LinuxRootfsMaterializer.Phase.COPY,
            LinuxRootfsMaterializer.Phase.COPY,
            LinuxRootfsMaterializer.Phase.BARRIER,
            LinuxRootfsMaterializer.Phase.PUBLISHED), phases)
        assertTrue(entries.last() >= 2) // base-tool + directories
        assertTrue(bytes.last() >= 4L) // "base"
        assertTrue(bytes.zipWithNext().all { (a, b) -> b >= a })
    }

    @Test fun failingDurabilityBarrierPublishesNothingAndKeepsOriginalLayer() = fixture { _, layer, base ->
        Files.writeString(layer.resolve("original"), "keep")
        val materializer = LinuxRootfsMaterializer(
            durabilityBarrier = { throw IllegalStateException("syncfs failed") })
        assertThrows(IllegalStateException::class.java) {
            materializer.prepare(plan(layer, base)) { false }
        }
        assertEquals("keep", Files.readString(layer.resolve("original")))
        assertFalse(Files.exists(layer.resolve(".floe-linux-rootfs-v1")))
        assertFalse(Files.exists(layer.resolve("usr/bin/base-tool")))
    }

    @Test fun cannotWriteThroughLowerGuestSymlink() = fixture { home, layer, base ->
        val outside = Files.createDirectory(home.resolve("outside"))
        Files.createSymbolicLink(base.resolve("escape"), outside)
        Files.createDirectories(layer.resolve("escape"))
        Files.writeString(layer.resolve("escape/inside"), "layer")
        // A higher directory replaces the link itself, never writes to its target.
        LinuxRootfsMaterializer().prepare(plan(layer, base)) { false }
        assertTrue(Files.isDirectory(layer.resolve("escape"), NOFOLLOW_LINKS))
        assertFalse(Files.exists(outside.resolve("inside")))
        assertEquals("layer", Files.readString(layer.resolve("escape/inside")))
    }

    @Test fun finalModesNeverFollowAReplacedAncestorLink() = fixture { home, layer, base ->
        Files.createDirectories(base.resolve("replace/subdir"))
        Files.setAttribute(base.resolve("replace/subdir"), "unix:mode", 0x1ED)
        val outside = Files.createDirectories(home.resolve("outside/subdir"))
        Files.setAttribute(outside, "unix:mode", 0x1C0)
        Files.createSymbolicLink(layer.resolve("replace"), outside.parent)
        LinuxRootfsMaterializer().prepare(plan(layer, base)) { false }
        assertEquals(0x1C0, (Files.getAttribute(outside, "unix:mode") as Int) and 0xFFF)
        assertTrue(Files.isSymbolicLink(layer.resolve("replace")))
    }

    @Test fun childSnapshotDoesNotResurrectDeletedParentFile() = fixture { home, parent, base ->
        val materializer = LinuxRootfsMaterializer()
        materializer.prepare(plan(parent, base)) { false }
        Files.delete(parent.resolve("usr/bin/base-tool"))
        val child = Files.createDirectory(home.resolve("child"))
        materializer.prepare(LinuxRootfsMaterializer.Plan("child", "base-1", child.toFile(),
            listOf(child.toFile(), parent.toFile(), base.toFile()))) { false }
        assertFalse(Files.exists(child.resolve("usr/bin/base-tool")))
    }

    @Test fun recoversMissingRegistryPathAfterFirstRename() = fixture { home, layer, base ->
        Files.writeString(layer.resolve("original"), "keep")
        val nonce = java.util.UUID.randomUUID().toString()
        val backup = home.resolve(".floe-rootfs-$nonce.previous")
        Files.move(layer, backup)
        Files.createDirectory(home.resolve(".floe-rootfs-$nonce.stage"))
        val properties = Properties().apply {
            setProperty("environment", "test-env"); setProperty("base", "base-1")
            setProperty("root", "layer"); setProperty("nonce", nonce)
        }
        Files.newOutputStream(home.resolve(".floe-rootfs-test-env.journal")).use { properties.store(it, null) }
        LinuxRootfsMaterializer().prepare(plan(layer, base)) { false }
        assertEquals("keep", Files.readString(layer.resolve("original")))
        assertFalse(Files.exists(backup))
    }

    @Test fun restoresMissingLayerBeforeRegistryCanReadItsManifest() = fixture { home, layer, _ ->
        Files.writeString(layer.resolve("original"), "registry-owned data")
        val nonce = java.util.UUID.randomUUID().toString()
        Files.move(layer, home.resolve(".floe-rootfs-$nonce.previous"))
        val journal = home.resolve(".floe-rootfs-layer.journal")
        val properties = Properties().apply {
            setProperty("environment", "layer"); setProperty("base", "base-1")
            setProperty("root", "layer"); setProperty("nonce", nonce)
        }
        Files.newOutputStream(journal).use { properties.store(it, null) }
        assertEquals(1, LinuxRootfsMaterializer().restoreMissingLayersBeforeRegistry(home.toFile()))
        assertEquals("registry-owned data", Files.readString(layer.resolve("original")))
        assertTrue(Files.exists(journal)) // Selected environment's prepare() owns later pruning.
    }
}
