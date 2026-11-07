# 第三方组件与许可选择

Floe 自有源码使用 MPL-2.0。第三方源码、字体轮廓、JavaScript 胶水与 WASM 各自保留适用条款；外层包的 MIT、Apache-2.0 或 Floe 的 MPL-2.0 不覆盖这些组件的声明。

当前 GIS 实际运行时清单见 [dependency-inventory.json](Sources/FloeGISKit/Resources/Web/dependency-inventory.json)，完整分发原文见 [THIRD-PARTY-NOTICES.txt](Sources/FloeGISKit/Resources/Web/THIRD-PARTY-NOTICES.txt)。清单记录固定包版本、锁文件 integrity、下载来源、原文 SHA-256，以及预打包依赖／内嵌组件的父包来源链。实际构建输入另见 [bundle-inputs.json](Web/bundle-inputs.json)。

| 组件 | 适用条款与来源 |
| --- | --- |
| Floe 自有编辑器与 SQLite 薄适配层 | MPL-2.0，见 [LICENSE](LICENSE)。 |
| OpenLayers、Turf 子包、proj4、GeoTIFF、Three.js 等 | 逐包采用实际 inventory 所列条款，保留对应完整原文。GIS 只引入实际使用的 Turf 子包；未使用的 arc／skmeans 不进入当前闭包。 |
| `@turf/jsts` 2.7.2／`jsts` 2.7.1 | 明确选择 **EDL-1.0**。原始 [LICENSE_EDLv1.txt](THIRD_PARTY/JSTS/LICENSE_EDLv1.txt)、包声明、来源／SHA 与声明文件保留在 [JSTS](THIRD_PARTY/JSTS/)。Turf 根 MIT 不替代此义务。 |
| LERC 3.0.0 解码器 | **Apache-2.0**。保留 [LICENSE](THIRD_PARTY/LERC/LICENSE)、[NOTICE](THIRD_PARTY/LERC/NOTICE)、解码器版权与 [精确来源／SHA](THIRD_PARTY/LERC/SOURCES.json)。Esri v3.0 的对应解码器与安装包逐字节一致；NOTICE 中的原始声明随包保留。 |
| `zstddec` 0.2.0 与其内嵌 Zstandard WASM | 包装代码 **MIT**，Zstandard 解码器另受 **BSD-3-Clause**；整体记录为 `MIT AND BSD-3-Clause`。实际包的 LICENSE 已包含两份原文；inventory 另记录内嵌 WASM 的 54,394 字节与 SHA-256。 |
| `@sqlite.org/sqlite-wasm` 3.54.1-build1 | npm 包装代码 **Apache-2.0**；SQLite 3.54.1 核心及其 JavaScript API 为原作者声明的 **public domain**；Emscripten 5.0.5 胶水明确选择 **MIT** 分支。各层分别记录，不以 Apache 覆盖 SQLite 或胶水。完整原件及来源见下文。 |

## SQLite 核心替换

当前 consumer 使用固定官方 `@sqlite.org/sqlite-wasm` 3.54.1-build1，WASM 保持官方原字节，SHA-256 为 `b8a92a19f441a90ff2339fe988fbe317c4adf3ed844096f12aee04aa72d58257`。浏览器胶水由同一固定 `dist/index.mjs` 构建为本地脚本。原始版本／source ID、SQLite blessing 与 Emscripten 5.0.5 声明保留在 [原始 API 头注](../../Qualification/HeavyEditors/Notices/score/embedded/sqlite-3.54.1-api-header.original.txt)，完整 Emscripten 原文见 [5.0.5 LICENSE](../../Qualification/HeavyEditors/Notices/score/embedded/emscripten-5.0.5-LICENSE.original.txt)。

冻结的 npm gitHead `d720c07b87731b737fac4d6bab43d460d90b1fa2` 的 package.json／README 声明 Apache-2.0，但未包含 LICENSE.md。保留的 [完整维护者 LICENSE.md](../../Qualification/HeavyEditors/Notices/score/embedded/sqlite-wrapper-LICENSE.original.txt) 来自其后明确列出各层许可的不可变 commit `e5b104c052b1a00c146e4f8a9917c953aa03537d`；[冻结 README 原文](../../Qualification/HeavyEditors/Notices/score/embedded/sqlite-wrapper-frozen-README.original.txt) 与 [来源说明](../../Qualification/HeavyEditors/Notices/score/embedded/sqlite-notice-PROVENANCE.txt) 分别保留，不把后来的文件冒充冻结提交的内容。

原 `sql.js` 发行 WASM 带有未能确认适用授权的 `extension-functions.c`，已从锁文件、实际导入和分发资源移除。其原始失败与审查证据保留在私有资格记录中；它不属于当前 consumer，也不被标为许可通过。GIS 使用官方 SQLite 核心及自有薄适配层完成数据库操作。

## 共享重型编辑器中的其他预打包组件

以下属于乐谱／字体模块，其来源链在各自 inventory 中记录；不会因此成为 GIS 自身的运行时依赖。

- 乐谱模块的 OpenSheetMusicDisplay 2.2.1 内嵌 VexFlow 1.2.93、JSZip 3.10.1、loglevel、typescript-collections，以及 JSZip 实际内嵌的 lie／immediate／pako／setimmediate。每个 npm 组件保留实际锁定版本、integrity、完整原文和预打包父链；JSZip 明确选择 MIT。
- Gonville 轮廓采用 Simon Tatham 原作者的 unrestricted 输出字体许可，VexFlow 自定义／微分音字形仍保留自身 MIT 声明；适用原文和设计署名见 [Gonville LICENCE](../../Qualification/HeavyEditors/Notices/score/Gonville-LICENCE.original.txt) 与 [来源／credits](../../Qualification/HeavyEditors/Notices/score/Gonville-SOURCE-AND-CREDITS.txt)。没有使用 Bravura／OFL 代替 Gonville 的许可。
- 字体模块的 Paper.js 0.17.0 完整构建另内嵌 **Straps.js（MIT）** 和 **Acorn 0.5.0（MIT）**。保留 [实际 Paper 头注](../../Qualification/HeavyEditors/Notices/score/embedded/paper-0.17.0-header.original.txt)、[Straps 原文](../../Qualification/HeavyEditors/Notices/score/embedded/straps-LICENSE.original.txt) 与 [Acorn 原文](../../Qualification/HeavyEditors/Notices/score/embedded/acorn-0.5.0-LICENSE.original.txt)，以父包 integrity 和实际 entry SHA 绑定内嵌代码。

预打包审查记录位于 [prebundled-runtime.json](../../Qualification/HeavyEditors/Notices/score/embedded/prebundled-runtime.json)。它只补有实际字节证据的组件；`@types`、未带入浏览器包的 Node stream 实现及开发依赖不计为运行时。依赖更新使已审查的入口或原文 SHA 改变时，生成器会拒绝沿用旧结论。
