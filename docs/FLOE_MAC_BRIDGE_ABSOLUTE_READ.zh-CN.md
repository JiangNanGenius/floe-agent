# Mac Bridge 绝对路径读取（cross-workspace）

本功能让使用已配对 Mac 作为执行环境的任务，直接读取 Mac 上的绝对路径文件。典型场景：
`exec.shell`、`npm` 或其他命令输出 `/Users/name/project/dist/report.png` 后，模型无需先复制
到任务工作区，即可用 `workspace.readFile`、`image.view` 或 `image.inspect` 读取该文件，
包括任务工作区之外的桌面、下载或其他工程目录。

## 使用方式

1. 任务必须在“执行环境”中选择已连接的 Mac（Floe Bridge 已配对并处于连接状态）。
2. `workspace.readFile`：`path` 传 Mac 绝对路径。每次最多返回 64 KiB 文本，结果带
   `macBridge=true`、`totalBytes`、本页 `sha256` 和 `truncated`；继续读取时传 `offset`。
3. `image.view`：`path` 传 Mac 绝对图片路径，返回经过校验的 PNG 附件及原始像素/裁剪信息。
   `image.inspect`：`path` 传 Mac 绝对图片或 PDF 路径，把实际图像字节交给已配置的视觉模型；
   PDF 用 `page` 选择 1-based 页码。`image.view` 仍只接受光栅图片。
4. 相对路径、工作区文件同步、Shell stdout 与附件格式均保持原样。

## 权限与边界

- 只读：新链路没有写入、删除、重命名或安装能力，也不会把路径拼接进 Shell 命令。
- 目标信任：仅当该任务持久化的冻结执行绑定与当前活动环境记录都指向同一个 Mac，
  且 Mac Bridge 仍处于已配对状态时才允许读取。原生工具无需带 Shell 环境变量；如果
  调用上下文包含执行环境，则该环境也必须与冻结绑定一致。
  Linux、本机原生、SSH 或未绑定环境不会回退到 Mac。
- 任务范围：受 `allowedWorkspacePaths` 文件范围约束的子任务不能使用绝对路径；临时聊天
  也不能读取绝对 Mac 文件。普通未收窄范围的任务可用。
- Mac OS 权限与普通文件一致：受 TCC/磁盘权限限制的目录仍可能返回真实的系统拒绝错误。
- 凭据保护：对实际打开的目标（含符号链接解析后的目标）继续执行工作区同款敏感文件排除
  （`.ssh`、`.aws`、`.gnupg`、`.env*`、`id_*`、密钥扩展名、`.git/config` 等）。
- 只接受普通文件；目录、FIFO、设备、失效链接等会被拒绝。合法 Mac 别名（如 `/tmp`、
  `/System/Volumes/Data/Users/...`）按其实际文件身份工作。

## 一致性与错误

- 读取按 1 MiB 分块，跨分块保持文件身份（设备、inode、大小、mtime、ctime）一致；
  图片整文件读取在 20 MiB 内完成，并用 Mac 端整文件 SHA-256 与本机汇总摘要核对。
- 文件在读取过程中被替换、截断或改写时报错并要求重读，不返回混合版本。
- 旧版 Floe Bridge 未提供该能力时会明确提示更新 Floe Bridge；不会静默回退。
- 文件不存在、无权限或不是普通文件时保留实际错误，不伪造空内容。
