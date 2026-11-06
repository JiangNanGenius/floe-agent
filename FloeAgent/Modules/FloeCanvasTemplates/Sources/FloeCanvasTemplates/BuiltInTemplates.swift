import Foundation
import CryptoKit
import FloeCanvasCore

public enum BuiltInCanvasTemplates {
    public static var all: [CanvasTemplate] {
        [
            make("research", .research, .init("Research board", "资料研究"),
                 .init("Connect sources, questions and evidence on one board.", "在一张画布中整理来源、问题与证据。"),
                 [.analyzeReference, .organize]),
            make("compare", .research, .init("Compare and decide", "方案比较"),
                 .init("Keep alternatives and their evidence side by side.", "并排保留方案、依据和待确认事项。"),
                 [.analyzeReference, .ideate, .organize]),
            make("ideas", .ideas, .init("Ideas and references", "脑暴与参考"),
                 .init("Collect references and develop a direction.", "收集参考，逐步形成创作方向。"),
                 [.ideate, .organize]),
            make("image-exploration", .image, .init("Image exploration", "图片探索"),
                 .init("Explore references, candidates and editable results.", "从参考探索候选，再继续编辑。"),
                 [.ideate, .generateImage, .editImage]),
            make("image-design", .image, .init("Drawing and layout", "绘画与排版"),
                 .init("Design a cover, poster or composition.", "制作封面、海报或图像排版。"),
                 [.designLayout, .editImage]),
            make("video", .video, .init("Video production", "短视频制作"),
                 .init("Develop a script, shots, sound and an editable film.", "从脚本和镜头到声音与可编辑成片。"),
                 [.writeScript, .planShots, .generateVideo, .editVideo]),
            make("short-drama", .film, .init("Short drama", "短剧与影视"),
                 .init("Keep scripts, characters, scenes and shots connected.", "关联剧本、角色、场景和镜头。"),
                 [.writeScript, .extractCharacters, .planShots, .generateImage, .generateVideo, .synthesizeVoice, .editVideo],
                 film: true),
            make("song", .music, .init("Songwriting", "歌曲创作"),
                 .init("Keep ideas, references, lyrics and a song together.", "一起保存灵感、参考、歌词和歌曲。"),
                 [.ideate, .writeLyrics, .generateMusic, .editMusic]),
            make("score", .music, .init("Score and accompaniment", "配乐与伴奏"),
                 .init("Compose to a mood, reference or target duration.", "按情绪、参考和目标时长制作配乐。"),
                 [.analyzeReference, .generateMusic, .editMusic]),
            make("music-video", .video, .init("Music video", "音乐 MV"),
                 .init("Bring a song, visual ideas and edited footage together.", "把歌曲、视觉构思和镜头组织成 MV。"),
                 [.planShots, .generateImage, .generateVideo, .editVideo]),
            make("podcast", .audio, .init("Podcast and audio", "播客与音频"),
                 .init("Prepare a script, voice, music and a finished mix.", "准备文稿、声音、音乐并完成混音。"),
                 [.writeScript, .synthesizeVoice, .editMusic]),
            make("cad", .design, .init("Product and CAD study", "产品与 CAD 构思"),
                 .init("Collect constraints and develop an editable design.", "整理参考与约束，继续完成可编辑设计。"),
                 [.analyzeReference, .editCAD, .renderCAD])
        ]
    }
    public static func template(id: UUID) -> CanvasTemplate? { all.first { $0.id == id } }

