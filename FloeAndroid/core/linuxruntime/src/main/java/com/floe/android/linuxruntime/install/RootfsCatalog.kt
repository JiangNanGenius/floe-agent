// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

/**
 * Fixed, reviewed rootfs sources. There are deliberately NO caller/model
 * supplied URLs or hashes: the service selects a catalog entry by ID and the
 * entry itself carries the HTTPS URL, SHA-256 pin, expected top prefix and
 * every budget. Adding a source means adding a reviewed constant here.
 */

enum class DeviceNodePolicy {
    /**
     * Character/block/FIFO members are counted in the stats and NOT
     * materialized: the launcher binds a runtime /dev. The counts still flow
     * into the manifest so nothing disappears silently.
     */
    EXCLUDE_AND_COUNT,

    /** Any device/FIFO member aborts the installation. */
    REJECT,
}

data class RootfsCatalogEntry(
    val catalogId: String,
    val version: String,
    val displayName: String,
    val archiveFileName: String,
    val httpsUrl: String,
    val archiveSha256: String,
    val knownArchiveBytes: Long,
    val maxArchiveBytes: Long,
    val maxEntryBytes: Long,
    val maxTotalExtractBytes: Long,
    val maxEntries: Long,
    val maxMetadataRecords: Long,
    val maxMetadataRecordBytes: Long,
    /**
     * Single required leading path component of every member (proot-distro
     * images store content under one top directory; upstream tooling strips
     * exactly 1 component). "" accepts flat archives.
     */
    val expectedTopPrefix: String,
    val deviceNodePolicy: DeviceNodePolicy,
    val minRegularFiles: Long,
    val minDirectories: Long,
    val minSymbolicLinks: Long,
    /**
     * Linux distribution rootfs archives (case-sensitive guest semantics)
     * must not be extracted onto a case-insensitive host volume: distinct
     * members collide there. True adds a cheap destination probe before any
     * content lands.
     */
    val requiresCaseSensitiveDestination: Boolean = false,
) {
    init {
        fun clean(s: String): Boolean =
            s.isNotEmpty() && !s.contains('/') && !s.contains("..") &&
            !s.any { it == Char(0) }
        require(clean(catalogId)) { "catalogId must be a clean path-safe component" }
        require(clean(version)) { "version must be explicit" }
        require(clean(archiveFileName)) { "archiveFileName must be a clean component" }
        require(httpsUrl.startsWith("https://")) { "rootfs sources are HTTPS-only" }
        require(!httpsUrl.any { it == Char(0) }) { "NUL in URL" }
        require(archiveSha256.matches(SHA256_HEX)) { "archiveSha256 must be 64 lowercase hex" }
        require(knownArchiveBytes in 1..maxArchiveBytes) { "archive budget below known size" }
        require(maxEntryBytes in 1..maxTotalExtractBytes) { "member budget above total budget" }
        require(maxEntries > 0 && maxMetadataRecords > 0) { "record budgets must be positive" }
        require(maxMetadataRecordBytes > 0) { "metadata record budget must be positive" }
        require(expectedTopPrefix.isEmpty() || clean(expectedTopPrefix)) {
            "expectedTopPrefix must be empty or one clean component"
        }
        require(minRegularFiles >= 0 && minDirectories >= 0 && minSymbolicLinks >= 0)
        require(minRegularFiles + minDirectories + minSymbolicLinks <= maxEntries) {
            "minimum content counts must fit inside the entry budget"
        }
    }

    companion object {
        private val SHA256_HEX = Regex("[0-9a-f]{64}")
    }
}


/**
 * The only sources this build ships. Every value below is a reviewed constant.
 *
 * Debian bookworm aarch64, proot-distro v4.7.0 image: the canonical GitHub
 * release asset URL returned 42,894,344 bytes whose SHA-256 equals the R1
 * pin on 2026-10-22 (verified live; the same archive bytes the R1 device
 * qualification used - see r1/backend/SOURCE_READY.json debianRootfs pin).
 * Budgets derive from the measured archive: 10,206 members (1,161
 * directories, 1,023 symlinks, 8 character devices, 8,014 regular files,
 * zero hardlinks), 221,379,155 file bytes, largest member 4,523,291 bytes,
 * a pax extended header on every member. Limits keep real headroom while
 * staying hard-bounded; minimums guard against silently short content.
 */
object FloeRootfsCatalog {

    val debianBookwormAarch64PdV470: RootfsCatalogEntry = RootfsCatalogEntry(
        catalogId = "floe-linux-debian-bookworm-aarch64-pd-v4.7.0",
        version = "bookworm-pd-v4.7.0",
        displayName = "Debian (bookworm, aarch64)",
        archiveFileName = "debian-bookworm-aarch64-pd-v4.7.0.tar.xz",
        httpsUrl = "https://github.com/termux/proot-distro/releases/download/v4.7.0/" +
            "debian-bookworm-aarch64-pd-v4.7.0.tar.xz",
        archiveSha256 = "4baa32280cc70b67e2c650777c1d974349f0cdf23afaabc305ad3bc6182b8df8",
        knownArchiveBytes = 42_894_344,
        maxArchiveBytes = 64L * 1024 * 1024,
        maxEntryBytes = 64L * 1024 * 1024,
        maxTotalExtractBytes = 512L * 1024 * 1024,
        maxEntries = 65_536,
        maxMetadataRecords = 131_072,
        maxMetadataRecordBytes = 64L * 1024,
        expectedTopPrefix = "debian-bookworm-aarch64",
        deviceNodePolicy = DeviceNodePolicy.EXCLUDE_AND_COUNT,
        minRegularFiles = 7_000,
        minDirectories = 1_000,
        minSymbolicLinks = 900,
        requiresCaseSensitiveDestination = true,
    )

    val entries: List<RootfsCatalogEntry> = listOf(debianBookwormAarch64PdV470)

    fun byCatalogId(catalogId: String): RootfsCatalogEntry? =
        entries.firstOrNull { it.catalogId == catalogId }
}
