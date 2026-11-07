# Native scientific analysis qualification

This small package compiles the production `ScientificDataAnalysis.swift` through
a source symlink and runs its numerical tests. It has no replacement engine or
dependency on the App, Linux, models or media packages.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path FloeAgent/Qualification/ScientificAnalysis \
  --scratch-path "$HOME/Library/Caches/CodexBuild/FloeAgent/0dd039b5b74b/xcode-27B52/scientific-analysis" \
  --jobs 6
```

The 18 numerical tests passed with Xcode 27.2 (27B52), Swift 6.4.2 on arm64 macOS.
They cover statistical conventions, missing pairs, stable moments, regression,
histogram boundaries, undefined statistics, finite JSON, limits and cancellation.
The core and `NativeDataAnalysisTool` also passed arm64 iOS 26 Simulator object
compilation against the actual compiled FloeCore and FloeTools modules.

The parent FloeExecution test includes a real tool invocation and temporary-chat
policy assertion. Separate runtime discovery tests check the offered directory
and Chinese queries. Those integration tests are outside this package and are
not included in the 18-test result. Full-App build and model interaction remain
separate evidence.

## 中文

本包通过符号链接直接编译生产计算源码，不替换算法，也不依赖整个 App、Linux、
模型或媒体构建图。上方命令从仓库根目录运行；共享同一 scratch 的构建须串行。

18 项数值测试已通过；核心和工具封装另通过 arm64 iOS 26 Simulator 真实对象编译，
使用实际 FloeCore／FloeTools 模块。父包中的工具调用、临时聊天限制及运行时发现测试
不计入这 18 项；完整 App 和实际模型调用仍分别验收。
