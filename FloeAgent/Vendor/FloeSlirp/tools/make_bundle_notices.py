#!/usr/bin/env python3
"""Assemble the four FloeSlirp bundle notices from the tracked license bytes.

Deterministic: reads FloeAgent/Vendor/FloeSlirp/licenses/* and the pinned
libslirp source archive (verified against PROVENANCE.json), preserving both
package and per-file notices. Writes FloeApp/Resources/Licenses/FloeSlirp-*.txt.
Run without --check to stage;
--check compares recomputation to the committed bytes and never writes.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
VENDOR_DIR = HERE.parent  # FloeAgent/Vendor/FloeSlirp
# --candidate = directory that contains FloeAgent/ (repo root in production);
# default is derived from this script's location inside the tracked package.
MIT_FILES = [
    "src/arp_table.c", "src/bootp.c", "src/dnssearch.c", "src/slirp.c",
    "src/state.c", "src/stream.c", "src/tftp.c", "src/util.c", "src/util.h",
]


def source_notices(vendor_dir: Path) -> str:
    """Preserve upstream per-file copyrights and grants in binary notices."""
    archive = vendor_dir / "vendor/libslirp-4.9.7-googlesource.tar.gz"
    if hashlib.sha256(archive.read_bytes()).hexdigest() != "4c34ed66c466daab0411bc50529567cfd1b9c30559db5ffbda41e54cbe36b030":
        raise ValueError("libslirp notice source archive does not match the pinned release")
    notices = []
    mit_files = []
    with tarfile.open(archive) as source:
        for member in sorted(source.getmembers(), key=lambda item: item.name):
            if not (member.isfile() and member.name.startswith("src/") and
                    member.name.endswith((".c", ".h", ".h.in"))):
                continue
            text = source.extractfile(member).read().decode("utf-8")
            comments = re.match(r"\s*(?:(?:/\*.*?\*/|//[^\n]*(?:\n|$))\s*)+", text, re.S)
            if not comments:
                raise ValueError(f"missing source notice: {member.name}")
            header = comments.group(0).rstrip()
            if "SPDX-License-Identifier: MIT" in header:
                mit_files.append(member.name)
                if "Permission is hereby granted" not in header:
                    raise ValueError(f"missing MIT grant: {member.name}")
            elif "SPDX-License-Identifier: BSD-3-Clause" not in header:
                raise ValueError(f"unreviewed source license: {member.name}")
            notices.append(f"--- {member.name} (upstream leading notices, verbatim) ---\n\n{header}\n")
    if mit_files != MIT_FILES or len(notices) != 58:
        raise ValueError("pinned per-file notice inventory changed")
    return "\n".join(notices)


def assemble(vendor_dir: Path, app_source_tag: str = "<APP_SOURCE_TAG>") -> dict[str, str]:
    lic = vendor_dir / "licenses"
    slirp_license = (lic / "libslirp-LICENSE.txt").read_text()
    slirp_copyright = (lic / "libslirp-COPYRIGHT.txt").read_text()
    glib_lgpl = (lic / "glib-LICENSES-LGPL-2.1-or-later.txt").read_text()
    pcre2 = (lic / "pcre2-LICENCE.md").read_text()
    intl = (lic / "proxy-libintl-COPYING.txt").read_text()

    licenses_txt = f"""Floe virtual network stack (FloeSlirp) - licenses and notices
================================================================

Floe Agent embeds a userspace virtual-network stack for its Linux guest:
libslirp 4.9.7, a trimmed GLib 2.90.1 core, PCRE2 10.46 (build-time JIT
disabled) and proxy-libintl 0.5 stubs. All four are linked statically into
the application binary. The exact pinned sources, local patches, build recipe
and per-file digests are recorded in FloeAgent/Vendor/FloeSlirp/PROVENANCE.json
(public GitHub repository JiangNanGenius/floe-agent); how to obtain, rebuild
and relink them is recorded in Licenses/FloeSlirp-SOURCE-OFFER.txt.

