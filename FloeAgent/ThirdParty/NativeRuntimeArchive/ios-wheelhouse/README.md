# Floe iOS Wheelhouse

为内嵌 CPython 3.13 预编译"没有纯 Python 通用 wheel"的常用包。与 pandas 产线同构：
**CI 构建候选 → 人工核验 → 不可变 GitHub Release → install 脚本 SHA-256 pin**。

## 1.7 环境与兼容性

wheel 构建成功只证明该产线的测试范围；接入 1.7 还要验证当前环境的安装位置、搜索顺序、ABI、来源/签名、升级与恢复。公共纯 Python 包与预构建原生扩展分开验收，普通 Linux wheel 或 ELF 不能作为 iOS 可运行包。

本轮状态见[兼容性说明](../docs/FLOE_1_7_COMPATIBILITY.md)和[构建验收](../docs/FLOE_1_7_BUILD_AND_ACCEPTANCE.md)。不要以软件包池候选条目数代替已通过 App 实测的版本数。

## 目录

- `manifest.json` — 每包构建配方：sdist URL/SHA-256、冒烟脚本、额外 env、rust 标记
- `smoke/<pkg>_smoke.py` — cibuildwheel 在 iOS testbed 里真跑的 import+最小功能断言
- `out/` — 构建输出（gitignored）

## 流程

1. **构建候选**（GitHub Actions，手动）：
   `ci.yml` → `build-native-wheels`，输入包名（`manifest.json` 里的 key）、`pandas`（走既有产线）或 `all`。
   产物：`native-wheels-ios-<pkg>` artifact（device `iphoneos` + simulator `iphonesimulator` 双 wheel）。
   - 也可本地构建：`bash FloeAgent/scripts/build_ios_wheel.sh <pkg>`（需要 Xcode 26.6 + cibuildwheel 4.2.1）。
2. **人工核验**：artifact 通过 ≠ App 验收。对照 pandas 的先例（`FloeAgent/scripts/pandas-runtime-release.md`）。
3. **发布**：打不可变 Release tag `runtime-<pkg>-<version>-cp313`，上传双 wheel，记录双 SHA-256。
4. **接入 App**：把 pin 行写进 `FloeAgent/scripts/install_python_binary_packages.sh` 的 `packages=()` 表
   （`name|version|device_sha|sim_sha|url_template|minimum_ios|flatten`），并：
   - 更新 `LocalPythonService.runtimeManifest()` 探测清单（保持"探针为准"）；
   - 更新 `FloeAgent/scripts/license_inventory.sh` 的上游清单与 `LICENSES-THIRD-PARTY.md`；
   - 在 `LocalPythonRuntimeTests` 增加 import 冒烟断言。
5. **验收**：CI `LocalPythonRuntimeTests`（模拟器）+ 真机 TestFlight 用例。

## 硬性边界

- **不做运行时下载原生代码**（Apple 2.5.2）：所有原生 wheel 构建期内置，`.so` 全部转签名 XCFramework。
- scipy / scikit-learn / statsmodels：当前产线未完成所需 Fortran/BLAS/LAPACK 的交叉构建与 ABI 验证，暂未内置；保留原生构建评估，不将历史构建障碍写成永久不可行。现有远端或 WASM 能力需单独验证。
- Rust 包（orjson / pydantic-core）：maturin 交叉链路为实验项，先在 CI 验证再 pin。

## lxml 候选产线（2026-09-15）

`lxml` 配方固定 6.1.3 sdist，并使用 `prepare_lxml_ios.py` 分别交叉构建静态 libxml2 2.14.6 和 libxslt 1.1.45，三个源码均校验 SHA-256。编译配置拒绝 macOS 或未知架构，禁止误用 Homebrew 库；依赖版权声明随 wheel 包含。测试床执行中文 XML、XPath、XSLT，以及 python-docx 1.2.0 / python-pptx 1.0.2 的生成、保存和重读。

[CI 34923284307](https://github.com/JiangNanGenius/floe-agent/actions/runs/34923284307) 已生成双 wheel，iOS 模拟器测试床完成上述功能。14 个原生模块均为对应 arm64 平台、最低 iOS 17，动态依赖仅 Python.framework 和 Apple 系统库。wheel 0.46.3 将上游错误的 iOS 13 标签校正为 17；已逐文件确认只有 WHEEL/RECORD 元数据改变。候选发布于 [runtime-lxml-6.1.3-cp313](https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-lxml-6.1.3-cp313)，携带来源和双 SHA-256。App 已添加构建 pin 与 Office Python 保存重读测试，完整 App 验证及真机验收仍待完成。wheel 构建与 App CI 独立运行。
