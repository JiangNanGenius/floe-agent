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
an ordered linker input manifest (`linkerInputs`), including explicitly required
`.a` libraries and `.o` objects. `linkerArchives` remains the archive-only subset.
File entries carry SHA-256 and size; explicit directory entries preserve empty
folder resources and directory aliases. Symlink
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

## Floe-owned native host (qualification in progress)

`FloeOfficeNative/FloeOfficeNative.h` exposes a pure Objective-C UIKit facade to
Swift. Its runtime waits for the native server's poll loops to start before it
admits documents. It uses a versioned Application Support profile/cache, replaces
upstream application startup/termination, and reports server failure without
aborting Floe or deleting document copies. Initialization currently retains
upstream main-thread affinity; device startup latency is not yet measured.

The document controller embeds the actual upstream editor with a fixed readonly
or editable permission. It only accepts a file inside a supplied persistent
session directory. Each engine open creates a new UUID child; failed opens and
later generations never erase previous copies. The open event means UIDocument
loaded its copy, not that the frontend rendered. Save events include autosaves
and are explicitly not original-writeback receipts. A separate explicit-save
API now associates a request ID with a kit save sequence and waits for that
sequence's UIDocument persistence result. Earlier autosaves, reordered receipts,
late results after cancellation and broker rejection cannot satisfy another
request. Eight compiled joiner checks pass; run `34296658499` also compiled and
linked the full protocol and imported its save/close APIs from Swift. A real
engine save is still unverified. Original-file CAS,
close recovery and the SwiftUI inspector/fullscreen transition remain gates.

`build_office_native_host.py` transforms the verified Mobile project into a
framework, replacing its six app/browser/template source files with Floe's host
and retaining the real editor/common/kit/net/wsd sources and ordered native
linker inputs. Engine/browser resources are packaged as `OfficeRuntimeResources`
for copying into the Floe **main app bundle**, as required by native bootstrap.
The framework only publishes the facade header. Qualification includes a real
native compile/link and a Swift module import; neither establishes UI/device
editing acceptance. All patched top-level source trees (including wsd) get owned
copies, and writes beneath directory aliases are rejected.

The copy-opening fragment is also compiled separately against real temporary
files and controlled resources/sockets: seven checks cover missing resources,
retry generations, repeated loads, independent opens, failed source copies,
non-file directories, and failed socket allocation. This supplements the eight
save/close fragment checks, but does not substitute for a real UIDocument open
or frontend rendering. `DocumentWorkspace.close` retains the session whenever
native generations, recovery data, or unknown sidecars exist, even when the
working file's digest is unchanged; only explicit discard removes those files.

Host qualification run **34292622779** succeeded for source `afdb221`. Its
unsigned framework and main-bundle resources are pinned under
`qualifiedHostArtifact` in `engine.lock.json`; all 4,780 resource files and 174
directories were checked after retrieval. A local iphoneos Swift typecheck also
used the actual retrieved framework to call startup, the throwing document
initializer, and all three lifecycle callbacks. This is compile-time API
integration only. That historical raw host receipt inherited two false Mobile
prepare-only flags; the `hostCompilePassed`, `hostLinkPassed`, and
`swiftModuleImportPassed` fields record the host result. New receipts identify
the framework target and keep those generic native flags consistent.

## Floe device-app packaging

The current qualified host is run `34296658499`, source `3b5308f`. Retrieved
payload verification checks 4,785 files and 178 directories, including the
public save/close API, executable and main-bundle resources. The new SwiftUI
session owns readonly inspector and fullscreen editor generations, requests a
correlated private save before coordinated original writeback, and waits for
native close before returning. Its actual app build, reading-position handoff,
recovery UI, save-as and real editing/fidelity acceptance are still pending.

`scripts/bootstrap_office_host.py` installs the pinned archive into the ignored,
versioned `Vendor/Office/<runID>/OfficeNativeHost` directory. It checks the archive,
qualification manifest, native source/overlay, binary, module map, Info.plist,
public header, all resources and empty directories. Reuse verifies existing
content; changed or unexpected files are preserved and rejected. The regular
runtime bootstrap invokes it with a developer gh login or a read-only Actions
token. No runtime executable download is added to the app.

The app's generated Xcode project links the framework only for `iphoneos` and
copies its main-bundle resources in a verified post-build phase with bounded
input/output declarations. The Floe target has only this script and disables
Xcode's script dependency sandbox for its recursive copy/signing; other targets
retain that sandbox. Every input is still hash-checked and output paths remain
restricted to the generated Floe app. Simulator has no native engine slice and skips embedding;
Simulator success cannot certify Office. Signing-enabled builds sign the copied
framework; unsigned qualification builds leave it unsigned. The host was built
with SDK 27 targeting iOS 26, so accepted-SDK packaging and Apple validation
remain separate release gates.

`verify_office_app_embedding.py` checks the actual unsigned Floe app's native
payload against the pin, preserves required empty directories, and requires a
real Office load command in the Floe executable. Its receipt keeps runtime open,
UI editing, original writeback and device fidelity false. Twelve bootstrap and
copy/verification tests cover tampering, missing assets/directories, aliases,
changed source, repeat installation, and preservation of unrelated app resources.

Actual Floe device build `34294036299` reached the post-build phase and failed
because XcodeGen ignored the unsupported `inputPaths` YAML key, generating an
empty script input list. The project now uses `inputFiles`; the generated PBX
contains all six declared script/metadata inputs. The first correction also
emitted a file list covering every payload entry and retained script sandboxing.
Twelve bootstrap tests passed, but the next actual app build exposed a separate
system argument limit, recorded below.