libslirp is licensed under the 3-clause BSD license reproduced below
(LICENSE), with the upstream copyright statement (COPYRIGHT). Nine files of
src/ carry the SPDX identifier "MIT" with their respective copyright holders
and the standard MIT permission notice retained verbatim in the file headers:
{chr(10).join('  - ' + f for f in MIT_FILES)}
Every other libslirp source file is BSD-3-Clause per its SPDX header.
The complete leading copyright and license notices of all 58 upstream
source/header files, including each MIT grant, are reproduced below.

--- libslirp LICENSE (verbatim) ---

{slirp_license}
--- libslirp COPYRIGHT (verbatim) ---

{slirp_copyright}
--- libslirp per-file source notices (verbatim) ---

{source_notices(vendor_dir)}
--- PCRE2 licence (BSD-3-Clause WITH PCRE2-exception, verbatim) ---

{pcre2}"""

    glib_txt = f"""GLib 2.90.1 - GNU Lesser General Public License 2.1 or later
============================================================

Floe Agent statically links a trimmed GLib 2.90.1 core (glib only; GObject/GIO
are not built) as part of the FloeSlirp userspace network stack, with its
recorded embedded-build patch (FloeAgent/Vendor/FloeSlirp/patches/). The library's
own COPYING member in the pinned release archive is a symlink to the text
reproduced verbatim below. The exact source, patches and rebuild and relink
instructions are recorded in Licenses/FloeSlirp-SOURCE-OFFER.txt and
FloeAgent/Vendor/FloeSlirp/PROVENANCE.json. Floe makes no relicensing claim;
the LGPL-2.1-or-later terms apply to this library component.

{glib_lgpl}"""

    intl_txt = f"""proxy-libintl 0.5 - GNU Library General Public License 2.0
==========================================================

The FloeSlirp stack links proxy-libintl 0.5 (frida fork) as static stubs:
the built libintl.a contains only identity pass-throughs and no dlopen,
matching the stub-only configuration of the GLib embedded build. The license
text of the pinned archive's COPYING is reproduced verbatim below; the
archive URL, hash and rebuild recipe are recorded in
FloeAgent/Vendor/FloeSlirp/PROVENANCE.json and Licenses/FloeSlirp-SOURCE-OFFER.txt.

{intl}"""

    offer = """FloeSlirp corresponding source and relink offer
===============================================

Application source tag: <APP_SOURCE_TAG>
Repository: https://github.com/JiangNanGenius/floe-agent

This material provides the corresponding source and rebuild/relink route for
Floe Agent's statically linked network stack: GLib 2.90.1 (LGPL-2.1-or-later),
proxy-libintl 0.5 (LGPL-2.0), libslirp 4.9.7 (BSD-3-Clause and per-file MIT),
and PCRE2 10.46 (BSD-3-Clause WITH PCRE2-exception; JIT disabled).

English
-------
1. Source. The immutable application tag above contains the complete App
   source and FloeAgent/Vendor/FloeSlirp/. Its vendor/ directory supplies
   every pinned source archive (libslirp tag commit
   ce12dcddf710a71dc0de6450ec95edbadf8e9f66). PROVENANCE.json records their upstream
   identities and SHA-256 values, local patch/build-source hashes, and the
   exact delivered archives and headers. The two libslirp mirrors have
   identical source contents; their archive bytes and hashes differ.
   Local modifications are recorded under patches/; see patches/README.md.
   libffi and zlib archives are supplied for completeness, and are not linked
   into this stack. Full license texts accompany this offer in Licenses/.
