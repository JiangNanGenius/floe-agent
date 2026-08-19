# Floe Agent 云构建与 TestFlight 发布手册

最后实测：2026-08-19

仓库：`JiangNanGenius/floe-agent`

当前成功基线：`v1.3.3` / build `24` / commit `212c9aea5207da11607c0759b398ea117b9adbc2`

这份文档是当前仓库的实际运行手册，不是通用 iOS 发布示例。WorkBuddy 在修改 CI、签名配置或发布步骤前，应先重新读取本文引用的工作流和脚本，以仓库当前内容为准。

## 1. 操作边界

- 本项目优先使用 GitHub Actions 完成完整 Xcode 构建、Release 归档和 TestFlight 上传。本地 Mac 内存较小，只做代码检查、定向测试和必要的轻量验证。
- WorkBuddy 可以在没有额外授权时检查代码、修改代码、准备版本、运行普通 CI。
- 创建或推送发布标签、触发 TestFlight、修改 App Store Connect、证书、描述文件、发布地区或合规声明，必须有用户明确授权。
- 不得把证书、私钥、`.p8`、`.p12`、描述文件或真实 Secret 值写入仓库、文档、Issue、PR、聊天记录或日志。
- GitHub Secrets 无法读取回原文。丢失原始文件时应轮换，而不是尝试从 Actions 中恢复。

## 2. 当前发布架构

普通 CI：`.github/workflows/ci.yml`

- 触发条件：`main` push、Pull Request、手动 `workflow_dispatch`。
- macOS 26 / Xcode 26.6：生成 Xcode 工程，构建 iPhone 17 Pro 与 iPad mini (A17 Pro)，执行 SwiftPM 构建和测试。
- Ubuntu / Swift 6.2：编译跨平台 targets。
- 生成并上传：Xcode result bundles、gitleaks 报告、SPDX SBOM、第三方许可证清单。

发布流水线：`.github/workflows/release-unsigned-ipa.yml`

- 推荐触发方式：推送符合 `vX.Y.Z` 的不可变 Git 标签。
- 第一阶段：重跑 Swift 测试和 Release 模拟器构建，扫描源码，生成未签名真机 App/IPA，验证元数据并扫描 App，生成 provenance。
- 第二阶段：从同一个标签重新 checkout，安装分发证书和两个描述文件，签名归档并上传 TestFlight。
- 第三阶段：只有 TestFlight transport 接受上传后，才发布 GitHub prerelease 及未签名 IPA、SHA-256、SBOM、许可证、测试摘要和扫描报告。
- GitHub 上的 IPA 是未签名审计制品，不能当作 TestFlight/App Store 安装包。

关键脚本：

- `FloeAgent/scripts/bootstrap_python_runtime.sh`：下载并校验固定 SHA-256 的 CPython 3.13 iOS runtime。
- `FloeAgent/scripts/gen_project.sh`：通过 XcodeGen 生成工程并检查漂移。
- `FloeAgent/scripts/pin_check.sh`：检查 Swift 依赖是否固定到版本或 revision。
- `FloeAgent/scripts/release_preflight.sh`：校验标签、版本、build number、bundle ID 和扩展显示名。
- `FloeAgent/scripts/secret_scan.sh`：gitleaks 扫描完整 Git 历史。
- `FloeAgent/scripts/sbom.sh`：生成 SPDX SBOM。
- `FloeAgent/scripts/license_inventory.sh`：生成依赖许可证清单并拒绝 GPL-family 依赖。

## 3. 当前 Apple 标识与签名契约

这些 ID 不是密码，可以记录；改变任何一项都必须同步更新 App ID、描述文件、entitlements、`project.yml`、ExportOptions 和发布工作流。

| 项目 | 当前值 |
|---|---|
| Apple Team ID | `QYL72C43K6` |
| 主 App Bundle ID | `org.floeagent.ios` |
| 屏幕共享扩展 Bundle ID | `org.floeagent.ios.screenshare` |
| App Group | `group.org.floeagent.ios` |
| CloudKit container | `iCloud.org.floeagent.ios` |
| 主 App profile 名称 | `Floe TestFlight AppGroup 2026` |
| 扩展 profile 名称 | `Floe Screen Share TestFlight AppGroup 2026` |
| 签名证书类型 | `Apple Distribution` |
| Export method | `app-store-connect` |
| 最低 iOS | `26.0` |

