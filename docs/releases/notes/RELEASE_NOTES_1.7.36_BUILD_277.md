# Floe 1.7.36 (277) — Continuous handwriting and compact pen controls

Beta candidate. Signing, upload, Apple processing and test-group availability are recorded separately.

测试版候选；签名、上传、Apple 处理及测试组可用状态另行记录。

## 简体中文

- **连续书写**：改进 Office 首笔后重新落笔及已有笔迹控制点附近落笔的处理，避免下一笔被旧选区截获；普通笔、记号笔和荧光笔保存为原生矢量样式，切换只影响后续笔迹。
- **书写入口**：工具栏直接开关书写，独立设置中保留颜色、粗细及透明度；点击“完成”关闭设置后仍可继续画，开启书写收起键盘，异常时恢复准确的开关状态。
- **五档粗细与预览**：Office 和 PDF／手记采用五个由小到大的圆点快速选粗细，保留滑块细调与实时笔迹预览；布局更紧凑，旧参数保持兼容。PDF 笔迹指导入手记后的编辑入口，独立 PDF 阅读器仍为只读。

代码验收：本地 Xcode 27 完整 App／测试宿主编译；真实 Office 引擎的 DOCX／XLSX／PPTX 各十笔混合样式保存重开，以及异常恢复、实际工具栏、PDF 导入与画笔设置交互。另两项定向回归在真实曲线控制点上落笔，均触发生产修复并保存第二条独立曲线，旧曲线路径、位置、锚点和样式不变。PDF／手记原生组件的八项回归覆盖全部八种笔刷的粗细边界、预览、持久化与交互。使用模拟 PointerEvent，未进行真实 Pencil 压力、手掌防误触、手感或长时间设备验收；不把原生组件或模拟器结果等同于真机通过。本构建的设备归档与分发结果另记。

## English

- **Continuous writing**: improves starting the next Office stroke and drawing near an earlier stroke's handles, so an old selection does not consume the new contact. Pen, Marker and Highlighter use native vector styles; changing presets affects future strokes.
- **Drawing controls**: toggle drawing directly from the toolbar and adjust color, width and opacity in separate settings. Done closes settings while keeping drawing active. Starting drawing dismisses the keyboard, and failures restore an accurate drawing state.
- **Five sizes and a live preview**: Office and PDF/Notes use five increasing dot sizes for quick selection, with a slider for fine adjustment and a live stroke preview. The layout is more compact and existing preferences remain compatible. PDF handwriting refers to PDFs imported into Notes; the standalone PDF reader remains read-only.

Code qualification: local Xcode 27 full-App and test-host compilation; ten mixed-style native strokes per DOCX/XLSX/PPTX with save/reopen, recovery, actual toolbar interaction, PDF import and pen settings. Two targeted regressions start on actual curve handles, trigger the production repair, save a second distinct curve and preserve the earlier curve's path, placement, anchor and style. Eight native PDF/Notes component checks cover all eight brush types, width boundaries, preview, persistence and interaction. These tests use simulated PointerEvents; physical Pencil pressure, palm rejection, feel and long-running device acceptance were not performed. Component and Simulator results are separate from physical-device acceptance. Device archive and distribution results for this build are recorded separately.
