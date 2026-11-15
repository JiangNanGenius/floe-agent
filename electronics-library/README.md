# Floe electronics library

This is a declarative parts library for the existing native electronics workbench. It contains 47 available symbol/footprint combinations in 12 categories. `Catalog.json` also retains three blocked combinations and the precise unsupported source features. A generic symbol or a user-defined combination is not a manufacturer-qualified part.

`SOURCES.lock.json` pins original KiCad files by repository revision, size and SHA-256. `sources/` keeps those exact files. `licenses/` contains the full CC BY-SA 4.0 text, the KiCad library exception and source attribution. Converted geometry retains the original source bytes, notices and explicit pin-to-pad maps in each `packages/<category>/Library.json`. No KiCad application code or 3D model binary is bundled here.

The KiCad library license is [CC BY-SA 4.0 with the library design exception](https://www.kicad.org/libraries/license/). Original symbols and footprints remain third-party data; the conversion and curated associations are identified as modifications. Upstream documentation: [libraries](https://www.kicad.org/libraries/download/), [symbol format](https://dev-docs.kicad.org/en/file-formats/sexpr-symbol-lib/), [footprint format](https://dev-docs.kicad.org/en/file-formats/sexpr-footprint/).

`packages/<category>/content.json` describes one category for the existing signed-content template mechanism. It binds `Library.json` by SHA-256. Normal content-hub sources use the directory `sources/templates/<package-id>/` and are packaged by the unchanged `content-hub/build.py`; an unsigned candidate is not a published feed. The proposed first supported App version is 1.9.0, pending the release owner's version check. `sourceRevision` must be filled with the actual source checkpoint before signing; no older checkpoint is claimed to contain this new library.

Installed libraries and user imports have separate persistent storage. Each placed part embeds its version-pinned snapshot, original sources and mapping in the saved design. Library updates change future choices; replacing a placed part requires an explicit differences review. Unsupported import features retain their original files and a blocking explanation instead of silently losing pins or graphics.

## 元件库说明

首批包含 12 类、47 个可用符号／封装组合；另有 3 个来源组合因不支持的图元而明确阻断，详情保留在目录中。通用符号和用户自定义组合不会冒充已核定的厂商型号。

原始文件、固定版本、SHA-256、完整许可证、归属及转换说明分别保存在 `sources/`、`SOURCES.lock.json` 和 `licenses/`。每个分类的 `Library.json` 保留原始数据、兼容性说明和明确的引脚／焊盘映射。3D 模型引用单独保留，本库未下载或验证对应模型文件。

分类内容通过既有签名内容更新机制分发；未签名候选不表示已经发布。首个可用 App 版本暂拟 1.9.0，最终版本及真实 `sourceRevision` 须由发布流程核定后再签名。旧工程保持原有器件快照，库更新不会静默修改设计；替换器件需要核对差异。
