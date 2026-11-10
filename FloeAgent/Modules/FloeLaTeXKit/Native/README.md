# Native XeTeX / Apple PDF backend

The production source route builds **FloeTeXNativeXDV** for arm64 iOS and arm64
iOS Simulator. XeTeX and the in-process BibTeX engine emit real XDV and a bounded
physical display list. The Apple renderer uses CoreGraphics, CoreText, ImageIO
and real FreeType outlines for traditional TeX fonts. Protected PDF work uses
the App's existing PDFKitGate and exception boundary. This route has no Linux
or host-interpreter fallback; Biber and unsupported engines report an error.

The regenerable `tectonic/` directory is ignored. A fresh checkout needs only
the checked-in bridge, Apple shims, pinned manifests, complete source patch and
scripts. They reproduce upstream commit
`8c0126a9653239a2e6e0a5274af9b8510f643030` without a private source tree:

```sh
python3 -B FloeAgent/Modules/FloeLaTeXKit/Native/Scripts/prepare_xdv_source.py \
  --apply --allow-source-downloads
python3 -B FloeAgent/Modules/FloeLaTeXKit/Native/Scripts/prepare_xdv_source.py --check
```

`--apply` is explicit. `--check` only reads existing source and pinned metadata;
it never downloads, patches, rewrites a manifest or updates Cargo.lock. An
existing modified or partially patched tree is rejected and preserved. For
offline preparation, replace `--allow-source-downloads` with `--archive` and
the path to the exact pinned upstream archive. Existing exact upstream source
can also be prepared with `--apply`; an already prepared tree is unchanged.

`patches/production-xdv.patch` contains the complete upstream-to-production
delta, including Apple support, scoped I/O, cancellation, XDV, image metadata
and resource budgets. `production-xdv-source-manifest.json` records every
upstream/after file identity; `production-xdv-local-sources.json` pins the local
bridge, Apple, header, license and build inputs. Keep upstream notices intact.

Serialize native builds and follow the repository resource policy. The build
requires Xcode 27.2 at `/Applications/Xcode.app`, the two Rust Apple iOS targets,
CMake, Ninja and pkg-config. Start with six jobs:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 -B FloeAgent/Modules/FloeLaTeXKit/Native/Scripts/build_apple_xdv.py \
  --platform both --jobs 6 --allow-source-downloads --package
```

The download option permits only missing archives at their existing fixed
versions and SHA-256 values. The source and five static dependency archives
are build inputs; runtime TeX/font data has separate pinned bundle/cache
ownership. No executable is downloaded at runtime.

The new output is `Production/Vendor/FloeTeXNativeXDV.xcframework`, its manifest
and `FloeTeXNativeXDV.NOTICES.{txt,json}`. The producer audits the actual Cargo
closure, archive members and defined symbols to reject `tectonic_pdf_io` and
`tectonic_engine_xdvipdfmx`. It never qualifies or renames the old PDF archive.
The original `Experiment/` artifacts and `build_apple.py` route remain separate
historical material and do not belong in the production dependency graph.

Licenses are per component. The production selection is TECkit **CPL-1.0**,
FreeType **FTL**, and Graphite2 **MPL-2.0**, with the original notices retained.
Tectonic's MIT umbrella does not replace those terms. Complete selected texts,
the TECkit source identities and the selection record are under `licenses/`;
the generated notice text records the actual native/Rust closure and the
corresponding-source route. Include that text in the App's license resources.

中文说明：正式原生路线由 XeTeX/BibTeX 生成真实 XDV，再由 Apple 原生渲染器生成 PDF，
传统 TeX 字体与公式使用原始 TFM、编码和真实字体轮廓；受保护 PDF 仍通过现有统一保护区。
本路线不回退 Linux 或宿主解释器，不支持的引擎与 Biber 明确报错。上游缓存不进入 Git；
固定提交、完整补丁、逐文件摘要、自有桥接源码与脚本即可重现。`--check` 严格只读，
下载和补丁只能由显式 `--apply` 授权。旧实验与其 GPL PDF 后端独立保留，不用于正式二进制；
正式构建按实际依赖和对象审计，分别保留 CPL、FTL、MPL 与其他原始许可及来源说明。
