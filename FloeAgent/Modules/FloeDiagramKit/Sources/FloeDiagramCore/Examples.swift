// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum DiagramExamples {
    public static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "D1A60000-0000-4000-8000-%012d", n))! }
    public static let pixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAAAoCAYAAABOzvzpAAAAWElEQVR4nO3QMQ0AIAwAwarCDuY6IYQZR6CiaUhueAF/MWbeH1r7lBTdYwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAdwAPxQrmIvlwxygAAAABJRU5ErkJggg==")!
    public static func library() -> DiagramDocument {
        let root = id(100), space = id(102), research = id(101), design = id(103), delivery = id(104)
        let task1 = id(1_001), task2 = id(1_002), task3 = id(1_003), asset = id(50)
        let source = DiagramSourceReference(id: id(60), documentID: "sample-interviews", locator: "page=3", title: "需求访谈.pdf", sourceRevision: "1", excerpt: "增加安静阅读与无障碍动线")
        let main = DiagramPage(id: id(2), title: "总览", elements: [
            .init(id: root, title: "社区图书馆改造", style: .init(fill: "accent", stroke: "accent", text: "onAccent", fontSize: 18, bold: true)),
            .init(id: research, title: "需求调研", parentID: root, order: 0,
                  content: [.note("整理读者访谈、使用时段和现有空间问题。")], taskID: task1, sources: [source]),
            .init(id: space, title: "空间规划", parentID: root, order: 1,
                  content: [.richText([.init("安静阅读", bold: true), .init("与交流活动分区，保留自然光。")])], taskID: task2, sources: [source]),
            .init(id: design, title: "方案设计", parentID: root, order: 2, contentExpanded: true,
                  content: [.table(.init(rows: [["空间", "席位"], ["安静阅读", "120"], ["共享活动", "40"]])),
                            .formula("A = \\pi r^2"), .code(language: "swift", text: "let seats = 120 + 40")]),
            .init(id: delivery, title: "实施计划", parentID: root, order: 3, taskID: task3, links: [.init(pageID: id(4), title: "项目计划")]),
            .init(id: id(105), title: "无障碍动线", parentID: space, order: 0),
            .init(id: id(106), title: "自然采光", parentID: space, order: 1),
            .init(id: id(107), kind: .floatingTopic, title: "是否增加夜间阅读区？", frame: .init(x: 80, y: 440, width: 220, height: 64), tags: ["待确认"])
        ], connections: [.init(id: id(400), from: research, to: design, label: "调研依据", dashed: true, endArrow: true)],
           theme: .init(id: id(10)))
        let pool = id(500), lane1 = id(501), lane2 = id(502)
        let flow = DiagramPage(id: id(3), title: "评审流程", structure: .flow, elements: [
            .init(id: pool, kind: .swimlanePool, title: "方案评审", frame: .init(x: 0, y: 0, width: 880, height: 390)),
            .init(id: lane1, kind: .swimlane, title: "方案组", containerID: pool, frame: .init(x: 0, y: 45, width: 880, height: 165)),
            .init(id: lane2, kind: .swimlane, title: "项目组", containerID: pool, frame: .init(x: 0, y: 210, width: 880, height: 180)),
            .init(id: id(510), kind: .roundedRectangle, title: "整理需求", containerID: lane1, frame: .init(x: 95, y: 100)),
            .init(id: id(511), kind: .rectangle, title: "形成空间方案", containerID: lane1, frame: .init(x: 350, y: 100)),
            .init(id: id(512), kind: .diamond, title: "资料齐全？", containerID: lane1, frame: .init(x: 610, y: 90, width: 150, height: 90)),
            .init(id: id(513), kind: .roundedRectangle, title: "联合评审", containerID: lane2, frame: .init(x: 610, y: 280), taskID: task3),
            .init(id: id(514), kind: .roundedRectangle, title: "确认实施计划", containerID: lane2, frame: .init(x: 350, y: 280))
        ], connections: [
            .init(id: id(600), from: id(510), to: id(511), kind: .flow, route: .orthogonal, endArrow: true),
            .init(id: id(601), from: id(511), to: id(512), kind: .flow, route: .orthogonal, endArrow: true),
            .init(id: id(602), from: id(512), to: id(513), kind: .flow, route: .orthogonal, label: "是", endArrow: true),
            .init(id: id(603), from: id(513), to: id(514), kind: .flow, route: .orthogonal, endArrow: true),
            .init(id: id(604), from: id(512), to: id(511), kind: .flow, route: .orthogonal, label: "补充资料", dashed: true, endArrow: true)
        ], theme: .init(id: id(11)))
        let tasks = [
            DiagramTask(id: task1, title: "完成读者访谈", status: .done, priority: 2, assignee: "林", start: Date(timeIntervalSince1970: 1_793_577_600), end: Date(timeIntervalSince1970: 1_793_923_200)),
            DiagramTask(id: task2, title: "确认空间分区", status: .inProgress, progress: 0.6, priority: 3, assignee: "陈", start: Date(timeIntervalSince1970: 1_794_182_400), end: Date(timeIntervalSince1970: 1_794_441_600)),
            DiagramTask(id: task3, title: "方案联合评审", priority: 3, assignee: "周", start: Date(timeIntervalSince1970: 1_794_787_200), end: Date(timeIntervalSince1970: 1_794_960_000))
        ]
        return .init(id: id(1), title: "社区图书馆改造", pages: [main, flow, .init(id: id(4), title: "项目计划", elements: [
            .init(id: id(700), title: "项目计划"),
            .init(id: id(701), title: "完成读者访谈", parentID: id(700), order: 0, taskID: task1),
            .init(id: id(702), title: "确认空间分区", parentID: id(700), order: 1, taskID: task2),
            .init(id: id(703), title: "方案联合评审", parentID: id(700), order: 2, taskID: task3)
        ], theme: .init(id: id(12)))], tasks: tasks,
                     dependencies: [.init(id: id(800), predecessorID: task1, successorID: task2), .init(id: id(801), predecessorID: task2, successorID: task3)],
                     assets: [.init(id: asset, fileName: "sample.png", mediaType: "image/png", byteCount: pixelPNG.count, sha256: DiagramCodec.digest(pixelPNG))])
    }
    public static func large(count: Int = 10_000, rich: Bool = false) -> DiagramDocument {
        let count = max(1, min(100_000, count))
        let elements = (0..<count).map { i in
            DiagramElement(id: id(100 + i), title: "主题 \(i + 1)", parentID: i == 0 ? nil : id(100 + (i - 1) / 4), order: i,
                           contentExpanded: rich, content: rich ? [.richText([.init("图文测试内容 ", bold: true), .init("用于测量排版和显示。")]), .image(assetID: id(900_000), caption: "共享示例图片"), .formula("x^2 + y^2 = r^2")] : [])
        }
        return .init(id: id(1), title: "\(count) 个主题", pages: [.init(id: id(2), elements: elements, theme: .init(id: id(10)))],
                     assets: rich ? [.init(id: id(900_000), fileName: "sample.png", mediaType: "image/png", byteCount: pixelPNG.count, sha256: DiagramCodec.digest(pixelPNG))] : [])
    }
}
