# Native Office embedding inputs

This is a build-input inventory, not proof that Floe has an embedded editor.
Source is pinned by `engine.lock.json`. Never enable a field-form fallback as
completion of the full Word/Excel/PowerPoint frontend requirement.

The pinned upstream [Mobile project](https://github.com/CollaboraOnline/online.mirror/blob/27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc/ios/Mobile.xcodeproj/project.pbxproj)
compiles native mobile, common, kit, net and wsd code in the app target. It needs
engine config headers, generated UNO API headers, Boost/libpng/POCO/zstd headers,
the native archive file list, generated iOS resources and the built browser.
Engine archives plus browser files alone do not cover this dependency set.

## Bundle format 2

`package_office_engine.py` now includes these source/header/resource trees and
an ordered linker archive manifest. File entries carry SHA-256 and size. Symlink
targets are relative to their location and must stay within the build root;
runner-specific absolute links are not shipped. Build object trees are excluded
except required static libraries and generated inputs. Third-party licenses are
retained alongside inputs; a complete license inventory is still required.

After extracting a format-2 bundle with a safe tar extractor:

```sh
python3 FloeAgent/scripts/verify_office_engine.py /path/to/extracted-bundle --prepare
```

This verifies the recorded files and links, then writes a relocated ordered
`prepared/ios-all-static-libs.list`. It leaves the original hashed inputs intact.
The embedding target must use this new list and set engine/source/header roots
to the extracted bundle; the original file list still records the build host's
paths. This script does not compile, link, render, sign or certify an editor.

Local packaging tests require Python 3.12 or newer:

```sh
python3 FloeAgent/scripts/test_office_engine_bundle.py
```

## Pinned source preparation

`prepare_office_native_sources.py /path/to/extracted-bundle` verifies a format-2
bundle and the source/patch hashes in `engine.lock.json`, then creates separate
`prepared/native` copies. Original verified sources remain intact. Repeated
preparation is idempotent; edited prepared sources are preserved and rejected.
The overlay replaces private keyboard introspection with public `GCKeyboard`,
removes WebKit method swizzling, and removes upstream's global temporary-folder
cleanup. The embedding target must link GameController and use the prepared
controller; Floe needs its own bounded engine startup rather than replacing its
app delegate with the upstream app delegate.

Twelve synthetic packaging/preparation tests pass. The overlay also applies to
the actual pinned source hashes, and its public keyboard helper passes an
iphoneos arm64 Objective-C syntax check. This is not a full controller compile,
engine link, keyboard test, or native document-editing acceptance.

## Save and close boundary overlay

The pinned Mobile save callback deleted the engine copy after **both successful
and failed** UIDocument saves. Its close path deleted the copy before closing
UIDocument and dismissed the controller before knowing the close result. Floe's
overlay retains those copies, dispatches persistence on the main queue, and
exposes `CODocument.floeSaveCompletion` plus
`DocumentViewController.floeCloseCompletion`. A save callback reports engine
failure or the subsequent UIDocument persistence result. It does **not** report
Floe's original-file writeback, round-trip verification, or a host operation ID.
The host must serialize explicit save/close requests and wait for the relevant
completion before committing through `DocumentWorkspace`.

A successful close releases web handlers before returning control to the host;
a failed close retains the view and files. Uninitialized forwarding-pipe IDs
start at -1, and repeated close notifications cannot close another fake socket
or issue duplicate terminal callbacks. The host owns final dismissal and cleanup.

`test_office_native_lifecycle.py` applies the exact pinned overlay and compiles
the save/close fragments with controlled document/view doubles on macOS. Eight
checks execute success, failure, pending and duplicate-close paths against real
temporary copy files. Public controller/document headers also pass an iphoneos
arm64 syntax check. This does not compile the complete controller/engine or run
UIKit document persistence. In a prepared format-2 bundle, run:

```sh
python3 FloeAgent/scripts/test_office_native_lifecycle.py /path/to/bundle/prepared/native
```

For a pinned upstream source tree, pass its root with `--original-source`; only
the lifecycle files are copied and patched in a temporary directory. The cloud
workflow records this check separately and retains a successfully built engine
even if a lifecycle check fails. The already-running old workflow is unchanged.

## Remaining integration work

- Actual bundle verification, native Mobile compilation/linking and resource
  loading must pass before attaching the editor to Floe file sessions.
- The in-flight qualification run `34268468731` started with the previous
  packager. It is not retroactively upgraded by these changes. Its eventual
  archive must be inspected and may need supplementation with generated headers
  and native sources. Preserve reusable libraries; do not restart a live build.
- Verify the prepared controller is actually compiled and linked before shipping.
  Apple's public
  [GCKeyboard.coalescedKeyboard](https://developer.apple.com/documentation/gamecontroller/gckeyboard/coalesced?language=objc)
  reports connected keyboards; verify attachment/detachment, onscreen keyboard
  and Chinese input behavior on a device after replacement.
- Read-only inspector and fullscreen edit must share the same working document,
  version and reading position. Controller `UIDocument` close/save callbacks must
  settle before Floe's coordinated writeback; conflict/failed-save content must
  remain recoverable. The existing workspace lifecycle tests cover file bytes,
  not engine save callbacks or Office formatting.
- Native engine copies still use upstream's temporary directory. Before enabling
  the adapter, put them inside a persistent Floe session, connect recovery indexing,
  serialize engine autosave/explicit-save/close acknowledgements, and test WebKit
  termination plus unsaved in-memory engine changes. Retaining a temporary copy
  in these callbacks alone does not prove restart recovery or complete save safety.
- Reopen native DOCX/XLSX/PPTX in Microsoft Office and verify object geometry,
  fonts, charts, embedded content, formulas and untouched features. No simulator
  result substitutes for device engine acceptance: upstream builds the engine
  for iphoneos, not iphonesimulator.
