# Mac suspension and storage ownership

The isolated designed-for-iPad Mac App was launched normally without XCTest
or a debugger. RunningBoard recorded two real OS suspensions followed by
foreground recovery in the same process. Background audio was off. Three
independent SQLite writer-lock probes acquired and rolled back their write
transactions. The synthetic saved Note and its FTS entry survived; Root reviewed
both retained before/after screenshots.

The isolated source derives from `5f17da74f73e2de55bb204b173bad63af8be8bed`.
Current storage-coordinator behavior is unchanged (SHA-256
`a6743061fa5a91be4bb897cf75f3db4a96aca436ae5ef9664e0c73917dcea0d0`).
The Metal cache repair is integrated in `e9cc`; its change from the observed
variant is two introductory comments only. Persistence, Notes and Documents
sources have no behavioral delta from that baseline to App336.

This closes the scoped suspension/resume storage gate. It does not identify
the original Build305 lock owner or prove production AppGroup-extension
coordination. Only background audio's off-state was independently recorded;
there is no separate snapshot of every background switch. Original run logs,
lock probes, source receipts and synthetic screenshots remain retained.

简体中文：隔离 Mac App 在关闭后台音频、无调试器的情况下，实际经过两次系统挂起
并在同一进程恢复；三库写锁探测与保存内容保持通过。本记录不扩充为原305具体锁
归因、生产扩展协同或全部后台开关的逐项实测。
