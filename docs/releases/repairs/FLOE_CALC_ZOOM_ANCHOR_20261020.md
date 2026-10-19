# Excel 双指缩放锚点修复（2026-10-20）

Excel 在普通模式与画笔模式下完成双指缩放后，会把视图拉回原先选中的单元格，造成缩放目标跳位或文字被裁切。本次修复保留缩放锚点，只在可见帧高度确实变化时执行移动端尺寸补偿。

## 原因与改动

实际完整 App 的调用追踪确认：缩放收尾先后从 `_updateTileTwips` 和 `_restrictDocumentSize` 进入 `CalcTileLayer._syncTileContainerSize`。帧高仍为 934 core pixels，却调用了原先的尺寸变化处理，继而把选中的 A1 滚入视图。两次横向修正为 −4149、−3845 twips，最终视图横坐标均变为零；这些写入发生在兼容点击之前，并不需要 status 消息触发。

补丁仅改动 Calc：用实际帧高变化约束这两项补偿调用，保留尺寸同步、范围限制、重绘、冻结窗格计算和显式单元格导航。真实高度增加／减少及文字光标处理仍保留。Word、PPT 和输入取消逻辑没有包含在此次产品补丁内。

- 补丁：[ios-calc-zoom-resize-anchor.patch](../../../FloeAgent/ThirdParty/Collabora/patches/ios-calc-zoom-resize-anchor.patch)。
- 浏览器锁：`c2328ac4759417dc5adcbf450ec7a2e483bed8e00dcf1a291d3090d2b4ba2e1b`。
- 实际浏览器资源：`b95ed4e695104944c375a544dae5df71e3fd3542980e114054c9ec8a33146cde`。
- 实际模拟器原生组件：`a6ddd80978aa6fb9ed2736eed268f32e5a50aa22ad73ecc0213e4c7db902d803`。

## 验证

本地 Xcode 27、iOS 27 SDK、最低兼容版本 26。原始对照重新生成 525 个模块并与已知原始资源字节一致；补丁后的 525 个模块也重新生成，资源回执独立核验通过。原生组件编译、链接、Swift 导入及安装器的 4,785 个文件检查通过，实际符号与二进制 UUID 一致。完整 App／测试宿主编译通过，构建及界面运行前后源码冻结一致。

两个原始完整 App 界面用例均通过，无失败、无跳过：

| 模式 | 双向缩放后的档位 | 完整文字、缩放锚点、原始松手状态、无误画及返回保存 |
| --- | --- | --- |
| 普通 | 10 → 13 → 12 | 通过 |
| 画笔 | 10 → 14 → 13 | 通过 |

四份缩放后记录均保留全部调用，追踪方法数为 15、无环形丢弃或导出省略；每次仍有两次高度未变的尺寸同步，但不再触发原先的旧单元格滚动。画笔模式放大后的横坐标为 3845 twips，完整目标文字可见，未被拉回零。返回后的实际手记文档库也已检查。录像、结果、截图、资源回执、符号及链接记录保留；本轮启动的固定 iPad 模拟器已关机。

46 项源码重放检查保留两个实际失败输入，并覆盖真实高度增减、文字光标、冻结／不冻结窗格和显式单元格导航。这些检查只证明源码行为，不能替代上面的完整 App 界面结果。重放脚本要求明确提供源目录，不包含本机缓存路径，也不修改输入文件：

```sh
node FloeAgent/scripts/test_calc_zoom_resize.cjs \
  --browser-root <producer-stage>/source/browser \
  --original <restored-browser>/src/layer/tile/CalcTileLayer.js \
  --patched <producer-stage>/source/browser/src/layer/tile/CalcTileLayer.js
```

## 边界与下一步

本次是 Excel 缩放子阶段的模拟器验收；匹配的 iPhoneOS 组件及新安装包仍需交付。没有据此宣布 S1 完成或真实 Pencil 压感、手感通过。当前用例没有画入新笔迹，不能替代“新笔迹经真实返回保存后显示在手记卡片”的验收。

Word 的键盘前置状态及隐藏后缩放回弹、原生零移动笔点、实际笔迹卡片和后续 S3—S7 仍按[阶段计划](../../FLOE_IOS_CLOSURE_PLAN_20261018.zh-CN.md)推进；原始失败记录保留。
