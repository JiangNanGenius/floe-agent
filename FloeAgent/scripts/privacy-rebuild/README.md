# Privacy rebuild — shell/text frameworks without uncovered statfs calls

`shell.framework` and `text.framework` shipped as pinned ios_system v3.0.2
binaries import `statfs`/`fstatfs`, which Apple classifies as
`NSPrivacyAccessedAPICategoryDiskSpace` APIs. Their call sites derive **no
disk-space value**, so no approved reason code describes them:

| framework | symbol | call site | what it actually reads |
| --- | --- | --- | --- |
| shell | `statfs` | `find -fstype` (`bsd_find/function.c`, `f_fstype`) | mount flags + `f_fstypename` only |
| text | `fstatfs` | `wc` (`text_cmds/wc/wc.c`, `cnt`) | `f_iosize` (I/O buffer size) |
| text | `fstatfs` | `tail` (`text_cmds/tail/forward.c`, `set_events`) | `MNT_LOCAL` mount flag |

The approved DiskSpace reasons are 85F4.1 (display space to the person),
E174.1 (check space before writing / delete when low), 7D9E.1 (opt-in bug
report) and B728.1 (health research). None of them matches a mount-flag or
I/O-size read, so this project rebuilds the two frameworks from the pinned
upstream source with a reviewed patch that removes those three calls instead
of declaring a reason that is not true.

## Rebuild

```bash
python3 FloeAgent/scripts/privacy-rebuild/rebuild_shell_frameworks.py \
    --output Local/Private/app-store-274-20261016/manifest-final/rebuilt-frameworks
```

The script:

1. clones `holzschu/ios_system` at tag `v3.0.2`
   (`8d013c4aa0a88fc97c5e8b4c052a62e03c716fe9`) into
   `~/Library/Caches/FloePrivacyRebuild/ios_system-v3.0.2` if not cached, and
   verifies the commit hash;
2. verifies the original SHA-256 of all three patched files, applies
   `patches/ios_system-v3.0.2-shell-text-privacy.patch` (SHA-256 pinned) and
   verifies the patched SHA-256 of each file;
3. builds the `shell` and `text` schemes for `iphoneos`/arm64 with
   `IPHONEOS_DEPLOYMENT_TARGET=26.0` (the app's deployment target) and
   `OTHER_CFLAGS=-Wno-error=incompatible-function-pointer-types` (the pinned
   sources predate the modern `FTSENT` const signature);
4. fails unless the rebuilt exported-symbol set is byte-identical to the
   shipped framework's set (ABI), no `statfs`/`fstatfs`/`statvfs`/`fstatvfs`
   import remains, the FileTimestamp imports the manifest declares are still
   present, the binary is arm64/iOS and the deployment target matches;
5. writes `shell.framework/` and `text.framework/` (executable + Info.plist)
   plus `PROVENANCE.json` to `--output`.

The patch changes exactly these behaviours:

* `find -fstype` fails with an explicit `-fstype is not supported in this
  build` instead of calling an undeclared API;
* `wc` sizes its read buffer from `fstat().st_blksize` (a FileTimestamp API
  the binary already uses and declares) instead of `fstatfs().f_iosize`;
* `tail` follow mode uses its existing sleep fallback on every volume instead
  of registering kqueue events it cannot validate for remote filesystems;
  `-F` still re-stats names every loop iteration.

## Symbols

The Release build also produces dSYMs next to the rebuilt bundles
(`…/Release-iphoneos/{shell,text}.framework.dSYM` in the rebuild
DerivedData). They are retained with the release artifacts and match the
rebuilt binaries — never pair the pinned v3.0.2 dSYMs with these binaries
(the UUIDs differ):

| framework | binary UUID | dSYM DWARF sha256 |
| --- | --- | --- |
| shell | `68693E63-E38F-3DB1-9B2D-2FA782E1EB3C` | `6dc7548b08f39ce4f7405543db1a396e4a7e4ed46f216e929d8bb45e60b13ba6` |
| text | `BD1169FD-7FB2-3F84-B5E0-F4492A32340D` | `6a42dc0c5f731682938d86254c19a3a0b7cce69f276fc6356d8c58cb22373dd8` |

## Release integration

The packaging step substitutes the rebuilds into the archive before signing:

```bash
python3 scripts/prepare_app_store_bundle.py --app "<Floe Agent.app>" \
    --report "<report.json>" \
    --rebuilt-frameworks "<rebuilt-frameworks directory>"
```

`prepare_app_store_bundle.py` verifies the `PROVENANCE.json` hashes, the
exported-symbol set against the embedded pinned framework (ABI), the absence
of statfs imports and the presence of the FileTimestamp imports, replaces only
the two executables plus their `Info.plist`, and records both the pinned and
rebuilt hashes in its report. Without the flag (or the
`FLOE_PRIVACY_REBUILT_FRAMEWORKS` environment variable) an unpatched shell/text
bundle fails the packaging with a pointer to this script — it can never ship
with the uncovered API by accident.

The rebuilt bundles are unsigned; the normal archive signing covers them. The
original SwiftPM artifacts stay in place as the rollback source: delete the
output directory and rebuild from the pinned SwiftPM cache to return to the
upstream v3.0.2 binaries.

## Provenance, licences and limitations

* Upstream project: <https://github.com/holzschu/ios_system> — BSD-3-Clause;
  the licence and the existing licence-inventory entry are unchanged. This
  directory records the local modification (patch + hashes) so the modified
  binaries stay attributable; there is no upstream ABI or symbol change.
* The rebuilt binaries are built with the local Xcode 27 toolchain; their bytes
  are therefore not bit-identical to upstream's Xcode 14.1 builds. The ABI
  (exported symbol set) and the manifest-visible imports are identical.
* Only the device (`iphoneos`/arm64) slice is rebuilt. Simulator builds keep
  using the pinned SwiftPM artifacts; the App Store submission uses the device
  archive that this substitution feeds.
* If a future upstream release ships manifests and removes these calls, delete
  this directory, drop the patch and pin the new upstream artifacts instead.
