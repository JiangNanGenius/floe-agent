#!/usr/bin/env python3
"""Apply the non-generated runtime wiring for the l10n migration.

Safe to run on a clean tree; uses read->replace->write with explicit encodings
so files are never truncated.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def edit(rel, replacements, must=False):
    path = os.path.join(ROOT, rel)
    with open(path, encoding="utf-8") as fh:
        s = fh.read()
    orig = s
    for old, new in replacements:
        if old not in s:
            if must:
                raise SystemExit(f"missing expected text in {rel}: {old[:60]!r}")
            continue
        s = s.replace(old, new, 1)
    if s != orig:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(s)
        print("wired", rel)


def main():
    # SettingsCenter: persist + apply immediately.
    edit("FloeApp/Settings/SettingsCenter.swift", [(
        """    func setLanguageOverride(_ value: LanguagePreference) {
        languageOverride = value
        defaults.set(value.rawValue, forKey: UDKey.language)
    }""",
        """    func setLanguageOverride(_ value: LanguagePreference) {
        languageOverride = value
        defaults.set(value.rawValue, forKey: UDKey.language)
        // Apply across the whole process and mirror to the App Group.
        FloeL10n.setPreference(rawValue: value == .system ? nil : value.rawValue)
    }""")])

    # App entry bootstrap + SwiftUI locale.
    edit("FloeApp/App/FloeAgentApp.swift", [
        ("""    init() {
        let environment = AppEnvironment.live()""",
         """    init() {
        // Apply the saved in-app language before any catalog lookup.
        FloeL10n.bootstrap()
        let environment = AppEnvironment.live()"""),
        ("""    private var resolvedLocale: Locale {
        switch environment.settingsCenter.languageOverride {
        case .system: return .autoupdatingCurrent
        case .en: return Locale(identifier: "en")
        case .zhHans: return Locale(identifier: "zh-Hans")
        }
    }""",
         """    private var resolvedLocale: Locale { FloeL10n.swiftUILocale }"""),
    ])

    # Inline bilingual helpers: follow the in-app override, not raw Locale.
    helper_files = [
        "FloeApp/Workbench/WorkbenchEnvironment.swift",
        "FloeApp/Workbench/WorkbenchCenter.swift",
        "FloeApp/Workspace/OfficeInkPreferences.swift",
        "FloeApp/Workspace/IDELanguageRunView.swift",
        "Sources/FloeCore/BackgroundExecutionPreference.swift",
        "Sources/FloeWorkspace/IDENativeTextWorkspace.swift",
        "FloeApp/Workspace/WorkspaceCanvasView.swift",
        "FloeApp/Workspace/EngineeringReviewSheet.swift",
    ]
    for rel in helper_files:
        edit(rel, [('Locale.current.identifier.hasPrefix("zh")',
                    'FloeL10n.isChinese')], must=False)

    # Missing imports for files whose helper lives in FloeCore.
    edit("FloeApp/Workspace/OfficeInkPreferences.swift", [
        ("import Observation\n", "import Observation\nimport FloeCore\n")], must=False)
    edit("FloeApp/Workspace/IDELanguageRunView.swift", [
        ("import SwiftUI\n", "import SwiftUI\nimport FloeCore\n")], must=False)
    edit("Sources/FloeWorkspace/IDENativeTextWorkspace.swift", [
        ("import Foundation\n", "import Foundation\nimport FloeCore\n")], must=False)

    # FloeNotes now depends on FloeCore (acyclic: FloeCore has no Floe deps).
    edit("Package.swift", [(
        "dependencies: [.product(name: \"GRDB\", package: \"GRDB.swift\"), "
        ".product(name: \"Crypto\", package: \"swift-crypto\"), "
        ".product(name: \"ZIPFoundation\", package: \"ZIPFoundation\")],\n"
        "            path: \"Sources/FloeNotes\",",
        "dependencies: [\"FloeCore\", .product(name: \"GRDB\", package: \"GRDB.swift\"), "
        ".product(name: \"Crypto\", package: \"swift-crypto\"), "
        ".product(name: \"ZIPFoundation\", package: \"ZIPFoundation\")],\n"
        "            path: \"Sources/FloeNotes\",")])


if __name__ == "__main__":
    main()
