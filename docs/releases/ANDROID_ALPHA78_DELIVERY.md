# Android Alpha78 / code104

日期 / Date: 2026-11-10

本源码检查点准备下一份GitHub中间预发布；实际构建、三星行为与公开下载分别补记。实质代码检查点为 `8d43e0f0f58a28077db6afaeb537eba57d4b5230`，安装包以生产记录中的不可变源码为准。

This checkpoint prepares a GitHub intermediate prerelease. Actual build, Samsung behavior and public downloads are separate results. The implementation checkpoint is `8d43e0f0f58a28077db6afaeb537eba57d4b5230`; the producer records the APK's immutable source.

- 设置页的控件说明并入所属行，分组说明放到卡片下方；减少非交互文字独占完整行的空白，保留点击区域、权限条件、密码遮挡和手机／平板导航。
- 手机输入在完整、唯一、可见且属于可信系统窗口的数字键盘存在时，输入前选择该通路；一旦部分输入失败，不再切换通路重放凭据。非数字或不完整键盘继续原有受控文字路径，只有实际解除锁屏才成功。
- 保留77的Linux复制流水线、轻量IDE成果、运行历史任务链接和升级状态布局；UI与功能代码并行交接，再集中构建。

- Control explanations now share their setting row, while group explanations use the grouped footer. This removes full-height explanatory cells and retains touch targets, permission predicates, password masking and phone/tablet navigation.
- When a complete, unique, visible native numeric keypad belongs to the trusted system window, its input channel is selected before typing. Partial failure never falls through to replay the credential. Non-numeric or incomplete keypads retain the bounded text path; actual keyguard release remains the success condition.
- Retains77's Linux copy pipeline, native lightweight file results, task links from schedule history and update-status layout. UI and functional source packages were developed concurrently, then integrated for one APK.

源码验证：39项手机解锁生命周期／确认回归检查及手机模块Release编译通过；一次已保留的可空Compose表达式编译错误经局部修正后，Full／Play实际消费端编译通过。未改的根环境和原生组件证据按输入身份复用，不重复整套检查。

Source qualification:39 focused phone unlock-lifecycle/submit regressions and actual phone-module Release compilation passed. After a retained nullable-Compose-expression compiler failure was corrected locally, actual Full/Play consumer compilation passed. Unchanged rootfs and native evidence is reused by input identity rather than rerunning entire suites.

已知边界：77的新自动解锁用例仍失败，原41条记录保留；本版输入通路修复必须使用新用例验收，不能把接受输入或完成手势当作解锁成功。整体UI精修、索尼Android9启动、专业图形保存、首次下载计量以及部分定时／恢复组合继续，不以中间版代替N01–N08完成。

Known limits: the fresh77 unlock case failed and its41 original records remain retained. This version's input-channel fix requires a new case; accepted input or a completed gesture is not unlock success. Whole-App refinement, Sony Android9 startup, professional graphical saves, fresh-download metering and remaining scheduling/recovery combinations stay open; this intermediate build does not close N01–N08.

发行保留一个Full ARM64安装包及必要组件、校验、更新与对应源码文件，保持iOS Latest和所有已发布不可变标签／字节。

Distribution keeps one Full ARM64 installer and required components, integrity/update and corresponding-source files, preserving iOS Latest and existing immutable tags and bytes.

## 公开交付 / Public delivery

[Alpha78/code104](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.78) 已从不可变源码 `cb562a704677e25d7f2c4a0c790582a8c06a43f5` 公开。Full APK为164,739,527字节，SHA-256：`6a40b761141c2bc5d04373298055f0d96be0b18f8d6484bfda13d1e1c924c1f6`。实际Full／Play生产、58项原生／封装绑定、API28／29签名、77→78重建、七个公开附件匿名实际下载以及当前／保留Alpha65更新发现均通过；iOS Latest保持 `v1.8.6`。真实设备行为继续单独验收。

Alpha78/code104 is public from the immutable source above. The Full APK is164,739,527 bytes with the recorded SHA-256. Actual Full/Play production,58 native/package bindings, API28/29 signatures,77→78 reconstruction, anonymous actual downloads of all seven assets and current/retained Alpha65 discovery passed. iOS Latest remains `v1.8.6`; device behavior is qualified separately.

保留一处标签注释文字笔误：注释写有旧的code103，实际标签名、源码、发布说明、签名APK及运行组件均绑定本版code104；不移动不可变标签或替换附件来修文字。

The immutable tag annotation contains the preceding code103 label. The tag name, source, release body, signed APK and runtime bind code104. The tag and assets remain unchanged rather than being replaced for this wording typo.

## 三星与后续边界 / Samsung and follow-up

三星已真实通过77的App内完整包按钮及保存的镜像源升级到78：主包／运行组件104的实际字节及原UID匹配，原5任务2项目保留。未使用ADB安装或清除应用数据。78的K用例未在预定窗口进入锁屏，实际显示使用中让路确认；已停止并保留41条原记录，不计作自动解锁通过或失败。自建任务、导出、临时凭据、范围及权限已清理恢复。

Samsung completed the actual77→78 in-App full-package/mirror upgrade. Both code104 packages match the published bytes and retain their UIDs, five tasks and two projects, without ADB installation or data clearing. Case K missed its lock-entry precondition and showed the in-use consent guard. It was stopped with41 original records retained; it is neither an automatic-unlock pass nor failure. Its temporary task, export, credential, scope and permissions were restored.

用户已停止后续Google Play发行；本版的历史Full／Play证据保留，未来只编译和自行分发Full APK。另收到索尼Android9环境就绪的正向外测照片，未显示App版本及原始命令回执，不归因到特定安装包或代替完整设备验收。

The user discontinued future Google Play work. This build's historical Full/Play evidence remains valid; future builds and self-distribution target Full only. A Sony Android9 external photo now reports a ready Linux environment, without an App version or raw command receipt, so it is not attributed to a particular build or treated as complete device acceptance.
