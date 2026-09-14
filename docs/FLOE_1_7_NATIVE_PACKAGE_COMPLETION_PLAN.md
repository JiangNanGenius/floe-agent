# Floe 1.7 原生软件包补全计划

本文件补充本轮修复、完整验证与内部 TestFlight 交付计划。日期：2026-09-15。以下是实施要求，不是完成声明。

## 当前核对结果

- `pool/manifest.json` 的 15 项全部为 pending，未提供产物 URL 和 SHA-256；`build_pool.py` 会跳过这些条目。
- 历史清单包括原生 Node SQLite、sharp/libvips，以及 WASI uutils、ripgrep、Typst、SQLite CLI；不能因为目前安装器拒绝原生载荷而将其从本轮漏掉。
- GitHub 发布列表可见 pandas、regex、PyYAML、MarkupSafe、zstandard、brotli、greenlet、frozenlist、multidict 的 runtime 发布。发布存在不等于当前 App 完整链路通过。
- 当前证据尚不能证明上述 Node 和 WASI 候选已经完成。实施前核查历史分支、CI 和私有产物，记录源码、版本、摘要和实际状态，复用有效成果。
- SQLite 候选将 better-sqlite3、sqlite3、上游地址和单一版本混写；必须拆分为独立条目，分别验证，不能沿用含混版本或硬编码 ABI。

## 归属和入口

| 类型 | 所属生态 | 安装与执行入口 |
|---|---|---|
| Python wheel | Python/pip | 纯 Python 包由 pip 安装；原生 iOS 扩展按当前签名框架链路构建期内置 |
| Node 原生扩展 | npm/pnpm | JavaScript 包由所选管理器解析；已适配原生实现通过匹配的内置模块加载机制提供 |
| Unix 命令 | Shell/APT | iOS 移植命令构建期集成；可运行 WASI 模块及数据由兼容软件源管理 |
| 普通 Linux ELF | Linux | 不作为 iOS 可直接运行的载荷；须另行移植或明确采用 WASI 实现 |

APT 的常规 Agent 入口收归 Shell：apt、apt-get 等命令与设置 UI 共用服务。旧 Tool 仅为历史记录/调用保留兼容，不进入普通工具发现。APT 不替代 pip/npm 的依赖解析；若系统包提供语言运行时组件，归属清单须说明提供关系，防止重复覆盖或卸载。

## 本轮逐项工作

1. Python：核对已发布 wheel 的可下载性、摘要、ABI、设备/模拟器、依赖、签名嵌入和完整 App 导入。继续补齐常用包清单；SciPy/scikit-learn 的旧文档与候选清单存在结论冲突，须核实可行性，不能以 WASM 结果冒充原生通过。
2. Node SQLite：分别核对 better-sqlite3 和 sqlite3 的源码与许可、Node/N-API 兼容性、iOS 构建、静态注册或签名加载路径。验证建库、事务、查询、关闭重开及两环境隔离。
3. sharp：核对 sharp、libvips 及传递原生依赖，建立设备/模拟器产物及完整 App 加载链路。验证真实图片缩放、裁剪、格式转换和文件重新读取；保留许可与通知文件。
4. Unix/WASI：逐项核对 uutils、ripgrep、Typst、SQLite CLI 的移植、WASI imports、文件预打开、stdin/stdout、退出码和资源限制；未适配功能明确报错。
5. 其他历史条目：TypeScript、ESLint、Jest、Webpack、clang/WASI 工具链和 Noto 字体全部保留在追踪表。尤其验证子进程依赖、编译器本体能否在目标设备运行，不能将桌面交叉编译工具链当作设备可执行程序。
6. 每项必须形成“已有成果/待构建/待接入/待验证/阻塞及原因”的结论，不能把 pending 自动改成 ready，也不能以候选数量宣传可用能力。

## 管理器与二进制集成

- npm/pnpm 保留自动、npm、pnpm 选择；自动遵循项目 packageManager 和唯一锁文件，无约束时默认 npm，冲突明确提示。
- 预编译 Node 模块匹配包版本、Node/N-API、平台、架构和最低系统版本；不兼容版本在安装前拒绝。
- npm 与 pnpm 必须分别真实加载同一受支持原生模块，验证 pnpm 布局不会破坏绑定查找。
- 不以放开任意安装脚本、下载任意原生代码、忽略签名或改变证书验证解决失败。
- 环境级 JavaScript/Python 包、只读基础原生组件和 APT 命令载荷分别登记归属；显示版本、来源、兼容状态和可用更新路径。
- 原生组件只能随新 App 更新时明确说明；运行时包管理器不能伪装完成原生版本升级。

