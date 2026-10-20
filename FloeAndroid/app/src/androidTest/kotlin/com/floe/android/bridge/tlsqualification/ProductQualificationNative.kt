// SPDX-License-Identifier: MPL-2.0
// Product-UID TLS probe JNI reference (job-b1709c36b200442c).
//
// The debug-only qualification JNI library is built by :core:swiftbridge and
// packaged into every debug APK (the CMake option is debug-buildType-gated),
// so the App instrumentation process can load it too. JNI resolves the
// exported symbols by declaring-class binary name, hence this class MUST be
// named com.floe.android.bridge.QualificationNative — the same fully
// qualified name the swiftbridge androidTest uses. The two declarations never
// meet: a module's androidTest classes are not published to consumers, so the
// App test APK contains exactly this copy. Only the TLS qualification entry
// is referenced here (the transport fixture entries stay component-test
// scope). The file intentionally lives in the tlsqualification package
// directory while declaring package com.floe.android.bridge so the symbol
// matches; this is documented, not accidental.
package com.floe.android.bridge

/**
 * Loads `floe_qualification_jni` and exposes ONLY the bounded TLS
 * qualification entry for the product-UID default-trust probe. Debug/test
 * APK scope; never referenced from the App's main source set.
 */
object QualificationNative {
    init {
        System.loadLibrary("floe_qualification_jni")
    }

    /** Bounded JSON spec in (scenario only for the product probe), bounded JSON report out. */
    external fun nativeTLSQualification(spec: String): String
}
