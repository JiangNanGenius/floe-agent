# Floe 1.7 软件包与模型资格矩阵

本表逐项登记源码清单的当前状态，不是最终兼容/许可评估。候选未制作不等于已证明不兼容；声明的许可证也不等于权重分发资格已确认。执行证据、真机耗时和内存缺失时明确记为未验收。

## 软件包：15 项

来源：[pool/manifest.json](../pool/manifest.json)。官方可用目录只能包含完成制作与实际运行验证的具体版本。

| 包 | 版本 | 类型 | 当前结论与下一门槛 |
|---|---|---|---|
| floe-node-typescript | 5.6.0 | npm | 待制作；验证移动 Node 安装、模块加载及实际命令 |
| floe-node-eslint | 9.0.0 | npm | 待制作；验证移动 Node 安装、模块加载及实际命令 |
| floe-node-jest | 29.0.0 | npm | 待制作；验证移动 Node 安装、模块加载及实际命令 |
| floe-node-webpack | 5.0.0 | npm | 待制作；验证移动 Node 安装、模块加载及实际命令 |
| floe-node-native-sqlite3 | 11.0.0 | cross-compiled | 待制作；验证资产来源、安装与实际用途 |
| floe-node-native-sharp | 0.33.0 | cross-compiled | 待制作；验证资产来源、安装与实际用途 |
| floe-wasm-uutils | 0.0.29 | wasm | 待制作；验证 WASI 编译、导入与命令 I/O |
| floe-wasm-ripgrep | 14.1.0 | wasm | 待制作；验证 WASI 编译、导入与命令 I/O |
| floe-wasm-typst | 0.12.0 | wasm | 待制作；验证 WASI 编译、导入与命令 I/O |
| floe-wasm-sqlite3 | 3.46.0 | wasm | 待制作；验证 WASI 编译、导入与命令 I/O |
| floe-python-native-scipy | 1.14.0 | python-wheel | 待制作；验证 iOS/CPython ABI、来源与实际功能 |
| floe-python-native-scikit-learn | 1.5.0 | python-wheel | 待制作；验证 iOS/CPython ABI、来源与实际功能 |
| floe-python-native-lxml | 5.3.0 | python-wheel | 待制作；验证 iOS/CPython ABI、来源与实际功能 |
| floe-toolchain-clang-wasi | 1.0.0 | file | 待制作；验证资产来源、安装与实际用途 |
| floe-fonts-noto | 1.0.0 | file | 待制作；验证资产来源、安装与实际用途 |

## 模型：33 项

来源：[skill-hub/models.json](../skill-hub/models.json)。下列条目均未提供可安装权重文件；当前不应出现在可安装能力列表。每项仍须核对权重来源/许可、转换与输入输出约定；真机耗时/内存和样本产物均未完成。

| 模型 ID | 能力 | 源码登记状态 | 权重与推理结论 |
|---|---|---|---|
| floe/model-rife-v4 | video.interpolate | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-film | video.interpolate | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-ifrnet | video.interpolate | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-amt | video.interpolate | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-realesrgan-x4plus | video.superResolution | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-realesrgan-x2plus | video.superResolution | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-realesrgan-anime | video.superResolution | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-esrgan | video.superResolution | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-swinir | video.superResolution | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-hat | video.superResolution | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-span | video.superResolution | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-edsc | video.superResolution | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-waifu2x | video.superResolution | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-nafnet-denoise | video.denoise | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-scunet | video.denoise | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-restormer | video.restore | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-gfpgan | video.faceRestore | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-gpen | video.faceRestore | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-mobilesam | video.segment | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-sam2 | video.segment | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-depth-anything-v2-small | video.depth | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-ddcolor | video.colorize | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-deoldify | video.colorize | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-lama | video.inpaint | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-e2fgvi | video.inpaint | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-transnetv2 | video.sceneDetect | 待核验许可 | 无已验证权重；转换与真机推理未验收 |
| floe/model-paddleocr | video.ocr | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-yolox | video.detect | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-whisper-small | audio.transcribe | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-demucs | audio.stems | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-spleeter | audio.stems | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-rnnoise | audio.denoise | 待制作资产 | 无已验证权重；转换与真机推理未验收 |
| floe/model-deepfilternet | audio.denoise | 待核验许可 | 无已验证权重；转换与真机推理未验收 |

## 完成标准

逐项最终结论应为可用、不兼容或明确排除，并记录原因和对应证据；许可与来源需引用权威原始材料。每类默认模型来自已验证实现，允许采用同能力替代模型。安装记录、参数文案、目录签名均不能替代推理产物和真机性能证据。
