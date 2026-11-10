# Contributing to Floe Agent

Repository instructions for coding agents: [AGENTS.md](AGENTS.md).

Thank you for helping build Floe Agent. The project has an App Store release and separate test channels; its interfaces continue to evolve. Changes involving credentials, browser control, files, or remote computers require especially careful review. [简体中文贡献指南](CONTRIBUTING.zh-CN.md)

<a id="floe-17-integration-workflow"></a>
## Current development workflow

Start from the actual current `main` checkout and inspect status, relevant diffs and active worktrees; create a scoped `codex/` branch only when isolation is needed. Read the [engineering guide](FloeAgent/README.md), [architecture](docs/ARCHITECTURE_OVERVIEW.md) and [local qualification guide](docs/FLOE_LOCAL_QUALIFICATION.md). Active plans and historical snapshots are separated in the [documentation hub](docs/README.md). Preserve unqualified changes, reproductions and recovery evidence; reconcile overlapping changes individually.

Use focused local tests and relevant local App builds; cloud CI supplies independent checks and release workflows. Update both language guides when user behavior changes. Report the tested commit, SDK, device/simulator and actual output. Runtime lock checks must remain read-only. Generated Xcode changes must match `project.yml`. Uploading an artifact is not release acceptance.

## Before you start

1. Read the [product overview](PRODUCT.md), [current status](docs/CURRENT_STATUS.md), and [security policy](SECURITY.md).
2. Search existing issues and pull requests for related work.
3. Open an issue before a large feature, dependency change, architecture change, or security-sensitive change.
4. Keep pull requests focused and explain the user impact, trade-offs, security impact, and verification evidence.

Do not open a public issue for a vulnerability. Follow the private process in [SECURITY.md](SECURITY.md).

## Development checkout

Use the current `main` baseline:

```bash
git clone https://github.com/JiangNanGenius/floe-agent.git
cd floe-agent
brew install xcodegen
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash FloeAgent/scripts/gen_project.sh
open FloeAgent/FloeAgent.xcodeproj
```

Use the installed full Xcode and toolchain required by [AGENTS.md](AGENTS.md); the app supports iOS/iPadOS 26 and newer. After changing targets, resources, settings, versions or schemes in `project.yml`, regenerate and inspect the matching project:

```bash
bash FloeAgent/scripts/gen_project.sh
git diff -- FloeAgent/project.yml FloeAgent/FloeAgent.xcodeproj/project.pbxproj
```

The generation script regenerates first and reports remaining tracked changes; inspect its output without discarding unrelated work. Choose checks for the affected behavior. `FloeAgent/scripts/local_build.sh` covers a cross-platform SwiftPM subset; it does not build the iOS App. Simulator runs follow the pinned iPad and locking rules in AGENTS.md.

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
