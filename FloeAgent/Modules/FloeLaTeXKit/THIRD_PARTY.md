# Third-party components and distribution boundary

Floe-authored editor, store, worker and host-adapter files remain MPL-2.0 under the repository license. This does not relicense upstream files.

## Production package

`Package.swift` has no native TeX binary target and no dependency on `Native/Experiment`. `verify_production_boundary.py` checks this boundary and can check the linked binary with `--binary`.

| Component | Pinned source | Selected terms | Use |
| --- | --- | --- | --- |
| ZIPFoundation | `0.9.20`, https://github.com/weichsel/ZIPFoundation/tree/0.9.20 | MIT; upstream copyright/license retained in SwiftPM dependency | Bounded project ZIP import/export |
| Apple platform zlib | OS SDK `libz` | System-provided library | Bounded gzip decoding for SyncTeX |
| Host formula renderer | Injected callback | Existing host dependency's own terms | The package neither bundles SwiftMath nor redistributes its fonts |

The production engine adapter calls independent, installed TeX tools through the App's explicitly resolved Linux `exec.shell` and jobs services. No host interpreter fallback, downloaded native App plug-in or new arbitrary-language execution tool is added. An environment's TeX Live, engines, Biber, fonts and macro packages retain their individual licenses and notices. They are not covered by the editor's MPL license. CLI/file separation is an architectural boundary, not an automatic legal conclusion or an App Store approval guarantee.

The Linux worker also requires the independently installed `bubblewrap` program. Its actual distro copyright/source records belong with the selected environment's package inventory; it is not linked into the Apple binary. The caller defines the mount/process/network policy, as explained by the [upstream project](https://github.com/containers/bubblewrap#sandbox-security). The qualification inventory retains installed package/source versions and original notices; passing those engineering checks does not approve a new redistribution catalog.

## Quarantined native experiment

`Native/Experiment/Package.swift` is a separate, explicit experimental package. It is used only by the independent LaTeX qualification host and is **not an approved dependency of the production App**. Keep its binary out of ordinary source commits and App packaging. It can be rebuilt from the pinned sources with `Native/Scripts/build_apple.py`.

Tectonic is pinned to `0.17.0`, commit `8c0126a9653239a2e6e0a5274af9b8510f643030`. Its root license notice explicitly covers only portions of the complete dependency closure. `engine_xdvipdfmx` and `pdf_io` contain GPL notices, and TECkit headers include LGPL notices. The source inventory records each detected file and hash; the count does not claim every listed file was compiled. The C ABI and separate Swift product do not clear those obligations. The existing successful native compile/runtime experiments are engineering evidence only.

| Experimental dependency | Version | Selected license branch / notice |
| --- | --- | --- |
| Tectonic/XeTeX closure | `0.17.0` at the commit above | Mixed; preserve per-file notices, including GPL/LGPL portions; do not label the whole binary MIT |
| FreeType | `2.15.0` | FreeType License branch; retain dual-license notices |
| HarfBuzz | `15.1.0` | MIT |
| Graphite2 | `1.3.15` | MPL-2.0 branch, with original multi-license notices retained |
| ICU | `79.1` | Unicode License v3 |
| libpng | `1.6.59` | libpng license |

Exact download hashes are in `Native/dependencies.json`; copied license texts are in `Native/licenses/`. Tectonic modifications are recorded in `Native/patches/apple-and-embedded.patch` and its base/patched hash manifest. `apply_host_patch.py --check` verifies without writing.

## Fonts and document packages

`Licenses/fonts-inventory.json` records hashes and embedded SFNT names, versions, copyrights and license notices for the existing host formula fonts and the experiment's observed fonts. These inventories are observations, not a new approved redistribution catalog. Latin Modern Math and TeX Gyre Termes use GUST Font License notices; several other host math fonts use OFL. The observed legacy XITS font has embedded STIX-family terms that must not be overwritten by a blanket OFL label. Experimental Fandol fonts require their exact accompanying font license/exception to be retained before any new redistribution.

`Licenses/experimental-tex-resources.json` records the exact macro/class/style files used by the seven experimental templates. Many packages declare LPPL, but some declare GPL or offer alternatives. Do not classify all `.sty`/`.cls` resources as LPPL, all fonts as OFL, or all resources as inert data. Reviewed resource catalogs must carry an explicit source, version, digest and applicable license for every package.

Primary notices: [Tectonic root notice](https://github.com/tectonic-typesetting/tectonic/blob/8c0126a9653239a2e6e0a5274af9b8510f643030/LICENSE), [xdvipdfmx source](https://github.com/tectonic-typesetting/tectonic/blob/8c0126a9653239a2e6e0a5274af9b8510f643030/crates/engine_xdvipdfmx/xdvipdfmx/dvipdfmx.c), [LPPL](https://www.latex-project.org/lppl/lppl-1-3c/), [GNU license FAQ](https://www.gnu.org/licenses/gpl-faq.en.html).
