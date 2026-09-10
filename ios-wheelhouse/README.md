# Floe iOS Wheelhouse

为内嵌 CPython 3.13 预编译"没有纯 Python 通用 wheel"的常用包。与 pandas 产线同构：
**CI 构建候选 → 人工核验 → 不可变 GitHub Release → install 脚本 SHA-256 pin**。

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
- scipy / scikit-learn / statsmodels：iOS 无 Fortran/LAPACK 工具链，**不可行**，继续走 Pyodide(WASM) 或 SSH 远端。
- Rust 包（orjson / pydantic-core）：maturin 交叉链路为实验项，先在 CI 验证再 pin。
