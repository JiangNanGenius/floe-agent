# Build 235 feedback repair — candidate work / 候选修复

This record describes work after Build 234; it is not a release or device acceptance record.
本文记录 Build234 后的候选修复，不代表已经发布或通过真机验收。

## Office

The primary review confirmed that a category implementation replaced the pinned upstream WebKit termination callback, suppressing its document-close path. The repair uses a subclass that calls upstream cleanup before notifying the host. The primary also strengthened the regression check to reject the overriding category and guarded a diagnostic field against unexpected types.

主线程确认：原有 category 覆盖了固定上游版本的 WebKit 终止回调，跳过上游文档关闭路径。候选改为子类先调用上游清理，再通知宿主；同时加强回归检查，避免重新引入覆盖，并检查诊断字段类型。

Bounded, content-free render-progress and stalled-evaluation events now identify readiness before the first editable frame. The render readiness rules and timeout were not relaxed. Fourteen local stage checks passed, including Objective-C++ declaration-order compilation. Cloud host run 36510871917 passed compilation, linking and Swift import; run 36511834020 verified 4,780 resource files before pinning the artifact. These checks do not establish device rendering.

新增有数量上限、不含文档内容的渲染进度和求值停滞事件，用于定位可编辑首帧之前的状态。没有放宽首帧条件或延长超时。14项本地阶段检查通过，包含 Objective-C++ 声明顺序编译。云端宿主36510871917通过编译、链接和 Swift 导入；36511834020核验4,780个资源文件后固定产物。这些检查不能证明真机渲染正常。

**PPT crash cause remains unconfirmed.** Device diagnostics show an abrupt process exit shortly after deferred edit entry; they do not include a matching current-build native crash stack. The last memory sample does not establish memory exhaustion. The callback defect is proven in source but is not proven to have caused this crash. PPT idle stability, editing, saving and reopening remain device acceptance items.

**PPT 闪退根因仍未确认。** 设备日志支持编辑等待后不久发生非正常进程退出，但缺少匹配当前构建的原生崩溃栈。最后的内存采样不能证明内存耗尽。回调覆盖是确定的代码缺陷，尚不能认定它导致本次闪退。PPT 静置稳定性、编辑、保存和重开继续等待真机验证。

## Linux and local model / Linux 与本地模型

Linux now uses a bounded, reusable read buffer for image hashing and cancellation-aware verification. Service-owned phase progress directly updates the native install card, with generation guards against stale callbacks. The execution-module suite passed 422 XCTest and 222 Swift Testing checks. Two failures in the separate Core/Tools run remain recorded and have not been established as baseline failures. Full App compilation and iPad installation remain pending. Host read-loop measurements support fixed-buffer memory use, but do not constitute an iPad installation pass. Local-model tool-call repairs remain under review. Model changes must retain canonical tool validation and cloud-provider behavior; two real tool-result continuation rounds remain required evidence.

Linux 镜像校验已改用有界复用缓冲区，并在校验过程中响应取消。服务管理的阶段进度直接更新原生安装卡片，启动代次检查防止旧回调覆盖当前状态。执行模块422项 XCTest 和222项 Swift Testing 通过；另一次 Core/Tools 检查的两个失败已保留，尚不能认定为基线问题。完整 App 编译和 iPad 安装仍待验证。宿主读取循环测量支持固定缓冲区方案，但不代表 iPad 安装通过。本地模型工具调用修复仍在审查。本地模型修改必须保留真实工具校验，不影响云端模型；仍需两轮真实工具结果续答证据。