主 App 描述文件必须满足：

- `application-identifier` 为 `QYL72C43K6.org.floeagent.ios`。
- 包含 App Group `group.org.floeagent.ios`。
- 与当前 Apple Distribution 证书和 Team 匹配。
- Profile 名称必须与上表完全相同，除非同时修改全部仓库配置。

屏幕共享扩展描述文件必须满足：

- `application-identifier` 为 `QYL72C43K6.org.floeagent.ios.screenshare`。
- 包含同一个 App Group `group.org.floeagent.ios`。
- Profile 名称必须与上表完全相同。

主 App 还使用 CloudKit container。重新生成 App ID/profile 时，不能遗漏现有 capabilities，否则签名可能成功但运行功能会失效。

## 4. 必需的 GitHub Actions Secrets

仓库 Settings → Secrets and variables → Actions 中必须存在以下 7 项：

| Secret 名称 | 内容 | 来源 |
|---|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | Apple Distribution `.p12` 的单行 Base64 | 从含私钥的钥匙串导出 |
| `APPLE_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 | 导出时自行设置 |
| `APPLE_PROVISIONING_PROFILE_BASE64` | 主 App `.mobileprovision` 的单行 Base64 | Apple Developer Profiles |
| `APPLE_SCREENSHARE_PROVISIONING_PROFILE_BASE64` | 屏幕共享扩展 `.mobileprovision` 的单行 Base64 | Apple Developer Profiles |
| `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64` | `AuthKey_XXXXXXXXXX.p8` 的单行 Base64 | App Store Connect API Keys |
| `APP_STORE_CONNECT_API_KEY_ID` | API Key ID | App Store Connect API Keys |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID | App Store Connect API Keys 页面 |

不需要以下旧式上传凭据：

- Apple ID 密码
- App-specific password
- `FASTLANE_*`
- `MATCH_*`

上传使用 App Store Connect API Key。该 Key 必须有权访问 Floe Agent 并上传构建；建议使用专门的发布 Key，给予完成上传所需的最小权限，不要复用个人日常 Key。

## 5. 首次生成 Apple 凭据

### 5.1 Apple Distribution 证书

1. 在受信任 Mac 的 Keychain Access 创建 CSR，确保私钥留在钥匙串中。
2. 在 Apple Developer → Certificates 创建 `Apple Distribution` 证书。
3. 下载并安装 `.cer`。
4. 在 Keychain Access 中同时选择该证书及其私钥，导出为 `.p12`。
5. 设置强密码；`.p12` 与密码分开保管。
6. 确认证书未过期、未撤销，并属于 Team `QYL72C43K6`。

只有 `.cer` 没有对应私钥时无法用于 CI 签名，必须在持有原始私钥的 Mac 上导出 `.p12`，或重新签发证书。

### 5.2 App IDs 与 capabilities

在 Apple Developer → Identifiers 中确认：

- `org.floeagent.ios` 已启用项目实际使用的 App Group 与 iCloud/CloudKit capability。
- `org.floeagent.ios.screenshare` 已启用 App Group。
- 两个 ID 都指向 `group.org.floeagent.ios`。
- CloudKit container 为 `iCloud.org.floeagent.ios`。

### 5.3 App Store provisioning profiles

为两个 Bundle ID 分别创建 App Store Connect/App Store distribution profile：

1. 主 App profile 命名为 `Floe TestFlight AppGroup 2026`。
2. 扩展 profile 命名为 `Floe Screen Share TestFlight AppGroup 2026`。
3. 选择当前有效的 Apple Distribution 证书。
4. 下载两个 `.mobileprovision` 文件。
5. 在本地解码检查名称、application identifier、App Group 和过期时间。

检查示例：

```bash
security cms -D -i /secure/path/Floe.mobileprovision > /tmp/floe-profile.plist
plutil -p /tmp/floe-profile.plist
```

不要把解码后的 profile plist 或原 profile 放入仓库。

### 5.4 App Store Connect API Key

1. App Store Connect → Users and Access → Integrations → App Store Connect API。
2. 创建专用发布 Key，并限制到所需权限和应用范围。
3. 创建后立即下载 `.p8`；Apple 通常只允许下载一次。
4. 单独记录 Key ID 与 Issuer ID。
5. 把 `.p8` 放在加密凭据库，不要放入项目目录。

## 6. 安全写入 GitHub Secrets

优先使用 GitHub 网页逐项粘贴，或使用已登录且指向正确仓库的 `gh` CLI。不要把真实 Secret 写在 `--body '真实值'` 中，因为它可能进入 shell history。

检查目标仓库：

```bash
gh auth status
gh repo view JiangNanGenius/floe-agent
```

文件型 Secret 可直接编码后送入 `gh secret set`，不落地中间 Base64 文件：

```bash
openssl base64 -A -in /secure/path/distribution.p12 \
  | gh secret set APPLE_CERTIFICATE_P12_BASE64 --repo JiangNanGenius/floe-agent

