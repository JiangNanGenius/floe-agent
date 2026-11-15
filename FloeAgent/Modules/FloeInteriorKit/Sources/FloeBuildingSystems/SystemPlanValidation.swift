// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum SystemIssueSeverity:String,Codable,Sendable {case invalid,needsInput,information}
public struct SystemPlanIssue:Codable,Equatable,Sendable,Identifiable {
    public var code:String
    public var severity:SystemIssueSeverity
    public var objectIDs:[UUID]
    public var detail:String
    public var id:String{code+"/"+objectIDs.map(\.uuidString).joined(separator:"/")}
}
public struct SystemPlanValidation:Codable,Equatable,Sendable {
    public var issues:[SystemPlanIssue]
    public var invalidCount:Int{issues.filter{$0.severity == .invalid}.count}
    public var needsInputCount:Int{issues.filter{$0.severity == .needsInput}.count}
    public var state:String{invalidCount>0 ? "invalid":needsInputCount>0 ? "needs-input":"checked-declared-connections"}
}
public enum SmartHomePlanValidator {
    public static func validate(_ plan:SmartHomePlan)->SystemPlanValidation {
        var issues:[SystemPlanIssue]=[]
        func issue(_ code:String,_ severity:SystemIssueSeverity,_ ids:[UUID],_ detail:String){
            issues.append(.init(code:code,severity:severity,objectIDs:ids,detail:detail))
        }
        guard plan.revision>=0,plan.equipment.count<=4096,plan.connections.count<=16384,
              plan.segments.count<=4096,plan.scenes.count<=4096,
              plan.equipment.allSatisfy({$0.ports.count<=256}),
              plan.equipment.reduce(0,{$0+$1.ports.count})<=32768 else {
            issue("invalid-plan-budget",.invalid,[plan.id],"Plan revision or collection budget is invalid")
            return .init(issues:issues)
        }
        let ports=plan.equipment.flatMap(\.ports)
        let allIDs=plan.equipment.map(\.id)+ports.map(\.id)+plan.connections.map(\.id)+plan.segments.map(\.id)+plan.scenes.map(\.id)
        guard Set(allIDs).count==allIDs.count,Set(plan.roomIDs).count==plan.roomIDs.count,ports.count<=32768 else {
            issue("duplicate-or-excessive-identity",.invalid,[plan.id],"Equipment, ports, connections and segments need distinct stable IDs")
            return .init(issues:issues)
        }
        let byID=Dictionary(uniqueKeysWithValues:ports.map{($0.id,$0)})
        let segments=Dictionary(uniqueKeysWithValues:plan.segments.map{($0.id,$0)})
        let deviceIDs=Set(plan.equipment.map(\.id)),roomIDs=Set(plan.roomIDs)
        var counts:[UUID:Int]=[:],outgoing:[UUID:[SmartHomePort]]=[:]
        var endpointPairs:Set<String>=[]
        for device in plan.equipment {
            if device.name.isEmpty || device.productReference.isEmpty || device.assetVersion.isEmpty {
                issue("missing-device-definition",.needsInput,[device.id],"Name and exact product/version are needed")
            }
            if let room=device.roomID,!roomIDs.contains(room){issue("unknown-room",.invalid,[device.id,room],"Room is not in this plan")}
            if let position=device.positionMM,!position.isFinite{issue("nonfinite-placement",.invalid,[device.id],"Placement must use finite mm coordinates")}
            if !device.isSpare && device.positionMM==nil{issue("unplaced-device",.information,[device.id],"BOM device is awaiting placement")}
            if let count=device.channelCount,count<=0{issue("invalid-channel-count",.invalid,[device.id],"Channel count must be positive when supplied")}
            if device.requiresNeutral==true && !device.ports.contains(where:{$0.medium == .acPower && $0.terminal == .neutral}) {
                issue("neutral-port-required",.invalid,[device.id],"This switch requires a distinct neutral terminal")
            }
            if let required=device.gatewayRequirement,!plan.equipment.contains(where:{$0.providedGatewayProfile==required && !$0.isSpare}) {
                issue("gateway-missing",.needsInput,[device.id],"Required gateway profile: "+required)
            }
        }
        for port in ports {
            let values=[port.nominalVoltageV,port.minimumVoltageV,port.maximumVoltageV,port.maximumCurrentA,port.demandCurrentA].compactMap{$0}
            if !values.allSatisfy({$0.isFinite && $0>=0}) || (port.maximumConnections.map{$0<1} ?? false) {
                issue("invalid-port-rating",.invalid,[port.id],"Port rating or capacity is invalid")
            }
            if let low=port.minimumVoltageV,let high=port.maximumVoltageV,low>high{issue("invalid-voltage-range",.invalid,[port.id],"Minimum exceeds maximum")}
        }
        for connection in plan.connections {
            guard connection.firstPortID != connection.secondPortID,
                  let a=byID[connection.firstPortID],let b=byID[connection.secondPortID] else {
                issue("unknown-or-self-endpoint",.invalid,[connection.id],"Connection needs two existing, different ports");continue
            }
            let pair=[a.id.uuidString,b.id.uuidString].sorted().joined(separator:"/")
            if !endpointPairs.insert(pair).inserted{issue("duplicate-connection",.invalid,[connection.id],"The same endpoints are connected twice")}
            counts[a.id,default:0]+=1;counts[b.id,default:0]+=1
            if a.direction == .source{outgoing[a.id,default:[]].append(b)}
            if b.direction == .source{outgoing[b.id,default:[]].append(a)}
            guard a.medium==b.medium else{issue("medium-mismatch",.invalid,[connection.id,a.id,b.id],"Port media differ");continue}
            if a.medium != .wireless && (a.terminal == .unspecified || b.terminal == .unspecified) {
                issue("terminal-role-unverified",.needsInput,[connection.id],"Exact terminal roles are not declared")
            }
            if a.terminal != .unspecified && b.terminal != .unspecified && a.terminal != b.terminal && a.medium != .dryContact {
                issue("terminal-mismatch",.invalid,[connection.id,a.id,b.id],"Terminal roles require an explicit compatible mapping")
            }
            if a.direction == .source && b.direction == .source{issue("two-sources",.invalid,[connection.id],"Two source outputs cannot be assumed connectable")}
            if a.medium == .rs485 || a.medium == .can || a.medium == .dali {
                if let ap=a.protocolName,let bp=b.protocolName,ap != bp{issue("protocol-mismatch",.invalid,[connection.id],"Declared protocols differ")}
                else if a.protocolName==nil || b.protocolName==nil{issue("protocol-unverified",.needsInput,[connection.id],"Physical bus type does not establish protocol compatibility")}
                if a.compatibilityProfile==nil || b.compatibilityProfile==nil {
                    issue("terminal-mapping-unverified",.needsInput,[connection.id],"Exact interface and terminal mapping evidence is needed")
                } else if a.compatibilityProfile != b.compatibilityProfile {
                    issue("interface-profile-mismatch",.invalid,[connection.id],"Declared interface profiles differ")
                }
            }
            if a.medium == .acPower || a.medium == .dcPower {
                let source=a.direction == .source ? a:b.direction == .source ? b:nil
                let sink=a.direction == .sink ? a:b.direction == .sink ? b:nil
                if let source,let sink,let voltage=source.nominalVoltageV,
                   let minimum=sink.minimumVoltageV,let maximum=sink.maximumVoltageV,
                   voltage.isFinite,minimum.isFinite,maximum.isFinite,minimum<=maximum {
                    if !(minimum...maximum).contains(voltage){issue("voltage-mismatch",.invalid,[connection.id],"Source voltage is outside the declared load range")}
                    if source.evidenceID==nil || sink.evidenceID==nil{issue("rating-evidence-missing",.needsInput,[connection.id],"Electrical values require product evidence")}
                } else{issue("power-conditions-unverified",.needsInput,[connection.id],"Source and load voltage conditions are incomplete")}
            }
            if let segmentID=connection.segmentID {
                if let segment=segments[segmentID] {
                    if segment.medium != a.medium{issue("segment-medium-mismatch",.invalid,[connection.id,segmentID],"Segment and connected ports differ")}
                    if (segment.medium == .rs485 || segment.medium == .can) && segment.terminationEvidenceID==nil {
                        issue("termination-conditions-unverified",.needsInput,[segmentID],"Use source-specific topology, rate, cable and termination conditions")
                    }
                } else{issue("unknown-segment",.invalid,[connection.id,segmentID],"Segment is not in this plan")}
            }
            if connection.routeMM.count==1 || connection.routeMM.count>4096 || !connection.routeMM.allSatisfy(\.isFinite) {
                issue("invalid-cable-route",.invalid,[connection.id],"A cable route needs at least two finite points within budget")
            }
        }
        for port in ports {
            let count=counts[port.id,default:0]
            if port.required && count==0{issue("required-port-unconnected",.needsInput,[port.id],"Required port has no declared connection")}
            if let maximum=port.maximumConnections,count>maximum{issue("port-capacity-exceeded",.invalid,[port.id],"Too many connections")}
            if let loads=outgoing[port.id],!loads.isEmpty {
                if let limit=port.maximumCurrentA,loads.allSatisfy({$0.demandCurrentA != nil}) {
                    let demand=loads.compactMap(\.demandCurrentA).reduce(0,+)
                    if !demand.isFinite || demand>limit{issue("supply-current-exceeded",.invalid,[port.id],"Declared load current exceeds the source rating")}
                } else if port.medium == .acPower || port.medium == .dcPower {
                    issue("current-budget-unverified",.needsInput,[port.id],"Supply or load current is missing")
                }
            }
        }
        for scene in plan.scenes {
            if scene.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ||
               scene.triggerDescription.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ||
               scene.actionDescription.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                issue("scene-description-missing",.needsInput,[scene.id],"Scene name, trigger and planned action are required")
            }
            if scene.equipmentIDs.isEmpty{issue("scene-device-empty",.needsInput,[scene.id],"Scene plan needs at least one related device")}
        }
        for scene in plan.scenes where !scene.equipmentIDs.allSatisfy(deviceIDs.contains) {
            issue("scene-device-missing",.invalid,[scene.id],"Scene plan references an unknown device")
        }
        var seen:Set<String>=[]
        return .init(issues:issues.filter{seen.insert($0.id).inserted})
    }
}
