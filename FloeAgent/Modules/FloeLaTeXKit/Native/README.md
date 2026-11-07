# Isolated native experiment

This directory is a reproducible engineering experiment, excluded from the
production `FloeLaTeXKit` dependency graph. The PDF backend contains GPL code;
TECkit components contain LGPL notices. The upstream MIT umbrella is not a
license determination for that complete closure. This is not an approved
production App distribution route.

The upstream checkout is a regenerable, ignored input. Its exact source,
original notices and successful-build evidence were retained in the private
qualification archive. For a fresh checkout, fetch only the pinned revision:

```sh
git clone --no-checkout https://github.com/tectonic-typesetting/tectonic.git \
  FloeAgent/Modules/FloeLaTeXKit/Native/tectonic
git -C FloeAgent/Modules/FloeLaTeXKit/Native/tectonic checkout --detach \
  8c0126a9653239a2e6e0a5274af9b8510f643030
python3 -B FloeAgent/Modules/FloeLaTeXKit/Native/Scripts/apply_host_patch.py
python3 -B FloeAgent/Modules/FloeLaTeXKit/Native/Scripts/apply_host_patch.py --check
```

`tectonic.source.json`, `dependencies.json` and `patches/source-manifest.json`
pin the inputs and per-file patch identities. Retain upstream notices and
review all linked components before any redistribution. `--check` only reads
and validates the already patched source; it never refreshes hashes.

`Scripts/build_apple.py --help` documents the standalone Apple build. Reuse the
repository's shared native build lock and task-owned internal caches. The
result goes to `Experiment/Vendor/FloeTeXNative.xcframework`; no binary target
from this directory belongs in the main App's production package.

中文说明：此目录仅保留隔离的原生工程实验。正式 App 通过已绑定的 Linux 工具链排版，
不链接这个实验。上游源码缓存不进入正式依赖；固定提交、补丁、原始许可与私有验证证据
仍然保留。能生成 PDF 不代表完整依赖许可或 Apple 分发已获确认。
