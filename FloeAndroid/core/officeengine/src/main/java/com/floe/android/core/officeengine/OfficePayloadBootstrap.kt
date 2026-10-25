package com.floe.android.core.officeengine

/**
 * Pure payload/bootstrap rules (JVM-testable, no Android framework use).
 *
 * The engine reads its writable profile from `$APP_DATA_DIR` (upstream
 * behaviour preserved): the packaged `unpack` subtree must be
 * extracted there once per payload change before the first native load, and
 * the fontconfig cache directory inside the extracted `etc/fonts/fonts.conf`
 * must point at the RUNNING package (the staged APK baked its own application
 * id, which is not this app's identity across full/dev/flavour suffixes).
 */
object OfficePayloadBootstrap {

    /** SharedPreferences key holding the completed extraction marker. */
    const val PREFS_NAME = "floe_office_engine"
    const val KEY_UNPACK_MARKER = "UNPACK_MARKER"

    /**
     * Marker identity = payload source revision + application package. A
     * package or payload change forces re-extraction (overwrite semantics are
     * idempotent; nothing under dataDir is deleted here).
     */
    fun unpackMarker(payloadSourceRevision: String, applicationPackage: String): String =
        "$payloadSourceRevision|$applicationPackage|bootstrap2"

    /** True when the stored marker already equals the required marker. */
    fun needsExtraction(storedMarker: String?, payloadSourceRevision: String, applicationPackage: String): Boolean =
        storedMarker != unpackMarker(payloadSourceRevision, applicationPackage)

    /**
     * Rewrites the baked upstream cachedir line to the running package. Any
     * other content is returned untouched; the function is pure so tests can
     * prove byte-level behaviour on the pinned fonts.conf text.
     */
    fun rewriteFontsConf(
        fontsConfContent: String,
        applicationPackage: String,
        applicationDataDir: String = "/data/data/$applicationPackage",
    ): String {
        require(applicationDataDir.startsWith("/")) { "Application data directory must be absolute" }
        // Use the actual OS-owned user/profile path; /data/data always names
        // user0 and is not the data directory of a secondary Android user.
        val cacheDir = (applicationDataDir.trimEnd('/') + "/fontconfig")
            .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        return fontsConfContent.replace(
            "/data/data/com.collabora.libreoffice/fontconfig", cacheDir,
        )
    }

    /** Asset path of the engine profile tree inside the packaged assets. */
    const val UNPACK_ASSET_ROOT = "unpack"

    /**
     * Relativise an asset path under [UNPACK_ASSET_ROOT] into a dataDir
     * relative path. Returns null for traversal attempts (defensive: the
     * listing comes from our own packaged assets, but paths are never blindly
     * joined).
     */
    fun unpackTargetRelPath(assetPath: String): String? {
        if (!assetPath.startsWith("$UNPACK_ASSET_ROOT/")) return null
        val rel = assetPath.removePrefix("$UNPACK_ASSET_ROOT/")
        if (rel.isEmpty() || rel.split('/').any { it == ".." || it.isBlank() }) return null
        return rel
    }
}
