# Texture painting and baking: original workflow closure

Source `ac420afb805cd676238e9c12066a37085a274f9b`, Xcode 27.1, Swift 6,
full App336 object build. The original X10 criterion is unchanged.

The canonical reused iPad Simulator executed the original UI workflow:
real surface stroke → exact Undo/Redo texture bytes → real geometry AO → save →
fresh process reopen. UI325 passed 1/1, with no skip. The native occluder switch
was activated at its actual trailing control and its on-state verified before
baking; no pixel or hash assertion was relaxed. Root reviewed the real baked
image and cold-reopened image.

Native326 passed all six selected cases, including real GLB export whose
embedded PNG and UV bytes match the painted/baked document before and after
save/reopen. Related save/prewarm generation, refused-save, history and sketch
identity checks passed. Both runs shut down the owned Simulator.

Original UI317, UI320 and UI324 failures remain retained. UI320's failed redo
was recovered by independent native Form button actions; UI324's inactive
occluder switch was corrected in the test interaction, with a required state
assertion. Neither failure was retried unchanged or reported as passed.

X10 is accepted within whole-body flattened color painting and mesh-based AO.
Texture layers, high/low transfer and normal baking are not claimed. This is
App/Simulator evidence, not physical-device performance or whole-release proof.

简体中文：原始绘制、撤销／重做、遮挡烘焙、保存与冷重开链已通过实际 iPad
模拟器操作；原生检查另核对 GLB 内嵌 PNG 与 UV 的真实字节。原断言和失败记录
保持，未把图层、法线烘焙或实机性能列为已验证。
