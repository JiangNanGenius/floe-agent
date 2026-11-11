// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

struct HelpCopy {
    let language: HelpLanguage
    static var current: Self { .init(language: HelpLanguage(preference: FloeL10n.currentLanguageCode)) }
    func text(_ chinese: String, _ english: String) -> String {
        language == .simplifiedChinese ? chinese : english
    }
    var title: String { text("帮助与指南", "Help & Guides") }
    var search: String { text("搜索指南与设置", "Search guides and settings") }
    var searchResults: String { text("搜索结果", "Search Results") }
    var noResults: String { text("没有找到相关指南", "No matching guides") }
    var trySearch: String { text("试试其他关键词。", "Try another search term.") }
    var offline: String { text("可离线阅读", "Available offline") }
    var unavailable: String { text("暂时无法打开指南", "Guide unavailable") }
    var unavailableDetail: String { text("请返回帮助首页，选择可用的指南。", "Return to Help & Guides and choose an available guide.") }
    var retry: String { text("重试", "Try Again") }
    var close: String { text("关闭", "Close") }
    var done: String { text("完成", "Done") }
    var contents: String { text("章节目录", "Contents") }
    var find: String { text("在本页查找", "Find on Page") }
    var reading: String { text("阅读外观", "Reading Appearance") }
    var appearance: String { text("外观", "Appearance") }
    var system: String { text("跟随系统", "System") }
    var light: String { text("浅色", "Light") }
    var dark: String { text("深色", "Dark") }
    var textSize: String { text("文字大小", "Text Size") }
    var copy: String { text("复制文章", "Copy Article") }
    var copied: String { text("已复制", "Copied") }
    var info: String { text("文档信息", "Document Information") }
    var version: String { text("文档版本", "Guide Version") }
    var source: String { text("来源版本", "Source Revision") }
    var languageLabel: String { text("语言", "Language") }
    var openSetting: String { text("打开此设置", "Open This Setting") }
    var enlargeImage: String { text("放大图片", "Enlarge Image") }
    var relatedHelp: String { text("相关帮助", "Related Help") }
    var readGuide: String { text("查看指南", "Read Guide") }
    var readFullChapter: String { text("阅读完整章节", "Read Full Chapter") }
}