openssl base64 -A -in /secure/path/Floe.mobileprovision \
  | gh secret set APPLE_PROVISIONING_PROFILE_BASE64 --repo JiangNanGenius/floe-agent

openssl base64 -A -in /secure/path/FloeScreenShare.mobileprovision \
  | gh secret set APPLE_SCREENSHARE_PROVISIONING_PROFILE_BASE64 --repo JiangNanGenius/floe-agent

openssl base64 -A -in /secure/path/AuthKey_XXXXXXXXXX.p8 \
  | gh secret set APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64 --repo JiangNanGenius/floe-agent
```

字符串型 Secret 建议不带 `--body` 运行命令，然后按交互提示粘贴：

```bash
gh secret set APPLE_CERTIFICATE_PASSWORD --repo JiangNanGenius/floe-agent
gh secret set APP_STORE_CONNECT_API_KEY_ID --repo JiangNanGenius/floe-agent
gh secret set APP_STORE_CONNECT_ISSUER_ID --repo JiangNanGenius/floe-agent
```

只能验证名称和更新时间，不能读回值：

```bash
gh secret list --repo JiangNanGenius/floe-agent
```

## 7. 日常开发的云 CI 方法

普通 PR 会自动运行 CI。需要在功能分支手动运行时：

```bash
gh workflow run ci.yml \
  --repo JiangNanGenius/floe-agent \
  --ref <branch-name>

gh run list \
  --repo JiangNanGenius/floe-agent \
  --workflow ci.yml \
  --branch <branch-name> \
  --limit 5

gh run watch <run-id> \
  --repo JiangNanGenius/floe-agent \
  --exit-status
```

普通 CI 必须至少确认：

- iPhone Simulator build 通过。
- iPad mini Simulator build 通过。
- SwiftPM build/test 通过。
- Linux cross-platform targets 通过。
- Secret scan、SBOM、license inventory 通过。

本地建议只做：

```bash
cd FloeAgent
git diff --check
swift test --filter '<relevant-suite-or-test>'
```

只有定向检查无法定位问题时，才在低并发下运行本地完整构建。完整 iPhone/iPad/Archive 优先交给云端。

## 8. 标准发布流程

以下命令从仓库根目录执行。

### 8.1 审计与版本准备

1. 检查 `git status`，不要覆盖或误提交用户的其他改动。
2. 审阅本次 diff 的功能逻辑、安全边界和迁移兼容性。
3. 修改 `FloeAgent/project.yml` 中主 App 和屏幕共享扩展的：
   - `MARKETING_VERSION`
   - `CURRENT_PROJECT_VERSION`
4. 两个 target 的版本和 build 必须一致。
5. `CURRENT_PROJECT_VERSION` 必须是整数，并严格大于上一发布标签中的 build。
6. 运行必要的定向测试、`git diff --check` 和泄密检查。
7. 提交并推送准备发布的 commit。

不要手改生成工程来代替 `project.yml`；`project.yml` 是签名和版本的主要事实来源。

### 8.2 先跑普通云 CI

```bash
gh workflow run ci.yml \
  --repo JiangNanGenius/floe-agent \
  --ref <release-commit-branch>
