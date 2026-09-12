# Floe 1.7 软件包与模型资格矩阵

本表逐项登记源码与上游核对的当前状态，完整兼容/许可评估尚未完成。候选未制作不等于已证明不兼容；声明的许可证也不等于权重分发资格已确认。执行证据、真机耗时和内存缺失时明确记为未验收。

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

| 模型 ID | 能力 | 上游代码许可证据 | 当前结论 |
|---|---|---|---|
| floe/model-rife-v4 | video.interpolate | [MIT](https://github.com/hzwer/Practical-RIFE/blob/bbfd2ea90910789a860ea3e2b32a240cd577b75e/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-film | video.interpolate | [Apache-2.0](https://github.com/google-research/frame-interpolation/blob/69f8708f08e62c2edf46a27616a4bfcf083e2076/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-ifrnet | video.interpolate | [MIT](https://github.com/ltkong218/IFRNet/blob/b117bcafcf074b2de756b882f8a6ca02c3169bfe/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-amt | video.interpolate | [NOASSERTION](https://github.com/MCG-NKU/AMT/blob/70f988fbfc0d3d458beba1ee49caf876e57968fe/LICENSE) | 本轮排除：非商业限制，未取得额外许可 |
| floe/model-realesrgan-x4plus | video.superResolution | [BSD-3-Clause](https://github.com/xinntao/Real-ESRGAN/blob/a4abfb2979a7bbff3f69f58f58ae324608821e27/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-realesrgan-x2plus | video.superResolution | [BSD-3-Clause](https://github.com/xinntao/Real-ESRGAN/blob/a4abfb2979a7bbff3f69f58f58ae324608821e27/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-realesrgan-anime | video.superResolution | [BSD-3-Clause](https://github.com/xinntao/Real-ESRGAN/blob/a4abfb2979a7bbff3f69f58f58ae324608821e27/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-esrgan | video.superResolution | [Apache-2.0](https://github.com/xinntao/ESRGAN/blob/73e9b634cf987f5996ac2dd33f4050922398a921/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-swinir | video.superResolution | [Apache-2.0](https://github.com/JingyunLiang/SwinIR/blob/6545850fbf8df298df73d81f3e8cba638787c8bd/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-hat | video.superResolution | [Apache-2.0](https://github.com/XPixelGroup/HAT/blob/1638a9a822581657811867bf670717f8371fc3e5/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-span | video.superResolution | [Apache-2.0](https://github.com/hongyuanyu/SPAN/blob/c77a5917759f09e66fbc7124220c5afc5ee221e5/LICENSE.txt) | 转换与权重/真机推理未验收 |
| floe/model-edsc | video.superResolution | [Apache-2.0](https://github.com/Saafke/EDSR_Tensorflow/blob/06c7bd65b0305c2955328f8f2721ea86c341f660/LICENSE) | 源为 EDSR；保留旧 ID，转换未验收 |
| floe/model-waifu2x | video.superResolution | [MIT](https://github.com/nagadomi/waifu2x/blob/cc385f97a9debfe611316aabfd5d8bb30ba2dbeb/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-nafnet-denoise | video.denoise | [NOASSERTION](https://github.com/megvii-research/NAFNet/blob/2b4af71ebe098a92a75910c233a3965a3e93ede4/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-scunet | video.denoise | [Apache-2.0](https://github.com/cszn/SCUNet/blob/52e440a80a655b01e0b41e9dd9bfe599bc11625e/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-restormer | video.restore | [MIT](https://github.com/swz30/Restormer/blob/68dc6ac472db26f16361150cb7a96a1bc87da93f/LICENSE.md) | 转换与权重/真机推理未验收 |
| floe/model-gfpgan | video.faceRestore | [NOASSERTION](https://github.com/TencentARC/GFPGAN/blob/7552a7791caad982045a7bbe5634bbf1cd5c8679/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-gpen | video.faceRestore | [未取到许可](https://github.com/yangxy/GPEN/blob/2c736702983368847fb544d234a22ac7cff25802/README.md) | 本轮排除：未取得可核验分发许可 |
| floe/model-mobilesam | video.segment | [Apache-2.0](https://github.com/ChaoningZhang/MobileSAM/blob/f706ad9c4eb7f219c00d9050e46328518ffb65d2/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-sam2 | video.segment | [NOASSERTION](https://github.com/facebookresearch/sam2/blob/2b90b9f5ceec907a1c18123530e92e794ad901a4/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-depth-anything-v2-small | video.depth | [Apache-2.0](https://github.com/DepthAnything/Depth-Anything-V2/blob/a561b849ebae10a6f5ef49e26c83cbbcd36c71bf/LICENSE) | Small 权重明确 Apache-2.0；其他尺寸不能替代，推理未验收 |
| floe/model-ddcolor | video.colorize | [Apache-2.0](https://github.com/piddnad/DDColor/blob/2adb63f2656ac41cbdf7b894cddd94121a3faf13/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-deoldify | video.colorize | [MIT](https://github.com/jantic/DeOldify/blob/5f86c28923799036ad4b1bf7af8c629ac65efd75/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-lama | video.inpaint | [Apache-2.0](https://github.com/advimman/lama/blob/786f5936b27fb3dacd2b1ad799e4de968ea697e7/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-e2fgvi | video.inpaint | [NOASSERTION](https://github.com/MCG-NKU/E2FGVI/blob/709cbe319edc21b8a365a28e14cba595a93d62cf/LICENSE) | 本轮排除：非商业限制，未取得额外许可 |
| floe/model-transnetv2 | video.sceneDetect | [MIT](https://github.com/soCzech/TransNetV2/blob/85cef72af9a916bdfd7cc94a670c9cdfbf12d1ed/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-paddleocr | video.ocr | [Apache-2.0](https://github.com/PaddlePaddle/PaddleOCR/blob/2661c7c0ef5c613e8f93c6e93b2e052399f0f854/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-yolox | video.detect | [Apache-2.0](https://github.com/Megvii-BaseDetection/YOLOX/blob/6ddff4824372906469a7fae2dc3206c7aa4bbaee/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-whisper-small | audio.transcribe | [MIT](https://github.com/openai/whisper/blob/86098128c0b4f24f0e2aa2994de830614b474227/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-demucs | audio.stems | [MIT](https://github.com/facebookresearch/demucs/blob/e976d93ecc3865e5757426930257e200846a520a/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-spleeter | audio.stems | [MIT](https://github.com/deezer/spleeter/blob/c8854001ac8acad34a9bc2bd15f28475541828b1/LICENSE) | 转换与权重/真机推理未验收 |
| floe/model-rnnoise | audio.denoise | [BSD-3-Clause](https://github.com/xiph/rnnoise/blob/70f1d256acd4b34a572f999a05c87bf00b67730d/COPYING) | 转换与权重/真机推理未验收 |
| floe/model-deepfilternet | audio.denoise | [NOASSERTION](https://github.com/Rikorose/DeepFilterNet/blob/d375b2d8309e0935d165700c91da9de862a99c31/LICENSE) | 转换与权重/真机推理未验收 |

31 个上游仓库的固定提交、许可文件地址和检索状态见 [来源证据](evidence/floe-1.7/model-upstream-metadata.json)。GitHub 的 `NOASSERTION` 是自动识别不足，不等于没有许可；例如 GFPGAN 文件描述 Apache-2.0 及第三方例外，NAFNet 包含多份许可，需要按具体组成核对。代码许可不自动覆盖全部权重。

## 完成标准

逐项最终结论应为可用、不兼容或明确排除，并记录原因和对应证据；许可与来源需引用权威原始材料。每类默认模型来自已验证实现，允许采用同能力替代模型。安装记录、参数文案、目录签名均不能替代推理产物和真机性能证据。
