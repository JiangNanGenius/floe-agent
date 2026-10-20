// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Debug instrumentation wrapper for the qualification seam compiled into
 * libFloeAndroidCore.so and exported through libfloe_qualification_jni.so.
 * Present ONLY in the androidTest source set, and the underlying native
 * library is built ONLY for the debug variant (CMake flag from the debug
 * buildType), so release AAR native entries and Java/Kotlin test-helper
 * classes never ship it. These entry points are not bridge operations;
 * security evaluation is classification only — no command is ever executed
 * here, and nothing registers grants or task authority.
 */
object QualificationNative {
    init { System.loadLibrary("floe_qualification_jni") }

    /** Returns a gate handle or 0 when the corpus is rejected (fail closed). */
    external fun nativeGateCreateFromCorpus(corpus: ByteArray): Long

    /** Returns the gate's own match-everything failClosed handle. */
    external fun nativeGateCreateFailClosed(reason: String): Long

    /** Classification only: JSON verdict {ok, stopped, matchedPatternID, reason}. */
    external fun nativeGateEvaluate(handle: Long, command: String): String

    external fun nativeGateRelease(handle: Long)

    /** JSON report over the real DatabaseManager/GRDB/SQLite runtime. */
    external fun nativeDbSmoke(cachePath: String): String

    /** JSON report of ACTUAL JSON primitive dynamic types + Canvas mapping. */
    external fun nativeJsonKindSmoke(): String

    /**
     * G02-P3 incremental transport probe: bounded JSON spec in (loopback base
     * URL + scenario + tag), bounded JSON report out. Drives the REAL Android
     * FoundationNetworking delegate transport through the original three wire
     * adapters, SSE parser pipeline and MCP Streamable-HTTP client against
     * the instrumentation-owned loopback fixture. Synthetic fixture traffic
     * only; never a real endpoint or credential.
     */
    external fun nativeTransportSmoke(spec: String): String

    /**
     * G02 native TLS/default-trust probe (job-b1709c36b200442c): bounded JSON
     * spec in (scenario + fixture base + canary + expected digests), bounded
     * JSON report out. Drives the REAL Android FoundationNetworking trust
     * path through the original `StreamingTransport.makeSession` factory and
     * the original provider/MCP adapters. Synthetic fixture material only;
     * the public positive carries no credentials and the test-CA lever is
     * managed by the test process (set/finally-clear), never in product code.
     */
    external fun nativeTLSQualification(spec: String): String

    /**
     * TEST-PROCESS-ONLY lever: point the upstream
     * `URLSessionCertificateAuthorityInfoFile` at a synthetic fixture CA
     * bundle for controlled TLS fixtures. Never called on product paths;
     * must never be combined with the INSECURE_SSL_NO_VERIFY value.
     */
    external fun nativeTLSSetCABundle(path: String)

    /** Restores the default system-CA trust path in the test process. */
    external fun nativeTLSClearCABundle()
}
