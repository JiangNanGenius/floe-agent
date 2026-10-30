# Worked examples

| file | shows |
| --- | --- |
| [dependencies.minimal.json](dependencies.minimal.json) | minimal envelope: one required exact pip pin |
| [dependencies.purepip.json](dependencies.purepip.json) | several pure `py3-none-any` pins sharing one package-local wheel lock |
| [dependencies.debian.json](dependencies.debian.json) | Debian apt identities with exact versions (single guest transaction + dpkg readback) |
| [dependencies.npm.json](dependencies.npm.json) | exact `name@version` npm pins (lock bytes are review evidence, never replayed) |
| [dependencies.cjk.json](dependencies.cjk.json) | Debian science-stack apt pins (`python3-matplotlib`, `fontconfig`) plus the optional exact font identity+version pin with the fixed CJK glyph-render probe |
| [dependencies.macos.json](dependencies.macos.json) | schemaVersion 2 macOS profile: exact pip pin with the same package-local lock reference plus an exact npm pin; no apt/font/runtimeComponent on macOS |

**A skill with no dependencies ships NO `dependencies.json` at all.** Do not
invent an empty declaration: a document with zero profiles or a profile with an
empty `requirements` array is invalid and fails closed. Guidance-only and
script-only packages keep the existing no-sidecar behavior — old and new clients
behave exactly as before.

The five schemaVersion 1 files above stay the frozen Linux examples. The macOS
example is schemaVersion 2 and is not a replacement for any of them; the
machine schemas are [v1](../dependencies.schema.json) and
[v2](../dependencies.v2.schema.json). These are declaration shapes only: the
referenced lock bytes are not shipped in docs (the Linux purepip example behaves
the same way).