    private static func stable(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(("floe.canvas.template.v1/" + key).utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private static func make(_ key: String, _ category: TemplateCategory,
                             _ title: TemplateText, _ summary: TemplateText,
                             _ operations: [TemplateOperation], film: Bool = false) -> CanvasTemplate {
        let canvasID = stable(key + "/canvas"), pageID = stable(key + "/page"), graphID = stable(key + "/graph")
        let briefID = stable(key + "/brief"), refID = stable(key + "/references")
        var brief = CanvasNodeSnapshot(id: briefID, title: "创作目标 / Goal", content: .text(""),
            frame: frame(0, 0), metadata: ["floe.template.required": "true", "floe.template.input": "brief"])
        var references = CanvasNodeSnapshot(id: refID, title: "参考 / References", content: .text(""),
            frame: frame(0, 230), metadata: ["floe.template.input": "references"])
        try! CreativePurpose(.brief).apply(to: &brief)
        try! CreativePurpose(.reference).apply(to: &references)
        var nodes = [brief, references]
        var flowNodes: [FlowNode] = []
        var edges: [FlowEdge] = []
        func source(_ name: String, _ canvasNodeID: UUID) -> FlowNode {
            FlowNode(id: stable(key + "/source/" + name), kind: .source, name: name,
                ports: [.init(id: stable(key + "/port/" + name), name: "output", dataType: .json, direction: .output)],
                parameters: ["sourceKind": .string("canvasBinding"),
                    "bindingKey": .string(CanvasTemplateEngine.sourcePrefix + canvasNodeID.uuidString),
                    CanvasFlowSourceParameterKey.canvasID: .string(canvasID.uuidString),
                    CanvasFlowSourceParameterKey.pageID: .string(pageID.uuidString),
                    CanvasFlowSourceParameterKey.nodeID: .string(canvasNodeID.uuidString)])
        }
        let goal = source("goal", briefID), refs = source("references", refID)
        flowNodes += [goal, refs]
        var previous = goal
        var previousCardID = briefID
        var relations: [CanvasConnectionSnapshot] = []
        for (index, operation) in operations.enumerated() {
            let prefix = key + "/step/\(index)"
            let flow = FlowNode(id: stable(prefix), kind: .transform, name: operation.rawValue,
                ports: [
                    .init(id: stable(prefix + "/in"), name: "input", dataType: .json, direction: .input),
                    .init(id: stable(prefix + "/refs"), name: "references", dataType: .json, direction: .input),
                    .init(id: stable(prefix + "/out"), name: "output", dataType: .json, direction: .output)
                ], parameters: [TemplateOperation.parameterKey: .string(operation.rawValue)],
                position: .init(x: Double(index + 1) * 340, y: 0))
            edges.append(.init(id: stable(prefix + "/edge"), sourceNodeID: previous.id,
                sourcePortID: previous.ports.first(where: { $0.direction == .output })!.id,
                destinationNodeID: flow.id, destinationPortID: flow.ports[0].id))
            edges.append(.init(id: stable(prefix + "/ref-edge"), sourceNodeID: refs.id,
                sourcePortID: refs.ports[0].id, destinationNodeID: flow.id, destinationPortID: flow.ports[1].id))
            var card = CanvasNodeSnapshot(id: stable(prefix + "/card"), kind: .generationTask,
                title: operationTitle(operation), content: .text(""), frame: frame(Double(index + 1) * 340, 0))
            CanvasFlowCardBinding(graphID: graphID, nodeID: flow.id).applied(to: &card.metadata)
            relations.append(.init(id: stable(prefix + "/relation"), sourceNodeID: previousCardID,
                destinationNodeID: card.id, kind: .source))
            nodes.append(card); flowNodes.append(flow)
            previous = flow; previousCardID = card.id
        }
        let outID = stable(key + "/output")
        let output = FlowNode(id: outID, kind: .output, name: "result",
            ports: [.init(id: stable(key + "/output/input"), name: "result", dataType: .json, direction: .input)],
            parameters: ["resultKey": .string("result")])
        edges.append(.init(id: stable(key + "/output/edge"), sourceNodeID: previous.id,
            sourcePortID: previous.ports.first(where: { $0.direction == .output })!.id,
            destinationNodeID: output.id, destinationPortID: output.ports[0].id))
        var result = CanvasNodeSnapshot(id: stable(key + "/output/card"), title: "作品 / Result",
            content: .text(""), frame: frame(Double(operations.count + 1) * 340, 0))
        CanvasFlowCardBinding(graphID: graphID, nodeID: outID).applied(to: &result.metadata)
        try! CreativePurpose(.finalOutput).apply(to: &result)
        nodes.append(result); flowNodes.append(output)
        var records: [CreativeRecord] = []
        if film {
            let characterID = stable(key + "/character"), sceneID = stable(key + "/scene")
            for (suffix, role, recordID) in [
                ("character", CreativePurpose.Role.characterReference, characterID),
                ("scene", CreativePurpose.Role.sceneReference, sceneID)
            ] {
                var n = CanvasNodeSnapshot(id: stable(key + "/" + suffix + "/card"),
                    title: suffix == "character" ? "角色参考 / Character" : "场景参考 / Scene",
                    content: .text(""), frame: frame(suffix == "character" ? 340 : 680, 230))
                try! CreativePurpose(role, recordID: recordID).apply(to: &n)
                nodes.append(n)
                records.append(.init(id: recordID, kind: suffix == "character" ? .character : .scene,
                    name: suffix, nodeIDs: [n.id]))
            }
            for index in 0..<3 {
                let shotID = stable(key + "/shot/\(index)")
                var n = CanvasNodeSnapshot(id: stable(key + "/shot/\(index)/card"),
                    title: "镜头 \(index + 1) / Shot \(index + 1)", content: .text(""),
                    frame: frame(Double(index + 1) * 340, 470))
                try! CreativePurpose(.shotDescription, recordID: shotID,
                    referenceNodeIDs: records.filter { $0.kind != .shot }.flatMap(\.nodeIDs)).apply(to: &n)
                nodes.append(n)
                records.append(.init(id: shotID, kind: .shot, name: "Shot \(index + 1)",
                    order: index, duration: 5, nodeIDs: [n.id], relatedRecordIDs: [characterID, sceneID]))
            }
        }
        let graph = FlowGraph(id: graphID, nodes: flowNodes, edges: edges)
        let snapshot = CanvasSnapshot(id: canvasID, name: title.zh,
            pages: [.init(id: pageID, name: title.zh, nodes: nodes, connections: relations, flowGraphs: [graph])])
        return CanvasTemplate(id: stable(key), title: title, summary: summary, category: category,
            isBuiltIn: true, snapshot: snapshot,
            slots: [.init(id: "brief", title: .init("Goal", "创作目标"), nodeID: briefID, required: true),
                    .init(id: "references", title: .init("References", "参考素材"), nodeID: refID)],
            records: records)
    }
    private static func frame(_ x: Double, _ y: Double) -> CanvasGeometry.Frame {
        .init(center: .init(x: x, y: y), size: .init(width: 280, height: 170))
    }
    private static func operationTitle(_ op: TemplateOperation) -> String {
        switch op {
        case .ideate: return "脑暴 / Ideas"
        case .organize: return "整理 / Organize"
        case .analyzeReference: return "分析参考 / References"
        case .writeScript: return "文稿 / Script"
        case .writeLyrics: return "歌词 / Lyrics"
        case .planShots: return "分镜 / Shots"
        case .extractCharacters: return "角色与场景 / Characters"
        case .generateImage: return "生成图片 / Generate images"
        case .generateVideo: return "生成视频 / Generate video"
        case .generateMusic: return "生成音乐 / Generate music"
        case .synthesizeVoice: return "配音 / Voice"
        case .designLayout: return "排版 / Layout"
        case .editImage: return "图像编辑 / Image editor"
        case .editVideo: return "视频剪辑 / Video editor"
        case .editMusic: return "音乐编辑 / Music editor"
        case .editCAD: return "CAD 编辑 / CAD editor"
        case .renderCAD: return "设计预览 / Design preview"
        }
    }
}