```

记录返回的 run URL，并等待全部 jobs 成功。CI 未全绿时禁止打发布标签。

### 8.3 安全创建发布标签

假设新版本为 `v1.3.4`：

```bash
git status --short --branch
git rev-parse HEAD
git ls-remote --tags origin refs/tags/v1.3.4
git tag --list v1.3.4
```

确认远端和本地都没有同名标签后：

```bash
git tag -a v1.3.4 -m "Floe Agent 1.3.4" <verified-commit-sha>
FloeAgent/scripts/release_preflight.sh v1.3.4
git push origin refs/tags/v1.3.4
```

标签推送会自动触发发布工作流。`release_preflight.sh` 要求标签已经存在于本地，因此顺序必须是“创建本地标签 → 预检 → 推送标签”。

### 8.4 监控发布

```bash
gh run list \
  --repo JiangNanGenius/floe-agent \
  --workflow release-unsigned-ipa.yml \
  --limit 5

gh run watch <release-run-id> \
  --repo JiangNanGenius/floe-agent \
  --exit-status \
  --interval 30
```

成功发布必须同时满足：

- `build-verify-release` 成功。
- `Archive and upload the same commit to TestFlight` 成功。
- 日志出现 `Upload succeeded` 和 `EXPORT SUCCEEDED`。
- `Publish GitHub assets only after TestFlight succeeds` 成功。
- GitHub Release 存在且不是 draft。

最后核验：

```bash
gh release view v1.3.4 \
  --repo JiangNanGenius/floe-agent \
  --json url,tagName,name,isDraft,isPrerelease,publishedAt,assets

git ls-remote --tags origin \
  refs/tags/v1.3.4 \
  'refs/tags/v1.3.4^{}'

git status --short --branch
```

TestFlight transport 接受上传只代表包已进入 Apple 处理队列，不代表已经对测试组可见。最终处理状态、合规问题和测试组分发要在 App Store Connect 中确认。

## 9. 手动重跑已有标签

正常发布优先使用标签 push。对已存在标签重新验证时，可手动 dispatch：

```bash
gh workflow run release-unsigned-ipa.yml \
  --repo JiangNanGenius/floe-agent \
  --ref main \
  -f tag=v1.3.4 \
  -f publish=true
```

该方式只能重建已有标签，不能替代版本提交和标签预检。

如果只是 GitHub 网络、runner 或 attestation 临时失败，代码和标签没有变化，可以重跑失败 jobs：

```bash
gh run rerun <release-run-id> \
  --repo JiangNanGenius/floe-agent \
  --failed
