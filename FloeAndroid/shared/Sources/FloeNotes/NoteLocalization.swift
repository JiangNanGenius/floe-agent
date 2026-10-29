// SPDX-License-Identifier: MPL-2.0
//
// ANDROID-PORT-PATCH 1 (G06 foundation lane, 2026-10-29)
//
// Upstream FloeNotes uses `String(localized:defaultValue:)`, which depends on
// the Apple bundle/localization runtime. The Android Foundation overlay does
// not guarantee that initializer, and this module is compiled into
// libFloeAndroidCore.so. This shim resolves the same catalog key through the
// product's single FloeL10n authority and otherwise keeps the exact English
// fallback that upstream passed to `defaultValue:`.
//
// Behaviour on Apple platforms is intentionally irrelevant here: the frozen
// mirror/shared Android package is the only consumer of this patched copy; the
// iOS FloeNotes target keeps the original source unchanged.
import Foundation
import FloeCore

enum NoteLocalization {
    static func text(_ key: String, fallback: String) -> String {
        let resolved = FloeL10n.l(key)
        return resolved == key ? fallback : resolved
    }
}
