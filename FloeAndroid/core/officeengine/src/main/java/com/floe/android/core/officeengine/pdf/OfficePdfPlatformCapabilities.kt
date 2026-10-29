// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.os.Build

/** Which real platform renderer class backs one isolated PDF job. */
enum class OfficePdfEngineKind {
    /** API 28–30: legacy `PdfRenderer` only — no password, no text content. */
    LEGACY,

    /** API 35+: `PdfRenderer` with `LoadParams` + page text content. */
    API_35,

    /**
     * API 31–34 WITH the Mainline `framework-pdf` module (module version 13+):
     * `PdfRendererPreV` exposes the API-35 render/password/text surface.
     */
    PRE_V,
}

/**
 * Runtime + pure capability policy for the isolated PDF renderer.
 *
 * Verified on 2026-10-30 against the installed API-37 SDK
 * (`platforms/android-37.0/android.jar`, `android-stubs-src.jar` and
 * `data/api-versions.xml`):
 *  - `android.graphics.pdf.PdfRenderer(ParcelFileDescriptor, LoadParams)` is
 *    public `since="35"`; `LoadParams.Builder.setPassword(String)` is public
 *    (the earlier handoff's "no public setter" assumption was WRONG);
 *  - `PdfRenderer.Page.getTextContents()`/`searchText()` are public
 *    `since="35"`;
 *  - `android.graphics.pdf.PdfRendererPreV` is a `framework-pdf` module class
 *    (`module="framework-pdf" since="35" sdks="31:13,33:13,34:13,35:13,0:35"`),
 *    i.e. present on API 31/33/34 devices whose PDF Mainline module is
 *    version 13+, and its `Page.getTextContents()` is part of that module
 *    surface. Class presence is therefore the honest runtime gate on 31–34;
 *  - `PdfRenderer.write(...)` is `since="35"` / PreV module 13, while
 *    `Page.addPageAnnotation(...)` is `since="36.1"` (module 18) — see
 *    [OfficePdfPlatformCapabilities.nativeAnnotationWrite] below.
 *
 * This object is pure for an explicit `(apiLevel, modulePresent)` pair so the
 * guard matrix is unit-testable on the JVM; only [pdfModulePresent] touches
 * the runtime class table (a name lookup, never an instance).
 */
object OfficePdfPlatformCapabilities {

    const val LEGACY_MAX_API: Int = 30
    const val PRE_V_MIN_API: Int = 31
    const val FULL_API: Int = 35
    /**
     * Conservative gate for the annotation surface: `addPageAnnotation` is
     * `since="36.1"` (a MINOR platform version this installed API-37 SDK
     * proves). `Build.VERSION.SDK_INT` alone cannot distinguish 36.0 from
     * 36.1, so this policy only claims annotations on the verified API 37
     * surface rather than overclaiming on an unverified 36.0 device.
     */
    const val ANNOTATION_WRITE_MIN_API: Int = 37

    /** Public native annotation/write facts used by the export-fidelity policy. */
    data class NativeAnnotationWrite(
        /** `PdfRenderer.write` exists (API 35+ or PreV module 13 on 31–34). */
        val writeApiPresent: Boolean,
        /** `Page.addPageAnnotation` exists (API 36.1+ / module 18). */
        val annotationApiPresent: Boolean,
        val supportedAnnotationTypes: List<String>,
    )

    fun engineKind(
        apiLevel: Int = Build.VERSION.SDK_INT,
        modulePresent: Boolean = pdfModulePresent(),
    ): OfficePdfEngineKind = when {
        apiLevel >= FULL_API -> OfficePdfEngineKind.API_35
        apiLevel >= PRE_V_MIN_API && modulePresent -> OfficePdfEngineKind.PRE_V
        else -> OfficePdfEngineKind.LEGACY
    }

    fun textExtractionSupported(
        apiLevel: Int = Build.VERSION.SDK_INT,
        modulePresent: Boolean = pdfModulePresent(),
    ): Boolean = engineKind(apiLevel, modulePresent) != OfficePdfEngineKind.LEGACY

    fun passwordSupported(
        apiLevel: Int = Build.VERSION.SDK_INT,
        modulePresent: Boolean = pdfModulePresent(),
    ): Boolean = engineKind(apiLevel, modulePresent) != OfficePdfEngineKind.LEGACY

    /** Already-resolved engine variant (used by the isolated service). */
    fun textExtractionSupported(kind: OfficePdfEngineKind): Boolean =
        kind != OfficePdfEngineKind.LEGACY

    /** The text backend exists at API 35 unconditionally; 31–34 depends on the module. */
    fun textMinApi(): Int = FULL_API

    fun textBackportMinApi(): Int = PRE_V_MIN_API

    fun nativeAnnotationWrite(
        apiLevel: Int = Build.VERSION.SDK_INT,
        modulePresent: Boolean = pdfModulePresent(),
    ): NativeAnnotationWrite {
        val kind = engineKind(apiLevel, modulePresent)
        val write = kind != OfficePdfEngineKind.LEGACY
        // addPageAnnotation is since 36.1: Android 16 QPR1+ on the full
        // framework, or module version 18 (which maps to 31:18 / 33:18 /
        // 34:18 in api-versions.xml). The installed API-37 SDK compiles it;
        // only that verified surface is claimed here.
        val annotation = apiLevel >= ANNOTATION_WRITE_MIN_API
        return NativeAnnotationWrite(
            writeApiPresent = write,
            annotationApiPresent = annotation,
            supportedAnnotationTypes = if (annotation) {
                listOf("FREETEXT", "HIGHLIGHT", "STAMP")
            } else {
                emptyList()
            },
        )
    }

    /**
     * Runtime Mainline-module probe: BOTH `PdfRendererPreV` and
     * `LoadParams.Builder` must be linkable. Called only on API 31–34 by
     * [engineKind]'s default, and the PreV adapter class is loaded only after
     * this returns true.
     */
    fun pdfModulePresent(): Boolean = runCatching {
        val loader = OfficePdfPlatformCapabilities::class.java.classLoader
        val preV = Class.forName("android.graphics.pdf.PdfRendererPreV", false, loader)
        Class.forName("android.graphics.pdf.LoadParams\$Builder", false, loader)
        // Prove the exact constructor this module calls exists, not merely the
        // class name: an older Mainline module may ship PdfRendererPreV without
        // the password-capable overload.
        preV.getConstructor(
            Class.forName("android.os.ParcelFileDescriptor", false, loader),
            Class.forName("android.graphics.pdf.LoadParams", false, loader),
        )
        // And prove the page object still exposes the text API used by the
        // adapter, so 31–34 is only selected when the module surface matches.
        preV.getMethod("openPage", Integer.TYPE).returnType.getMethod("getTextContents")
        true
    }.getOrDefault(false)

    /** Path-free diagnostic line for settings/diagnostics views. */
    fun diagnosticsLine(apiLevel: Int = Build.VERSION.SDK_INT, modulePresent: Boolean = pdfModulePresent()): String {
        val kind = engineKind(apiLevel, modulePresent)
        return "pdfEngine=${kind.name.lowercase()} api=$apiLevel pdfModule=$modulePresent " +
            "text=${textExtractionSupported(apiLevel, modulePresent)} " +
            "password=${passwordSupported(apiLevel, modulePresent)}"
    }
}