Run `34296994732` then compiled the actual Floe UI but could not spawn
sandbox-exec because ~5,000 file declarations exceeded the argument limit.
Small iphoneos build probes confirmed that recursive inputs can be enabled but
directory outputs still grant literal access only; nested writes were denied.
This matches [Swift Build's sandbox implementation](https://github.com/swiftlang/swift-build/blob/main/Sources/SWBTaskConstruction/TaskProducerSandboxing.swift).
The bounded declaration / target setting above replaces that unsuccessful
configuration. A minimal app build using the actual embed script now succeeds,
and its copied framework plus 4,780 resources / 174 directories pass payload
verification. Twelve bootstrap regressions also pass. That probe is not the
actual Floe executable or a runtime/editor test; a fresh full app build remains
required. The cloud job now also retains an unsigned app for further qualification.

Twenty-two synthetic packaging/preparation/repair tests pass. The overlay also applies to
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

- Actual bundle verification and native Mobile compilation/linking have passed
  in the isolated target. Floe host integration and on-device resource loading
  must pass before enabling its editor for file sessions.
- Qualification run `34268468731` completed successfully. Its old-format archive
  is locked by SHA-256 in `engine.lock.json` and preserved locally. Inventory
  confirms 278 linked archives are present but all 91 explicitly linked NSS
  objects, generated config/UNO headers and common/kit/net/wsd sources are absent.
  `supplement_office_engine.py` reuses those archives, generates missing headers
  with the pinned host cppumaker and rebuilds only NSS dependencies, then restores
  and checks the original archive bytes before packaging complete inputs. Its
  cloud workflow preserves generated dependencies even if later packaging fails.
  Supplementation and the subsequent complete Mobile compile/link have now
  succeeded; see the locked artifacts and qualification record below. The
  initial engine build alone did not establish these later results.
- Verify the prepared controller is compiled and linked into Floe before shipping.
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

## Complete native UI qualification

`qualify_office_mobile.py <verified-format-2-bundle> <new-output-directory>`
prepares a separate native source tree with the exact locked overlay and builds
the upstream Mobile target for unsigned arm64 iphoneos. It retains all 57 native
source entries and 28 editor resource entries, uses the relocated complete linker
list and adds GameController. Upstream release scripting, test-data copying and
the separate QuickLook extension are excluded. Verified input files stay intact.
The result includes the Xcode log, result bundle, executable hash and platform
load commands. A successful result proves compilation/linking only: all Floe
embedding and device-editing acceptance flags remain false.

Five project-boundary/evidence tests pass, and the transformation was inspected against
the actual pinned project. The complete native UI build still needs to execute.
Dependency attempt `34286492116` generated the host tool and NSS objects but failed
starting cppumaker because the script used `instdir_for_build/program`. Its actual
macOS library delivery is `instdir_for_build/Contents/Frameworks`; the corrected
workflow also preserves those dylibs. Logs and generated objects were retrieved.
This failure did not invalidate or replace the already-qualified engine archives.

Dependency run `34287476509` then successfully generated and packaged 46,525
inputs and all 369 ordered linker entries (278 archive entries, 277 distinct
archives, and 91 objects). Its SHA-locked artifact is retained. Native UI
qualification stopped before compilation because two unused zstd CLI test links
pointed to a script excluded by header-only packaging. The packager now omits
such aliases. `repair_office_embedding_bundle.py` only accepts the exact locked
archive and removes exactly those two recorded links in a fresh extraction;
it verifies every other file, alias and linker entry and leaves the original
archive intact. The actual repaired bundle passed verification: 46,523 entries,
all 369 linker inputs. All 91 regenerated NSS objects were also inspected and
are iOS objects with minimum OS 26.0. This is still not native UI compilation.

The separate `office-mobile-qualification.yml` workflow downloads this preserved
bundle and performs verification, source preparation and Mobile compile/link.
It does not repeat the engine or dependency builds. Early input-verification
failures now produce a failed qualification receipt as well as job logs.

Run `34288940412` passed bundle verification/source preparation and entered
Xcode, then failed copying the absent empty `resources/config` directory. The
pinned `engine/ios/CustomTarget_iOS_setup.mk` creates this directory without
populating it. The repair lock now restores exactly that empty directory; the
packager and verifier also preserve explicit directory entries, so empty folder
resources and header-directory aliases survive relocation. All 57 source paths
and 28 resource references were checked in the prepared project; this was the
only missing resource. This check does not prove header compilation or linking.
The revised repair was also executed against the actual locked archive in a new
local extraction: 46,524 entries and all 369 linker inputs verified successfully.

## Native Mobile compile/link passed

Run [34289431937](https://github.com/JiangNanGenius/floe-agent/actions/runs/34289431937)
completed successfully with the locked overlay. Xcode compiled the complete
prepared Mobile target and linked its arm64 iphoneos executable (minimum iOS
26.0, SDK 27.0). The unsigned app archive was retrieved; its executable SHA-256
matches the cloud receipt. The archive and executable hashes are retained in
`engine.lock.json.qualifiedMobileArtifact`. The executable is 191,386,256 bytes;
the archived app has 5,135 entries totaling 342,972,254 uncompressed bytes.

This supersedes the pending **compile/link** notes above, but does not prove
Floe embedding, launch, document editing, keyboard behavior or layout fidelity.
Next integration must expose the native controller through a Floe-owned host,
exclude the upstream app delegate/browser lifecycle, initialize an isolated
engine profile/cache, keep engine document copies in persistent Floe sessions,
and correlate explicit-save completion with UIDocument persistence before
original-file writeback. The existing uncorrelated save callback is insufficient
to distinguish an earlier autosave from the user's explicit save. Inspector and
fullscreen presentation must preserve document state and enforce readonly/edit
access, and source/resource integration must be compiled again in Floe.
