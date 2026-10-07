# Port management / 端口管理

Candidate contract for 1.7.22 (263); see [release status](CURRENT_STATUS.md).

## `linux.port`

The tool resolves its environment from the authorized `ToolContext`, never from a
model-supplied environment ID. It shares the native port center and the existing
approval runner. Mutations require the current task's normal permissions. A
saved rule records the originating task when created by a model.

| Action | Arguments | Meaning |
| --- | --- | --- |
| `list` | none | List saved rules and actual binding state first |
| `create` | `guestPort`, `label`, `access`, optional `hostPort` | Save and apply a TCP rule if the guest is running |
| `update` | `ruleID`, `guestPort`, `label`, `access`, optional `hostPort` | Replace settings while retaining rule identity and origin |
| `enable` / `disable` | `ruleID` | Enable or stop a saved rule |
| `delete` | `ruleID` | Remove the rule and its live listener |

`access` is `local` (loopback) or `lan`. Guest ports are 1–65535. Optional host
ports are 49152–65535; omission means dynamic allocation. At most 16 enabled
rules exist per environment. A fixed port conflict may be remapped; always use
the receipt's actual port, not the requested port. Receipts contain the rule,
actual bound port, `listening` / `saved` / `disabled` state, available addresses,
remapping indicator and application error. Disabled rules remain listed.

Forwarding does not start the VM or a server. A listener without a service on its
guest port cannot serve a page. Stopping the VM preserves rules but revokes its
browser origin grants and clears actual bindings. Restart applies saved enabled
rules. This feature does not perform router mappings or public Internet exposure.

## 原生界面与模型一致

设置、虚拟机、终端、浏览器和网页服务入口复用同一端口中心。未指定环境的入口要求
先选环境，不自动使用第一台虚拟机。界面支持新增、编辑、启停、删除、复制地址和预览。

模型应先 `list`，使用返回的 `ruleID` 修改当前授权环境的规则。`create/update` 的
`access=local` 仅允许本机访问，`lan` 允许局域网；省略主机端口表示自动分配。
返回的实际端口可能与请求不同。规则已保存、实际监听、网页服务可访问是三个独立状态，
不能把转发成功说成服务已启动。停止虚拟机后规则保留，地址暂不可访问。
