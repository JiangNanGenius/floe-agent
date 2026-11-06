# FloeMusicKeyboard

Floe 音乐工作台的可复用电子琴演奏面板。仅 UI：本包复用开源 AudioKit
`Keyboard` 琴键渲染，加上弯音/调制轮和可选音色控制条，把触摸转换成带归属
标识的演奏事件，交给宿主注入的 sink。本包**不**拥有音频引擎、**不**占用
音频会话、**不做**存储——乐器音源、混音、录音和持久化都由宿主负责。

- iPad 优先，iPhone 可用。iOS 26 / macOS 15，Swift 6。
- 琴键渲染：[AudioKit/Keyboard](https://github.com/AudioKit/Keyboard)，固定提交
  `3b1a7bfd6f2e49f23ee9fb317a8fde2c3152f371`（MIT，见 `NOTICE.md`）。
  [AudioKit/Tonic](https://github.com/AudioKit/Tonic) 固定
  `8f103c6765af93bc1d2c3e18eb35f02718b0613d`（MIT）。依赖不浮动。
- 键盘 UI 本身不发声。

## 接入

```swift
import FloeMusicKeyboard
import SwiftUI

struct KeyboardDetail: View {
    // 宿主侧：每个乐器轨一个 controller。
    @State private var controller = KeyboardPerformanceController(
        owner: KeyboardOwnerToken("track-42"),
        sink: MyInstrumentTrackSink.shared   // 实现 KeyboardPerformanceSink
    )
    @State private var selectedPreset: String? = "grand"
    @State private var volume: Float = 0.8

    var body: some View {
        ElectronicKeyboardPanel(
            controller: controller,
            configuration: .default,            // 25 键、C3 起始、带轮与延音
            toneSurface: KeyboardToneControlSurface(
                presets: hostPresets,           // 仅宿主已获授权的音色描述
                selectedPresetID: $selectedPreset,
                volume: KeyboardParameterControl(value: $volume)
            ),
            onExpand: { /* 宿主自行承接全屏 */ }
        )
        .onChange(of: selectedPreset) { _, _ in
            controller.presetDidChange()        // 换音色时释放正在发声的音
        }
    }
}
```

sink 在主线程接收 `KeyboardPerformanceEvent`：

- `.noteOn(owner, PerformanceNote)` / `.noteOff(owner, note, channel)`——
  音高已经过八度/移调；释放永远对应最初发声的那个音。
- `.sustain(owner, Bool)`、`.pitchBend(owner, -1...1)`、`.modulation(owner, 0...1)`。
- `.allNotesOff(owner)`——每次整体/部分释放后的明确收尾栅栏。

### 归属与生命周期保证

- 修改 `controller.owner` 或 `controller.sink` 时，先把所有按住的音、踏板
  和轮状态释放给**原** owner/sink——替换后的 owner 永远不会收到迟到的
  note-off。
- 八度/移调/音域/音色变化会释放原先发声的音；之后再抬手指不会关掉已经
  偏移的新音高。
- 场景失活与面板消失时面板自动调用 `releaseAll(reason:)`；断开连接时宿主
  也可主动调用。恢复时不会自动重播。
- 键盘录制与回放都走宿主的乐器轨；MIDI 录音归属宿主引擎。

## 已知限制

- 触摸屏只能给出位置，没有真实击键力度。默认策略按键内纵向位置映射力度；
  可用 `KeyVelocityPolicy.fixed(_:)` 注入或在 `.noteOn` 上自行处理。
- 延音踏板的音保持语义在宿主乐器侧；面板转发踏板状态与即时抬键。
- 弯音归一化为 −1...1；宿主映射到实际弯音范围。
- 音色描述只列出宿主提供的音源；本包不含任何声音与预置资源。
- 上游 `Keyboard` 组件负责绘制与命中测试，已处理触摸取消；支持多点同时
  触摸。
- 演奏面板有意不开放琴键锁存（latching）模式。
- 本地化随包提供 `en` 与 `zh-Hans`。

## 状态

26 项事件控制测试及 arm64 iOS 对象编译通过，独立 iPad 测试 App 已将面板
接到原生合成器并编译、链接通过。共享模拟器占用锁阻止了 UI 运行测试；
实际布局、多指触摸和触键发声延迟/真机听感尚未验收，见 `API_HANDOFF.md`。
