// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBuildingRecords
import FloeBuildingSystems
import FloeBuildingWorkspace

extension BuildingCopy {
    static func errorMessage(_ error: Error,locale:Locale = .current) -> String {
        if let value = error as? BuildingRecordsError {
            switch value {
            case .revisionConflict:
                return text("工程已有更新。请重新打开，再检查并重试。", "The project changed. Reopen, review and retry.",locale:locale)
            case .contentTooLarge:
                return text("文件超过当前导入大小限制，请拆分后重试。", "The file exceeds the current import limit. Split it and retry.",locale:locale)
            case .sourceFileMissing:
                return text("找不到原件，请重新导入或恢复工程备份。", "The original is missing. Reimport it or restore a project backup.",locale:locale)
            case .sourceFileCorrupted:
                return text("原件与保存记录不一致，请从原始文件或备份恢复。", "The original differs from its saved record. Restore it from the source or a backup.",locale:locale)
            case .emptyContent:
                return text("文件为空，请选择有内容的文件。", "The file is empty. Choose a file with content.",locale:locale)
            default: break
            }
        }
        if let value = error as? BuildingWorkspaceError {
            switch value {
            case .wrongProject: return text("资料不属于当前工程，请检查所选工程。", "The data belongs to another project. Check the selected project.",locale:locale)
            case .concurrentSnapshot: return text("工程正在更新，请稍后重新打开。", "The project is updating. Reopen it shortly.",locale:locale)
            case .componentBudget: return text("方案超过当前保存限制，请缩小范围后重试。", "The design exceeds the current save limit. Reduce its scope and retry.",locale:locale)
            case .componentChanged: return text("此方案已有其他更新。本地修改仍保留，请导出或重新打开后比较。", "This design changed elsewhere. Local edits are retained; export them or reopen to review.",locale:locale)
            case .revisionRequired: return text("请先读取工程当前版本，再执行修改。", "Read the current project revision before editing.",locale:locale)
            case .closed: return text("工程已关闭，请重新打开后继续。", "The project is closed. Reopen it to continue.",locale:locale)
            }
        }
        return error.localizedDescription
    }
    static func issueTitle(_ issue: SystemPlanIssue,locale:Locale = .current) -> String {
        let zh: String
        switch issue.code {
        case "invalid-plan-budget": zh = "方案规模或版本无效，请检查导入内容。"
        case "duplicate-or-excessive-identity": zh = "存在重复对象，请检查导入和复制结果。"
        case "missing-device-definition": zh = "请补齐设备名称、准确型号与资料版本。"
        case "unknown-room": zh = "设备关联的房间不在此工程中。"
        case "nonfinite-placement": zh = "设备位置无效，请重新定位。"
        case "unplaced-device": zh = "设备已在料单中，尚待布置。"
        case "invalid-channel-count": zh = "请核对设备通道数量。"
        case "neutral-port-required": zh = "此开关需要单独的零线端子。"
        case "gateway-missing": zh = "缺少设备要求的网关。"
        case "invalid-port-rating", "invalid-voltage-range": zh = "请核对端口电压、电流和连接容量。"
        case "unknown-or-self-endpoint": zh = "线路需要连接两个不同且有效的端口。"
        case "duplicate-connection": zh = "同一对端口被重复连接。"
        case "medium-mismatch", "terminal-mismatch": zh = "连接两端的接口或端子不匹配。"
        case "terminal-role-unverified", "terminal-mapping-unverified": zh = "请补齐端子定义和对应关系。"
        case "two-sources": zh = "线路连接了两个供电输出，请核对接线。"
        case "protocol-mismatch": zh = "连接两端使用了不同协议。"
        case "protocol-unverified": zh = "请补齐并核对通信协议。"
        case "interface-profile-mismatch": zh = "连接两端的接口配置不兼容。"
        case "voltage-mismatch": zh = "供电电压不在负载允许范围内。"
        case "rating-evidence-missing": zh = "请补充端口额定参数的资料依据。"
        case "power-conditions-unverified": zh = "供电条件尚未补齐，当前不能判断兼容。"
        case "segment-medium-mismatch": zh = "线路与所属总线段的接口不一致。"
        case "termination-conditions-unverified": zh = "请核对总线终端条件并保留依据。"
        case "unknown-segment": zh = "线路引用的总线段已不存在。"
        case "invalid-cable-route": zh = "线路路径无效，请检查布线位置。"
        case "required-port-unconnected": zh = "存在必须接线但尚未连接的端口。"
        case "port-capacity-exceeded": zh = "端口连接数量超过已知容量。"
        case "supply-current-exceeded": zh = "负载电流合计超过供电容量。"
        case "current-budget-unverified": zh = "电流参数不齐，尚不能核对供电容量。"
        case "scene-description-missing": zh = "请补齐场景名称、触发条件与计划动作。"
        case "scene-device-empty": zh = "此场景尚未关联设备。"
        case "scene-device-missing": zh = "场景引用了已移除的设备。"
        default: zh = "此项需要核对，请查看详细信息。"
        }
        return text(zh, issue.detail,locale:locale)
    }
}
