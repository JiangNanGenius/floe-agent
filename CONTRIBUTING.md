# Contributing to Floe Agent

Thank you for helping build Floe Agent. The project ships prerelease builds, its interfaces are still moving, and changes involving credentials, browser control, files, or remote computers require especially careful review. [简体中文贡献指南](CONTRIBUTING.zh-CN.md)

## Floe 1.7 integration workflow

当前整合分支为 `codex/floe-1-7-integration-20260912`。先阅读[实施状态](docs/FLOE_1_7_IMPLEMENTATION_STATUS.md)与[构建验收说明](docs/FLOE_1_7_BUILD_AND_ACCEPTANCE.md)，保留未验收修改、复现输入和恢复证据。不要用整分支覆盖重叠修改。

Use focused local tests and cloud App builds. Update both language guides when user behavior changes. Report the tested commit, SDK, device/simulator and actual output; do not turn an artifact upload into a release claim. Runtime lock check mode must remain read-only. Generated Xcode changes must match `project.yml`.

## Before you start

1. Read the [product overview](PRODUCT.md), [development plan](docs/DEVELOPMENT_PLAN.md), and [security policy](SECURITY.md).
2. Search existing issues and pull requests for related work.
3. Open an issue before a large feature, dependency change, architecture change, or security-sensitive change.
4. Keep pull requests focused and explain the user impact, trade-offs, security impact, and verification evidence.

Do not open a public issue for a vulnerability. Follow the private process in [SECURITY.md](SECURITY.md).

## Development checkout

The active implementation is maintained on `main`. Use:

```bash
git clone https://github.com/JiangNanGenius/floe-agent.git
cd floe-agent
cd FloeAgent
scripts/local_build.sh
```

Requirements are a full Xcode installation with Swift 6.2 and the iOS 26 SDK or newer. Regenerate the committed Xcode project after changing `project.yml`:

```bash
swift build
swift test
xcodegen generate
```

Some iOS-only targets require Xcode rather than a command-line Swift toolchain.

## Pull request checklist

- Add or update tests for changed behavior.
- Run the smallest relevant checks locally and report the exact commands and results.
- Keep credentials, hostnames, personal paths, device identifiers, and private fixtures out of commits.
- Update README or architecture documentation when public behavior or setup changes.
- Preserve English and Simplified Chinese localization coverage for user-facing text.
- Update both English and Simplified Chinese README/user-guide sections when public behavior changes.
- Describe any new network destination, entitlement, dependency, persistence, approval, or privacy behavior.
- Keep generated files and unrelated formatting out of the pull request.

By contributing, you agree that your contribution is licensed under the repository's [Mozilla Public License 2.0](LICENSE).
