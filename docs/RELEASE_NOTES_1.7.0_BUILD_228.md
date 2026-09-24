# Floe 1.7.0 (228) — release notes / 发布说明

**Status / 状态：云端 App 构建、未签名 IPA、签名上传、GitHub 预发布和 Floe QA 内部 TestFlight 可安装状态均已核实；真机功能尚未验收。** Immutable tag `v1.7.0-beta.85` binds source `ed8f233a432f64df6475d767d82ace2d77b15a63`. [Release run 36009125622](https://github.com/JiangNanGenius/floe-agent/actions/runs/36009125622) produced the [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.85) and retained the unsigned IPA (739,478,368 bytes; SHA-256 `1cfe17ba4e95f869bf962d3a1238f333b6525fddfc1dde1b295f78a262d95076`). [Prepare run 36015637207](https://github.com/JiangNanGenius/floe-agent/actions/runs/36015637207) read back both beta-note locales; [verify run 36015717443](https://github.com/JiangNanGenius/floe-agent/actions/runs/36015717443) confirmed Apple `VALID`, unexpired, sole private internal Floe QA group and `IN_BETA_TESTING` at 2026-09-24T14:50:39Z.

## 简体中文

Build 227 的 iPad 反馈指出三个阻断问题：IDE 文件树中的 DOCX、XLSX、PPTX 一直停在“正在打开文档”；PPTX 预览可见，但进入编辑后仍停住；本地 MLX 模型在普通聊天和测速中失败或闪退。窄宽度 Git 侧栏操作按钮尺寸不均。以上问题不因源码修改或宿主编译而自动视为已修复。

Build 228 将 IDE Office 标签接入现有共享文档会话的实际打开流程，并在失败时结束等待、给出重试。PPT 原生宿主对已加载且页面尺寸已确定、但首个 tile 尚未到达的文档提供有界的编辑入口后备；成功状态仍要求编辑后的真实绘制，不把页面尺寸误报成首帧。宿主修改必须经云端重建、固定产物和 App 打包检查。DOCX/XLSX 仅作防回归验证，现有 Office 路由和保存逻辑保持不变。

Office 宿主已在[云端运行 36000058922](https://github.com/JiangNanGenius/floe-agent/actions/runs/36000058922)编译、链接并打包，产物 SHA-256 `7b6a4c8f519009ddc51db5183fd0e05e9f4a617de51b3777582412c48d93d4d3` 已写入固定锁文件。此项证明源码和宿主产物一致，**不证明** PPT 已在 iPad 上出现可编辑首帧或保存成功。

IDE Git 侧栏的窄宽度操作采用一致的触控目标。运行面板提供自动、单核、双核选择，并将请求交给 Linux 启动链。双核 `fork/exec` 与 9P 已通过云端真实客体检查；修正后的 S5 等量 `dd` 工作负载中，单核中位数 1.69 秒、双核 1.93 秒，未达到 1.10 倍加速门槛。正式版继续以单核安全门拒绝显式双核请求，不静默降档；其他工作负载的收益仍待测。选择本地模型时提前执行与活跃 Linux 客体的冲突确认；取消不改变原有选择或停止客体。Qwen 多 token 预填充现由固定的 `mlx-swift-lm` 本地补丁走现有逐步运算路径，单 token 解码仍保留融合内核；Office 不再于启动时预热并安装全进程信号处理器。云端 macOS 宿主使用同一 Qwen 快照完成 3147 token 输入及多段预填充，未覆盖 iPad Metal/内存行为。许可原文并入现有一份开源声明。MLX 加载与普通对话的设备级故障须另有实际运行证据，不能仅凭宿主结果宣称已修复。

云端 App、原生宿主和 Linux SMP 分别验证。真机需重点确认：MLX 加载、测速、普通与工具对话；IDE 中 DOCX/XLSX/PPTX 的打开；工作区、手记与 IDE 中 PPTX 的编辑、保存、关闭重开；Git 窄侧栏触控；选择本地模型前的 Linux 冲突确认。构建、未签名 IPA、签名上传、Apple `VALID`、Floe QA 可安装和设备体验逐项记录。

## English

Build 227 iPad feedback identified three blocking regressions: DOCX, XLSX and PPTX tabs opened from the IDE file tree stay on “Opening document”; PPTX preview renders but edit entry stalls; and the local MLX model fails or crashes in ordinary chat and benchmark. Narrow Git sidebar actions also have inconsistent touch sizes. Source edits and host compilation alone do not close these reports.

Build 228 opens IDE Office tabs through the existing shared document session and ends failed waits with a retry path. The PPT native host has a bounded edit-entry fallback for a loaded, sized document whose first decoded tile is delayed; readiness still requires a real paint after entering edit mode. A changed host must be rebuilt in cloud CI, pinned, and checked in the App payload. DOCX/XLSX are regression checks; existing Office routing and save behavior stay in place.

The Office host [cloud run 36000058922](https://github.com/JiangNanGenius/floe-agent/actions/runs/36000058922) compiled, linked and packaged the updated framework; its SHA-256 `7b6a4c8f519009ddc51db5183fd0e05e9f4a617de51b3777582412c48d93d4d3` is pinned. This proves source/artifact agreement, **not** an editable PPT first frame or successful save on an iPad.

Narrow IDE Git actions use consistent touch targets. The Run sheet offers automatic, one-core and two-core choices and passes the request to Linux startup. Real dual-hart `fork/exec` and 9P passed cloud guest checks; the corrected S5 equal-work `dd` benchmark measured medians of 1.69 seconds on one hart and 1.93 seconds on two, below the 1.10x speedup gate. The shipping single-core gate still refuses explicit two-core requests without silently downgrading them; other workloads need separate measurement. Selecting an on-device model asks to resolve an active Linux conflict before changing selection; cancel keeps the previous model and guests. A pinned local `mlx-swift-lm` patch routes multi-token Qwen prefill through the existing per-step operations while retaining the fused single-token decode path. A macOS cloud host completed a 3,147-token prompt with the same Qwen snapshot, but this does not verify iPad Metal or memory behavior. Office no longer prewarms at app launch and installs its process-wide signal handler before chat. Its MIT notice is included in the existing unified declaration. The MLX device failure remains open until actual loading and chat evidence proves a repair.

Cloud App compilation, native Office host qualification and SMP guest qualification are separate checks. Physical iPad retesting must cover MLX load, benchmark and ordinary/tool chats; DOCX/XLSX/PPTX IDE tabs; PPTX edit, save and reopen in Workspace, Notes and IDE; narrow Git controls; and the Linux conflict prompt at local-model selection. Build, retained unsigned IPA, signed upload, Apple `VALID`, Floe QA availability and device behavior will be recorded separately.
