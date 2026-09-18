# Floe Agent 1.7.0 (187) / beta.44 candidate

Fixed source `d77aa11f7b4933b987faf5cf65ebc817d520e15e`, tagged
`v1.7.0-beta.44`. [Release run 35312393708](https://github.com/JiangNanGenius/floe-agent/actions/runs/35312393708)
is qualifying in cloud CI; no upload or installability is claimed. Build 186 / beta.43
failed qualification and was not uploaded ([final record](RELEASE_1.7.0_BETA_43.md)).
Delivery status: [beta.44 record](RELEASE_1.7.0_BETA_44.md).

## 简体中文

- 手记 Office 封面采用渐进显示：现代 Word／Excel／PowerPoint 先显示带“摘要”标识的真实
  内容，系统缩略图就绪后再自动升级；系统超时或只返回图标时保留明确摘要，不显示空白或
  通用图标。老格式与超过 48 MiB 的文件仍先走系统缩略图路径。
- 摘要来自文档自身内容但有明确上限（最多 240 个字段；Excel 只取第一张工作表），
  不等于原始排版；无法解析时明确显示预览不可用。
- 严格“仅系统缩略图”的 7 项检查改为独立诊断记录：完整执行、且失败均为已知系统不可用
  标记时不阻断功能验收；缺结果、跳过、崩溃或未标记失败仍会阻断。
- 修复 Office 顶栏返回按钮的辅助功能标识被父容器覆盖的问题；修复本地化键未命名空间导致
  构建前测试失败的问题，并增加构建前纯 Python 本地化检查。

这是测试候选版本，尚未上传 TestFlight。云端构建使用你自己的 GitHub 配置；
Linux／macOS 产物不是 iOS 可安装程序。原生 Office／Pencil 操作、iPad 本地模型稳定性
与真机冷启动仍需分别验收。RDP 未作为可用 App 功能交付。

## English

- Notes Office covers now render progressively: modern Word/Excel/PowerPoint cards
  show a labelled real content summary first and upgrade to the system thumbnail
  when it settles. A timeout or icon-only result keeps the explicit summary instead
  of a blank or generic icon. Legacy formats and files above 48 MiB keep the
  system-thumbnail-first path.
- Summaries are bounded (at most 240 fields; Excel reads the first sheet only) and
  are not an original-layout render; unparseable files remain explicitly
  unsupported.
- The seven strict system-thumbnail-only checks moved to a separate diagnostic
  record: a complete run whose failures carry only the known
  Quick-Look-unavailable markers no longer blocks functional acceptance, while
  missing, skipped, crashed or unmarked results still block.
- Fixed the Office header back button losing its accessibility identifier to the
  parent container, and the non-namespaced localization key that failed pre-build
  tests; added a pure-Python localization catalog check before builds.

This is a test candidate and has not been uploaded to TestFlight. Cloud builds use
your own GitHub configuration; Linux/macOS artifacts are not installable iOS
programs. Native Office/Pencil operation, iPad local-model stability and
physical-device cold relaunch still require separate acceptance. RDP is not
delivered as a usable App feature.
