# ARM64 network component qualification

Run on an Apple Silicon Mac with the selected Xcode and the supplied FloeSlirp dependency. Coordinate any shared native build window before starting. The output must be a fresh directory; the runner preserves command logs, failures, input hashes and results there.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 FloeAgent/Qualification/ARM64Network/run.py \
  --output "$HOME/Library/Caches/CodexBuild/FloeNetwork-component-check" --jobs 6
```

This builds the actual 30 engine translation units and runs five component executables. No App, Simulator or Linux VM is launched. `QueueCompletionTests.c` includes production runtime/device code against real guest RAM, DMA and MMIO. It tests independent packet checksum/segmentation oracles, deferred notification, held bulk-tail progress during continuous control traffic, queue sizes 8/32/64/256 and stale-ID removal on reset. A control-only stream must complete every older bulk descriptor; eventual success after an idle tick is insufficient.

The four backend executables test ordinary Ethernet TCP/UDP/DNS/DHCP/IPv6 behavior, read/write wait interests and deadlines, per-instance socket limits including accepted forwards, resolver discovery, and injected DNS64/NAT64 mapping over real IPv6 sockets. `FLOE_USERNET_TEST_HOOKS` is enabled only for their separately compiled adapter objects. It is never an App build flag. Injection proves the mapping mechanism, not operation on a real IPv6-only/DNS64 access network. Resolver-dependent expectations are documented in `backend/test_nat64.c`.

`NodeNetworkFixture.cjs` is the deterministic guest-side HTTP/TCP/UDP fixture used for full Linux measurements. Run it inside the existing guest with Node.js and measure only after it reports ready. Forward its ports through the normal runtime; verify payload bytes and hashes, keepalive, six concurrent resource clients, large responses plus simultaneous small requests, gzip, TCP half-close and UDP. Guest boot time is separate. The component runner does not claim these full-guest checks or M1 performance.

For current measurements and limitations see [runtime evidence](../../../docs/ARM64_RUNTIME_PERFORMANCE.md) and [network plan](../../../docs/FLOE_VIRTUAL_NETWORK_ENHANCEMENT_PLAN_20261110.zh-CN.md). Full App/resource packaging, Simulator acceptance, M1 iPad latency, real DNS64 networks and Apple review are separate outcomes.

## 简体中文

此 host 验证真实生产 C 路径及独立报文参考，不启动 App、Simulator 或 Linux。原失败与输出保留在新指定的缓存目录。队列检查必须证明持续控制包期间旧 bulk 描述符能归还，并覆盖不同队列大小和 reset；不能只看空闲后最终成功。后端的解析器注入仅证明机制，不代表真实 DNS64 网络验收。Node fixture 用于另行开展的实际 guest 流程，不以组件结果替代 M1 页面或 Apple 审核结论。