```

如果需要修改代码，禁止移动或强推已经发布的标签。必须增加 build number，通常同时增加 patch version，然后创建新标签。

## 10. 常见失败与处理

### `release tag must be SemVer`

标签必须严格为 `v数字.数字.数字`，例如 `v1.3.4`。

### 标签与 MARKETING_VERSION 不一致

修改 `project.yml` 中两个 target 的版本，使其都与标签一致；重新提交。不要修改已推送标签。

### build number 没有递增

`CURRENT_PROJECT_VERSION` 必须大于上一 SemVer 标签的 build。提升 build、提交，并使用新标签。

### profile 名称或 application identifier 不匹配

发布脚本会主动校验两个 profile。重新生成正确 profile；如果确实要改名，必须同步更新：

- `FloeAgent/project.yml`
- `FloeAgent/Config/ExportOptions-TestFlight.plist`
- `.github/workflows/release-unsigned-ipa.yml` 中的期望名称和 App ID

### App Group 缺失

主 App 与扩展 profile 都必须包含 `group.org.floeagent.ios`。只修改 entitlements 而不重新生成 profile 不会生效。

### `security import` 失败

常见原因：`.p12` 密码不对、证书没有私钥、证书过期/撤销、Base64 内容损坏。重新从持有私钥的钥匙串导出并轮换 Secret。

### App Store Connect API 认证失败

检查 `.p8` 是否与 Key ID 对应、Issuer ID 是否正确、Key 是否撤销、权限和 App 范围是否允许上传。不要在日志中打印这些值。

### build number 已被 App Store Connect 使用

Apple 不允许同一版本重复上传同一 build。增加 `CURRENT_PROJECT_VERSION`，提交并创建新标签。

### provenance/ID token 网络超时

例如 `Failed to get ID token` 或 GitHub endpoint `ETIMEDOUT`。如果前面构建/扫描已通过且 commit 未变，这是基础设施失败，可以使用 `gh run rerun <id> --failed`。不要因此移动标签。

### 本地 tag 与远端 tag 冲突

不要直接覆盖、删除或强推。先分别检查：

```bash
git show --no-patch --decorate <tag>
git ls-remote --tags origin refs/tags/<tag> 'refs/tags/<tag>^{}'
```

发布标签默认视为不可变；需要修复时使用新版本。

### Python.framework dSYM 警告

当前上传可能出现 Python.framework 缺少 dSYM 的非阻断警告。它不阻止 TestFlight 接收，也不影响 Python runtime 正常运行，但会降低该预编译原生框架发生崩溃时的符号解析质量。除非上游提供匹配 UUID 的 dSYM，否则不能伪造；应在后续升级 Python.xcframework 时重新检查。

## 11. 密钥轮换与吊销

建议建立到期清单，至少记录证书、两个 profiles 和 API Key 的创建时间、到期时间、负责人，但不要记录私钥正文。

轮换顺序：

1. 创建新证书/Key/profile，不先撤销旧值。
2. 在隔离环境验证 ID、entitlements 和 profile 名称。
3. 更新对应 GitHub Secrets。
4. 手动运行普通 CI，再用一个新的 build/tag 完整发布验证。
5. 确认 TestFlight 上传成功后，再撤销不再使用的旧证书或 API Key。

疑似泄漏时：

1. 立即撤销受影响证书或 API Key。
2. 删除/重建相关 profiles。
3. 更新 GitHub Secrets。
4. 检查 Actions 日志、Git 历史、Release artifacts 和本地终端历史。
5. 即使随后删除了仓库文件，也要把已提交的 Secret 当作已泄漏处理并轮换。

## 12. 仓库与 GitHub 安全建议

- 保护 `main` 和发布标签规则，限制谁能推送 `v*` 标签。
- 对 `.github/workflows/**`、签名配置和发布脚本设置强制 review。
- 不要让不受信任的 commit 获得发布标签；标签所指向的 workflow 代码会接触发布 Secrets。
- Public fork PR 默认拿不到仓库 Secrets，不要通过临时改 workflow 的方式绕过这一保护。
- Release actions 尽量固定到不可变 commit SHA；升级 action 前审阅变更。
- 任何发布前都检查完整 Git 历史和最终 App 制品，而不只扫描当前 diff。

## 13. 2026-08-19 实测记录

- 普通 CI：`https://github.com/JiangNanGenius/floe-agent/actions/runs/32219123563`
- 发布流水线：`https://github.com/JiangNanGenius/floe-agent/actions/runs/32220034125`
- GitHub Release：`https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.3.3`
- TestFlight transport：`Upload succeeded`，build 24 已进入 Apple processing。
- 首次 provenance 步骤因 GitHub ID token endpoint 超时失败；使用 `gh run rerun 32220034125 --repo JiangNanGenius/floe-agent --failed` 后成功。
- 源码和构建后 App 的 gitleaks 报告均无泄漏。

## 14. 给 WorkBuddy 的最短执行清单

1. 读取本手册、两个 workflow、`project.yml` 和发布脚本。
2. 保留用户已有改动；先审计 diff，再修复功能/逻辑问题。
3. 只修改 `project.yml` 中两个 target 的版本/build，并确保 build 递增。
4. 运行定向测试和普通云 CI。
5. 普通 CI 未全绿时停止，不创建标签。
6. 得到明确发布授权后，检查远端无同名 tag，创建 annotated tag，运行 preflight，再推送 tag。
7. 监控到 TestFlight upload、GitHub release 和远端 tag 三者全部成功。
8. 遇到基础设施失败可重跑；遇到代码/签名/版本问题必须修复并使用新版本，绝不移动已发布标签。
9. 最终报告版本、build、commit、CI URL、release URL、TestFlight transport 状态、测试结果、Secret 扫描结果和任何非阻断警告。
