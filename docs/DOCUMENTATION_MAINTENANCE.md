# 文档来源与平台边界 / Documentation sources and platform boundaries

[`DOCUMENTATION_CATALOG.json`](DOCUMENTATION_CATALOG.json) is the explicit source registry for public guides. Each document has one audience: `shared`, `ios` or `android`, plus its English and Simplified Chinese source paths. A new source must be classified before entering an App help package or website platform index. Missing or unknown classifications fail the build; consumers must not discover help by scanning every Markdown file.

公开指南统一在上述目录登记受众和双语源文件。通用操作维护一份，平台入口、权限、安装、运行环境、编辑器和系统差异放在对应平台的指南中。新增文档先分类，不通过扫描全部 Markdown 自动加入 App 帮助。

| Source / 来源 | Audience / 受众 | App help / App 帮助 |
| --- | --- | --- |
| `SHARED_GUIDE*.md` | Both platforms / 两端共通 | Reused by each platform / 各自组装时复用 |
| `QUICKSTART*`, `USER_GUIDE*`, `WORKSPACES_GUIDE*` | iOS/iPadOS | iOS only / 仅 iOS |
| `ANDROID_GUIDE*` | Android | Android only / 仅 Android |
| Legal, channel snapshots and historical references / 法律说明、渠道快照、历史参考 | Explicitly classified / 逐项分类 | Not automatically included / 不自动加入 |

Existing filenames and deep links remain valid. Keep iOS/iPadOS and Android menu instructions out of the shared guide. Link to the shared guide rather than copying its full steps into each platform manual. A platform guide can explain its own menu labels and additional behavior.

保留现有文件名与深链。共通指南不写某一平台独有的菜单步骤；平台教程引用共通流程，再补充自己的菜单与差异，避免复制后两份内容逐渐分叉。

## iOS/iPadOS

`FloeAgent/scripts/build_help_content.py` selects `shared` + `ios` help sources, then generates the bundled resources and the authoring tree under `content-hub/sources/help/floe.help.quickstart`. The existing signed package ID, relative resource paths, signature checks and per-resource hashes stay authoritative. The website JSON catalog is not a signed App update feed.

生成器仅选择共通与 iOS 文档，同时生成 App 内置资源和签名内容源包。App 继续通过现有签名内容更新链读取 `floe.help.quickstart`，不抓取官网混合目录。修改内容需使用新的内容版本，已发布的同版本字节不可覆盖；生成资源后，由 App 主线同步 `HelpBundleMetadata.bundledVersion` 并完成当前候选的构建与验收。

```sh
python3 FloeAgent/scripts/build_help_content.py build
python3 FloeAgent/scripts/build_help_content.py check
python3 -m unittest discover -s FloeAgent/scripts/tests -p 'test_documentation_catalog.py'
python3 -m unittest discover -s FloeAgent/scripts/tests -p 'test_build_help_content.py'
```

## Website and Android / 官网与 Android

The website publishes `/docs/ios/zh.html`, `/docs/ios/en.html`, `/docs/android/zh.html` and `/docs/android/en.html`. Each platform's `catalog.json` lists only shared and matching platform documents. Its `platform` is required; entries include `id`, `audience`, `locale`, `title`, `summary`, `url`, `markdownURL` and the Markdown `sha256`. The website catalog is read-only navigation metadata, not permission to execute content or install an update.

官网分别生成平台目录、搜索索引与只读元数据。Android 页面只使用 Android 入口；现有 `android-zh.html`、`android-en.html` 及 iOS 手册深链保留。原生页面接入、离线缓存和 App 分发由各平台主线验收，网站更新不代表已发布新的安装包。