2. Rebuild. On macOS with Xcode 27.2 (27B52), Meson 1.12+, Ninja 1.13+,
   pkg-config, Python 3 and zsh, use a fresh build cache:

     cd FloeAgent/Vendor/FloeSlirp
     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
     export FLOE_SLIRP_CACHE="$HOME/Library/Caches/FloeSlirp-relink"
     zsh build/prepare-sources.sh

   To change a library, edit its unpacked sources under
   "$FLOE_SLIRP_CACHE/src" after preparation, then build:

     zsh build/build-platform.sh macos
     zsh build/build-platform.sh ios-device
     zsh build/build-platform.sh ios-sim
     python3 build/assemble_xcframework.py \
       --staging-root "$FLOE_SLIRP_CACHE/staging" \
       --output "$FLOE_SLIRP_CACHE/export/FloeSlirp.xcframework" \
       --manifests-dir "$FLOE_SLIRP_CACHE/export/vendor"
     zsh build/audit.sh ios-device

   Choose a fresh output path on later builds. The assembly tool preserves
   existing outputs. Source/configuration is reproducible; published digests
   identify the delivered bytes, and a private or modified rebuild has its
   own digests. Build details and required system link flags are in build/.
3. Relink. In a separate copy of the matching complete App source, replace
   FloeAgent/Vendor/FloeSlirp/FloeSlirp.xcframework with the rebuilt directory
   from step 2, including its Headers. Generate the App project using
   FloeAgent/scripts/gen_project.sh, then build the App target with Xcode and
   your own signing identity. FloeAgent/Package.swift links the static stack
   through FloeSlirpBinary and FloeARM64Engine. Keep the published source/tag
   and original release artifacts unchanged when making your own variant.
4. Rights. The applicable LGPL terms permit library modification and reverse
   engineering for debugging those modifications. Source access and relinking
   materials are provided for these purposes; platform installation/signing
   uses your own identity. The bundled license texts govern these rights.

简体中文摘要
------------
上方不可变应用 Tag 提供对应版本的完整 App 源码、固定的依赖源码归档、本地
补丁和构建工具。先按上述步骤准备独立构建目录，在 src/ 修改所需库源码，
重建三个平台的静态库，再用 assemble_xcframework.py 组装新的 XCFramework。
在同版本 App 的独立源码副本中替换整个 XCFramework（包含头文件），生成
工程、重建并使用自己的身份签名，即可使用修改后的库重新链接应用。
原发布版本与其不可变 Tag 保留不动；私人重建产物使用自己的校验和。
适用 LGPL 条款允许修改库及为调试此修改进行反向工程，完整许可文本与
对应源码、补丁和构建方法随本记录提供。本材料是工程交付记录。
""".replace("<APP_SOURCE_TAG>", app_source_tag)

    return {
        "FloeSlirp-LICENSES.txt": licenses_txt,
        "FloeSlirp-GLib-LGPL.txt": glib_txt,
        "FloeSlirp-ProxyLibintl-LGPL.txt": intl_txt,
        "FloeSlirp-SOURCE-OFFER.txt": offer,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--candidate", type=Path, default=HERE.parents[3],
                    help="directory containing FloeAgent/ (repo root); defaults to this package's location")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--app-source-tag", help="exact immutable App tag, supplied before release freeze")
    a = ap.parse_args(argv)
    vendor_dir = a.candidate / "FloeAgent/Vendor/FloeSlirp"
    out_dir = a.candidate / "FloeAgent/FloeApp/Resources/Licenses"
    tag = a.app_source_tag
    offer_path = out_dir / "FloeSlirp-SOURCE-OFFER.txt"
    if tag is None and offer_path.is_file():
        match = re.search(r"^Application source tag: (.+)$", offer_path.read_text(), re.MULTILINE)
        if match:
            tag = match.group(1)
    tag = tag or "<APP_SOURCE_TAG>"
    if tag != "<APP_SOURCE_TAG>" and not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-beta\.[1-9][0-9]*)?", tag):
        ap.error("app-source-tag must match the repository's immutable SemVer release tag")
    texts = assemble(vendor_dir, tag)
    problems = []
    for name, expected in texts.items():
        target = out_dir / name
        if a.check:
            actual = target.read_text() if target.is_file() else None
            if actual != expected:
                problems.append(f"drift: {target}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(expected)
            print(f"wrote {target} ({hashlib.sha256(expected.encode()).hexdigest()[:12]})")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    if a.check:
        print("bundle notices --check OK (deterministic from tracked license bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
