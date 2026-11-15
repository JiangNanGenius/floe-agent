// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct SystemLegendVertex:Codable,Equatable,Sendable {
    public var x:Double;public var y:Double
    public init(_ x:Double,_ y:Double){self.x=x;self.y=y}
}
public struct SystemLegendStroke:Codable,Equatable,Sendable {
    public var vertices:[SystemLegendVertex]
    public var closed:Bool
    public init(_ vertices:[SystemLegendVertex],closed:Bool=false){self.vertices=vertices;self.closed=closed}
}
public struct SystemLegendPreset:Codable,Equatable,Sendable,Identifiable {
    public var id:String
    public var nameZH:String
    public var nameEN:String
    public var strokes:[SystemLegendStroke]
    public var terminalLabels:[String]
    public var medium:SystemPortMedium
    public var roles:[SystemTerminalRole]
    public var requiresNeutral:Bool?
    /// Original planning glyphs, not a claim of a licensed IEC/ANSI symbol set.
    public var convention:String{"Floe planning preset v1"}
}
public enum SystemLegendCatalog {
    public static var presets:[SystemLegendPreset] {
        let box=[SystemLegendStroke([.init(8,8),.init(44,8),.init(44,36),.init(8,36)],closed:true)]
        func line(_ values:[Double])->SystemLegendStroke {
            .init(stride(from:0,to:values.count,by:2).map{.init(values[$0],values[$0+1])})
        }
        func ring(_ x:Double,_ y:Double,_ radius:Double)->SystemLegendStroke {
            .init((0..<24).map { index in
                let angle=Double(index) * .pi / 12
                return .init(x+cos(angle)*radius,y+sin(angle)*radius)
            },closed:true)
        }
        func glyph(_ id:String)->[SystemLegendStroke] {
            switch id {
            case "ac-plug-lnp": return [line([14,10,14,20,38,20,38,10]),line([20,2,20,10]),line([32,2,32,10]),line([26,20,26,36])]
            case "ac-socket-lnp": return [ring(26,22,16),line([20,14,20,24]),line([32,14,32,24]),line([22,30,30,30])]
            case "neutral-switch": return box+[line([16,28,34,14]),ring(15,28,2),ring(36,14,2)]
            case "dc-supply": return box+[line([14,18,22,18,22,12,30,12,30,18,38,18]),line([16,27,36,27])]
            case "dc-load": return [ring(26,22,15),line([16,12,36,32]),line([16,32,36,12])]
            case "dry-relay": return box+[line([13,27,23,27,34,14]),line([34,12,40,12]),line([34,28,40,28])]
            case "ethernet-port": return box+[line([15,14,37,14,37,26,32,26,32,31,20,31,20,26,15,26,15,14])]
            case "poe-ap": return [ring(26,28,3),line([17,23,21,20,31,20,35,23]),line([10,17,17,12,35,12,42,17]),line([3,10,13,4,39,4,49,10])]
            case "analog-dimming": return box+[line([15,28,36,13]),line([28,13,36,13,36,21])]
            case "rs485-node": return box+[line([13,17,39,17]),line([13,27,39,27]),line([19,13,19,31])]
            case "can-node": return box+[line([13,14,20,22,32,22,39,14]),line([13,30,20,22,32,22,39,30])]
            default: return box+[line([14,14,14,30,26,30,35,22,26,14,14,14])]
            }
        }
        func preset(_ id:String,_ zh:String,_ en:String,_ medium:SystemPortMedium,_ roles:[SystemTerminalRole],_ labels:[String],neutral:Bool?=nil)->SystemLegendPreset {
            let terminals=roles.indices.map { index in
                let x=12+Double(index)*8
                return SystemLegendStroke([.init(x,36),.init(x,44)])
            }
            return .init(id:id,nameZH:zh,nameEN:en,strokes:glyph(id)+terminals,terminalLabels:labels,medium:medium,roles:roles,requiresNeutral:neutral)
        }
        return [
            preset("rs485-node","RS-485 节点","RS-485 node",.rs485,[.signalA,.signalB,.signalReference],["A","B","REF"]),
            preset("can-node","CAN 节点","CAN node",.can,[.canH,.canL,.signalReference],["H","L","REF"]),
            preset("ac-plug-lnp","L/N/PE 插头","L/N/PE plug",.acPower,[.line,.neutral,.protectiveEarth],["L","N","PE"]),
            preset("ac-socket-lnp","L/N/PE 插座","L/N/PE socket",.acPower,[.line,.neutral,.protectiveEarth],["L","N","PE"]),
            preset("neutral-switch","需要零线的开关","Neutral-required switch",.acPower,[.line,.neutral],["L","N"],neutral:true),
            preset("dc-supply","低压直流电源","Low-voltage DC supply",.dcPower,[.positive,.negative],["+","−"]),
            preset("dc-load","低压直流负载","Low-voltage DC load",.dcPower,[.positive,.negative],["+","−"]),
            preset("dry-relay","干接点继电器","Dry-contact relay",.dryContact,[.common,.normallyOpen,.normallyClosed],["COM","NO","NC"]),
            preset("ethernet-port","以太网端口","Ethernet port",.ethernet,[.data],["LAN"]),
            preset("poe-ap","PoE AP","PoE AP",.ethernet,[.data],["PoE"]),
            preset("analog-dimming","模拟调光接口","Analog dimming interface",.analogDimming,[.positive,.signalReference],["DIM","REF"]),
            preset("dali-interface","DALI 接口","DALI interface",.dali,[.data],["DA"])
        ]
    }
    /// Creates a draft without inventing voltage, protocol or product ratings.
    public static func draft(from preset:SystemLegendPreset,name:String,productReference:String="",assetVersion:String="",roomID:UUID?=nil)->SmartHomeEquipment {
        let ports=zip(preset.roles,preset.terminalLabels).map { role,label in
            SmartHomePort(label:label,medium:preset.medium,terminal:role,
                direction:preset.id=="dc-supply" ? .source:preset.id=="dc-load" ? .sink:.bidirectional,
                maximumConnections:preset.medium == .ethernet ? 1:nil)
        }
        return .init(name:name,productReference:productReference,assetVersion:assetVersion,roomID:roomID,ports:ports,requiresNeutral:preset.requiresNeutral)
    }
}
public struct SystemBOMRow:Codable,Equatable,Sendable,Identifiable {
    public var id:String
    public var productReference:String
    public var assetVersion:String
    public var roomID:UUID?
    public var physicalDeviceCount:Int
    public var knownChannelCount:Int
    public var unknownChannelDeviceCount:Int
    public var spare:Bool
}
public enum SmartHomeSchedules {
    public static func bom(_ plan:SmartHomePlan)->[SystemBOMRow] {
        var rows:[String:SystemBOMRow]=[:]
        for item in plan.equipment {
            let fields=[item.productReference,item.assetVersion,item.roomID?.uuidString ?? "unassigned",item.isSpare ? "spare":"planned"]
            // JSON encodes boundaries, so names containing separators cannot collide.
            let key=String(data:(try? JSONEncoder().encode(fields)) ?? Data(),encoding:.utf8) ?? item.id.uuidString
            var row=rows[key] ?? .init(id:key,productReference:item.productReference,assetVersion:item.assetVersion,
                roomID:item.roomID,physicalDeviceCount:0,knownChannelCount:0,unknownChannelDeviceCount:0,spare:item.isSpare)
            row.physicalDeviceCount+=1
            if let channels=item.channelCount,channels>0,channels<=4096 {row.knownChannelCount+=channels}
            else{row.unknownChannelDeviceCount+=1}
            rows[key]=row
        }
        return rows.values.sorted{$0.id<$1.id}
    }
    private static func csv(_ rows:[[String]])->String {
        rows.map{$0.map{"\""+$0.replacingOccurrences(of:"\"",with:"\"\"")+"\""}.joined(separator:",")}.joined(separator:"\r\n")+"\r\n"
    }
    public static func bomCSV(_ plan:SmartHomePlan)->String {
        csv([["product","asset_version","room_id","physical_devices","known_channels","unknown_channel_devices","role"]]+bom(plan).map {
            [$0.productReference,$0.assetVersion,$0.roomID?.uuidString ?? "",String($0.physicalDeviceCount),String($0.knownChannelCount),String($0.unknownChannelDeviceCount),$0.spare ? "spare":"planned"]
        })
    }
    public static func wiringCSV(_ plan:SmartHomePlan)->String {
        csv([["connection_id","first_port_id","second_port_id","segment_id","label","cable","routed_length_m"]]+plan.connections.map {
            [$0.id.uuidString,$0.firstPortID.uuidString,$0.secondPortID.uuidString,$0.segmentID?.uuidString ?? "",$0.label,$0.cableProduct ?? "",$0.routedLengthM.map{String($0)} ?? ""]
        })
    }
    public static func scenesCSV(_ plan:SmartHomePlan)->String {
        csv([["scene_id","name","trigger","condition","planned_action","equipment_ids"]]+plan.scenes.map {
            [$0.id.uuidString,$0.name,$0.triggerDescription,$0.conditionDescription,$0.actionDescription,$0.equipmentIDs.map(\.uuidString).joined(separator:";")]
        })
    }
}