## Floe 官方软件源：统一发布和获取

用户要求：完成适配的包和构建产物发布到 Floe 自有仓库，并提供模型和包管理器可使用的稳定获取方式。产品名称统一为“Floe 官方软件源”，不是新增编程语言，也不新增一个需要 Agent 专门学习的独立安装 Tool。

- 复用现有 Floe 仓库、不可变 GitHub Release 产物和签名发布链；统一目录入口，分别提供 Python、Node.js、Shell/APT、WASI 分区。源域名和路径以部署配置为准，不在未部署时写成可用 URL。
- 保留标准包名及上游版本含义，例如 requests、sharp、better-sqlite3、ripgrep。只有真正修改过的发行版本才使用合法的构建版本标记；不将所有语言包强行改为 floe-* 名称。
- 每条记录包括生态、标准包名、版本、上游来源、源码提交、许可证、依赖、目标系统/架构、Python或Node ABI、最低 App 版本、文件大小、摘要、签名/来源证明和安装方式。
- 所有通过验证且可再分发的本轮产物进入自有仓库，包括纯代码包、预编译 wheel、Node 原生构建、WASI 命令和必要数据。不能再分发的条目明确排除并说明原因；不将候选或测试夹具放入可用目录。
- Python 分区提供标准 Simple 索引，Node.js 分区提供兼容的包元数据和 tarball 获取入口，APT 分区使用现有 OpenPGP Release 签名链。WASI 命令进入统一目录及 Shell 命令适配，不伪装成 Python/Node 包。
- 公共源码包可以继续从官方公共源获取，但 Floe 托管包按名称明确绑定来源；不简单合并多个索引后取最高版本，避免同名包覆盖经过适配的版本。
- 对适配包的必要依赖固定版本、摘要和来源；无需镜像整个 PyPI/npm。源不可用时仅使用已验证缓存，否则明确失败，不静默替换成不兼容上游构建。
- 设置中的 Python、JavaScript 和 Shell 包管理页预置 Floe 官方软件源，显示有效来源、支持平台、安装/更新方式、进度和错误恢复。npm/pnpm 选择仍按环境及项目规则处理，两者读取同一 Node 包目录。
- Agent 从现有工具发现及环境能力报告得知源和可用命令，通过 python3 -m pip、npm、pnpm、apt 获取包；不要求模型拼接内部资产 URL 或管理签名密钥。
- 可运行时安装的纯代码、WASI、数据直接通过对应管理器安装。需随 App 签名的原生组件发布为构建输入并登记运行时兼容关系；已内置版本可供环境使用，未内置版本明确要求更新 App，不能仅下载后返回安装成功。
- 索引发布前检查所有产物存在、摘要匹配、依赖可解析，并原子更新目录。旧版本和固定 URL 保持不可变，索引可回滚。
- 发布验收必须从实际公开软件源，经完整 App 的 pip/npm/pnpm/APT 跑通查询、下载、校验、安装和执行；覆盖缓存、断网、篡改、错误平台、并发安装和恢复。GitHub 上传成功不等于软件源可用。

## 验收及交付

- pip、npm、pnpm、APT 均覆盖 UI 与 Shell/Agent 入口、实际执行、取消、失败恢复、升级卸载和环境隔离。
- 原生 npm 验收包含真实 SQLite 数据库及 sharp 图像产物；Unix 命令验收包含文本检索、文件处理、排版 PDF 和数据库操作。
- 官方目录仅发布验证后的具体版本及匹配摘要；原生构建产物与随 App 签名集成的证据分开记录。
- 云端重型构建，完整 App 在 iPad/iPhone 及两 SDK 验证；原生真机缺失证据明确待补，不算通过。
- 内部 TestFlight、GitHub 预发布和 Feather 使用匹配版本及不可变来源；更新常用包矩阵、用户指南和演示素材。
- 本文件所有未通过项保留可见状态；不得通过删去历史承诺来宣称本轮全部完成。
