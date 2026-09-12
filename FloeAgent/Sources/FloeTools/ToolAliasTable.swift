// FloeTools — Single source for tool aliases and discovery synonyms.
// See docs/ARCHITECTURE_LOCAL_SHELL.md §Tool surface: rename aliases live for
// one release window; capability synonyms are shared by tools.search and
// skill.search instead of being duplicated per module.

import Foundation

public enum ToolAliasTable {
    /// Renamed tool → canonical registered name. The runtime resolves an
    /// exact call to a renamed name before rejecting it, and discovery shows
    /// the canonical spelling. Entries are removed one minor release after
    /// the rename ships.
    public static let renamed: [String: String] = [
        "presentation.createDeck": "document.presentation.createDeck",
        "presentation.createInline": "document.presentation.createInline",
        "task.readPlan": "checklist.readPlan",
        "task.updatePlan": "checklist.updatePlan",
        "image.qrGenerate": "image.qr.generate",
        "image.scanBarcode": "image.barcode.scan",
        "cloudWorkspace.gitStatus": "cloudWorkspace.git.status",
        "cloudWorkspace.gitDiff": "cloudWorkspace.git.diff",
        "cloudWorkspace.gitLog": "cloudWorkspace.git.log",
        "cloudWorkspace.gitInitialize": "cloudWorkspace.git.initialize",
        "cloudWorkspace.gitStage": "cloudWorkspace.git.stage",
        "cloudWorkspace.gitCommit": "cloudWorkspace.git.commit",
        "cloudWorkspace.gitFetch": "cloudWorkspace.git.fetch",
        "cloudWorkspace.gitPull": "cloudWorkspace.git.pull",
        "cloudWorkspace.gitPush": "cloudWorkspace.git.push",
        "cloudWorkspace.gitBranch": "cloudWorkspace.git.branch"
    ]

    /// Lowercased query token → capability group. A query containing one of
    /// these terms expands to the group before falling back to description
    /// ranking. Shared by ToolDiscovery and SkillManagement.
    public static let synonyms: [String: [String]] = [
        "vnc": ["vnc", "远程桌面", "鼠标", "remote desktop"],
        "executor": ["ssh", "executor", "执行命令", "运行命令"],
        "hosts": ["主机", "server", "连接配置"],
        "terminal": ["终端", "terminal", "交互", "telnet", "串口"],
        "shell": ["shell", "sh", "bash", "命令", "脚本", "管道", "command", "terminal"],
        "packages": ["apt", "package", "packages", "包", "安装", "pip", "dpkg", "pkg"],
        "python": ["python", "numpy", "pillow", "pandas", "scipy", "matplotlib", "数据分析"],
        "pdf": ["pdf"],
        "office": ["markdown", "rtf", "富文本", "格式转换", "互转", "office", "word", "excel", "powerpoint", "ppt", "幻灯片", "演示文稿", "表格", "工作簿", "文档"],
        "http": ["http", "接口", "api"],
        "network": ["network", "网络", "ping", "dns", "http", "端口", "traceroute"],
        "workspace": ["workspace", "文件", "编辑", "file", "html", "代码"],
        "image": ["image", "图片", "图像", "照片", "生成图片", "生图", "画图", "createimage", "create image", "text-to-image", "文字识别", "ocr"],
        "canvas": ["canvas", "画布", "生成", "图片", "视频"],
        "memory": ["memory", "记忆", "remember"],
        "skill": ["skill", "技能"],
        "browser": ["browser", "浏览器", "网页", "website"],
        "web": ["web", "搜索", "search", "查找"],
        "git": ["git", "仓库", "commit", "repository"],
        "mail": ["mail", "邮件", "邮箱", "收信", "发信", "imap", "pop3", "smtp"]
    ]

    /// Canonical spelling for a renamed name; unchanged names pass through.
    public static func canonical(_ name: String) -> String {
        if let canonical = renamed[name] { return canonical }
        // Known historical provider wire spellings only; never guess arbitrary names.
        return renamed.first { $0.key.replacingOccurrences(of: ".", with: "_") == name }?.value ?? name
    }

    /// Aliases that currently resolve to `name`, sorted for deterministic output.
    public static func aliases(of name: String) -> [String] {
        renamed.compactMap { $0.value == name ? $0.key : nil }.sorted()
    }
}
