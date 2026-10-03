# Floe 1.7.0 Build240 — device feedback repair / 真机反馈修复

## 简体中文

- PPT：修正进入编辑时的 JSON 片段序列化异常，修复原生回调生命周期，并让迟到的真实绘制在同一文档代际内有界恢复。保存仍要求实际绘制及编辑确认；未验证文档不会被当作保存成功。
- Linux：统一安装与运行状态，减少设置页重复恢复工作，按实际启动镜像判断双核资格；已有环境不会凭标题或内核名称自动获得双核。
- 搜索：调整已配置搜索提供方在部分代理网络中的连接校验，保留任意 URL、私网目标和重定向边界。VPN fake-IP 是待设备验证的解释，本地真实模型搜索回答尚未验收。
- 上下文：已知上下文容量在生成前可见；用量尚未报告时显示等待状态。
- Gitee 只同步源码与 Release，不回到软件加速源。保留 Build239 已验证的镜像及用户已确认好的中文字体。

PPT 证据：完整 Floe App 在云 Xcode 的 iPad mini (A17 Pro)、iOS 27.0 模拟器运行同一合成 PPT。运行 36843561563 完成真实导入、预览、进入编辑、两次插页、静置 120.35 秒、保存关闭和两次重开；主线程核对 GUID 回执、五个文档渲染帧、原生代际与确认链、手记版本 1→2→3→4 及真实四页落盘文件。云端所有门槛通过，本地原始回执和五帧与云端逐字节一致；事件链及保存文件本地复核通过。本地重复像素计算未完成，采用相同源码、同字节输入的云端像素门槛结果，没有修改校验器。历史失败保留。

这是内测候选；此说明不代表已上传或可安装。云模拟器验收不能替代用户物理 iPad 或全部用户文档验收，Build239 真机闪退系统栈仍未匹配。Linux、搜索、上下文变化仍需设备反馈。

## English

- PPT: fixes the JSON fragment serialization exception on edit entry, repairs native callback lifetime, and observes bounded late rendering within the same document generation. Saving still requires real paint and its own edit acknowledgement.
- Linux: aligns installation and running state, avoids redundant settings restoration, and derives dual-core eligibility from the actual booted image.
- Search: adjusts connection validation for configured search providers on some proxy networks while retaining arbitrary-URL, private-target and redirect boundaries. VPN fake-IP remains a device-unverified explanation; real-weight local-model search answers are not accepted yet.
- Context: known context capacity is visible before generation; unreported usage stays pending.
- Gitee remains source/Release synchronization only. Build239 mirrors and the user-confirmed Chinese font repair remain.

Full Floe App cloud Xcode Simulator run 36843561563 passed on an iPad mini (A17 Pro), iOS 27.0, using the same synthetic PPT: import, preview, real edit entry, two slide insertions, 120.35 seconds idle, save/close and two reopens. Primary review checked the GUID receipt, all five document frames, native generation/acknowledgement chain, Notes revisions 1→2→3→4 and the real four-slide saved file. Original receipt/frames byte-match cloud inputs; local trace and persistence replay passed. Optional duplicate local pixel recomputation did not finish; the unchanged cloud pixel gate on identical bytes is authoritative. Original failures are retained.

Internal beta candidate only; this document does not mean uploaded or installable. Simulator acceptance does not replace physical iPad or all-user-document acceptance. The Build239 physical crash stack remains unmatched; Linux, search and context changes still need device feedback.
