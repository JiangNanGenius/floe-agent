# Floe maintained library slice

Source: https://github.com/royalapplications/royalvnc/tree/92d4427c73817d8f849bb289ff190aa4b40c44ea
License: MIT, retained in LICENSE. Library sources are preserved except below.

Trailing whitespace in Swift source is mechanically removed; no other
formatting or upstream behavior changes are intended beyond the listed patch.

- Queue.swift: replace the unsynchronized value array with a locked reference
  queue. Input/API producers, the asynchronous sender and handshake clear all
  share it. Guarding an empty check separately from removal is insufficient.
- Package.swift: retain the library/C dependencies and dynamic product, omit
  demos and Windows-only bundled zlib, pin the existing CryptoSwift revision.
- QueueTests: simultaneous producers/consumer and clear stress coverage.
- VNCKeyCode+ObjC.swift: inline secret-scanner exceptions only for six public
  X11 keyboard symbol assignments misidentified as API credentials.

Only this ~1 MiB library source slice is vendored, not upstream demos, binaries,
build trees or native runtime packages. This is compiled into the signed app;
no runtime patching or modification of SwiftPM cache checkouts is used.

中文：固定上述上游提交，仅将发送队列改为加锁的引用对象，防止发送循环和输入线程
并发修改数组；保留原 MIT 许可证。独立压力测试和 Floe 真实 RFB 回环测试共同验收。
