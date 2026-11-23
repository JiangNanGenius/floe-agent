# 配对设备工作区同步

工作区文件沿用设备配对和会话入口。发送方为同一设备单独开启该会话的工作区文件，授权绑定本机当前的工作区归属。接收方主动选择是否同时同步文件，文件按相对路径进入接收会话实际绑定的工作区。双方均开启文件共享后可分别从对方拉取。

## 传输

配对、`floe/device-link/1` 和 JSON 整数 `version: 1` 沿用。每项会话 offer 可增加 `workspaceFiles: true`，缺少表示未共享文件。旧端继续使用原会话操作。按会话 ID 拉取文件时重新查询当前能力。

| 请求 `operation` | 其他字段 | 成功响应字段 |
| --- | --- | --- |
| `prepareWorkspace` | `taskID` | `size`、`digest` |
| `workspaceManifest` | `taskID`、`offset` | `bytes` |
| `workspaceFile` | `taskID`、`index`、`offset` | `bytes` |
| `confirmWorkspace` | `taskID`、`indexes` | 无 |

准备请求建立单连接、单会话的快照。后续操作核对同一授权和快照，每次最多返回 393,216 字节，以标准 Base64 编码。清单是 UTF-8 JSON `{"entries":[...]}`。目录记录含 `path` 和 `kind:"directory"`。文件记录另含 `kind:"file"`、整数 `size` 和小写 64 位十六进制 SHA-256 `digest`。响应 `prepareWorkspace` 的 `size` 和 `digest` 对应 JSON 原始字节。清单按零基 `index` 寻址，零字节文件无分段请求。确认最多 128 个已处理文件索引，无重复。同一快照确认可重试。

清单最多 10,000 项和 16 MiB，单文件最多 1 GiB，文件总量最多 8 GiB。沿用 `notShared`、`unavailable`、`busy`、`tooLarge`、`conflict` 和 `invalidResponse`。发送端发现文件与清单时的内容标识不一致就中止该项。接收端校验长度和摘要，完成后才替换目标。网络失败保留已落盘且校验通过的文件，再次拉取只获取仍需传输的文件。

## 路径和本机归属

- 保留原拼写。相对路径使用 `/`，最多 1,024 个 UTF-8 字节、64 层，每段最多 255 字节。禁止空段、`.`、`..`、反斜杠、冒号、控制字符和以 `~` 开头的路径。
- 使用 NFC 后的不分区域小写路径检查重复。相同父路径的各记录使用相同原始拼写。文件路径不能也是另一条记录的上级目录。例如 `Demo/a` 与 `demo/b`、`é.txt` 与 `e\u0301.txt` 同批均无效。
- 跳过根下的 `Mounts` 和 `Network`。各层排除 `.git`、`.svn`、`.hg`、`.ds_store`、`node_modules`、`.venv`、`__pycache__`、`.build`、`.gradle`、`.swiftpm`、`.floe`、以 `.floe-` 开头的名称、`Floe Sync Conflicts`。各层还排除 `.ssh`、`.aws`、`.gnupg`、`.netrc`、`.npmrc`、`.pypirc`、`.git-credentials`、`.htpasswd`，以 `.env`、`.pgpass`、`id_rsa`、`id_dsa`、`id_ecdsa`、`id_ed25519` 开头的名称，以及扩展名 `pem`、`key`、`keystore`、`p12`、`pfx`、`jks`。比较忽略大小写。
- 只读取实际仓内的普通文件和目录。忽略链接、特殊文件和挂载。接收时拒绝路径映射到任何链接和保留文件。目录绑定、执行授权、书签和密钥只保留本机。

## 合并

以对端、会话、本机工作区归属和相对路径记录双方已确认的文件摘要。文件相同、首次写入或基线仍相同且替换完成后才能确认。发送端只接受已准备清单里的文件索引，并只登记本机仍对应原清单的版本。远端仍是基线时保留本机改动。两边各有不同版本时保留本机版本，将对端版本写到本机工作区的 `Floe Sync Conflicts/<远端文件摘要>/<原相对路径>`。远端清单缺项保留本机文件，文件删除由各端自行处理。重新授权或改绑工作区时使用新的绑定校验。
