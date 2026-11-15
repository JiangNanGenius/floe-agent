// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum SystemPortMedium: String, Codable, Sendable, CaseIterable {
    case acPower,dcPower,rs485,can,ethernet,dryContact,analogDimming,dali,wireless
}
public enum SystemTerminalRole: String, Codable, Sendable {
    case line,neutral,protectiveEarth,positive,negative,signalA,signalB,canH,canL
    case signalReference,shield,common,normallyOpen,normallyClosed,data,unspecified
}
public enum SystemPortDirection: String, Codable, Sendable { case source,sink,bidirectional,passive }
public struct SystemPointMM: Codable, Equatable, Hashable, Sendable {
    public var x:Double;public var y:Double;public var z:Double
    public init(_ x:Double,_ y:Double,_ z:Double) {self.x=x;self.y=y;self.z=z}
    public var isFinite:Bool {x.isFinite && y.isFinite && z.isFinite}
}
public struct SmartHomePort: Codable, Equatable, Sendable, Identifiable {
    public var id:UUID
    public var label:String
    public var medium:SystemPortMedium
    public var terminal:SystemTerminalRole
    public var direction:SystemPortDirection
    public var protocolName:String?
    public var compatibilityProfile:String?
    public var nominalVoltageV:Double?
    public var minimumVoltageV:Double?
    public var maximumVoltageV:Double?
    public var maximumCurrentA:Double?
    public var demandCurrentA:Double?
    public var maximumConnections:Int?
    public var required:Bool
    public var evidenceID:String?
    public init(id:UUID=UUID(),label:String,medium:SystemPortMedium,terminal:SystemTerminalRole = .unspecified,
                direction:SystemPortDirection = .bidirectional,protocolName:String?=nil,compatibilityProfile:String?=nil,
                nominalVoltageV:Double?=nil,minimumVoltageV:Double?=nil,maximumVoltageV:Double?=nil,
                maximumCurrentA:Double?=nil,demandCurrentA:Double?=nil,maximumConnections:Int?=nil,
                required:Bool=true,evidenceID:String?=nil) {
        self.id=id;self.label=label;self.medium=medium;self.terminal=terminal;self.direction=direction
        self.protocolName=protocolName;self.compatibilityProfile=compatibilityProfile;self.nominalVoltageV=nominalVoltageV
        self.minimumVoltageV=minimumVoltageV;self.maximumVoltageV=maximumVoltageV;self.maximumCurrentA=maximumCurrentA
        self.demandCurrentA=demandCurrentA;self.maximumConnections=maximumConnections;self.required=required;self.evidenceID=evidenceID
    }
}
public struct SmartHomeEquipment: Codable, Equatable, Sendable, Identifiable {
    public var id:UUID
    public var name:String
    public var productReference:String
    public var assetVersion:String
    public var roomID:UUID?
    public var positionMM:SystemPointMM?
    public var ports:[SmartHomePort]
    public var channelCount:Int?
    public var requiresNeutral:Bool?
    public var gatewayRequirement:String?
    public var providedGatewayProfile:String?
    public var isSpare:Bool
    public init(id:UUID=UUID(),name:String,productReference:String,assetVersion:String="1",roomID:UUID?=nil,
                positionMM:SystemPointMM?=nil,ports:[SmartHomePort],channelCount:Int?=nil,
                requiresNeutral:Bool?=nil,gatewayRequirement:String?=nil,providedGatewayProfile:String?=nil,isSpare:Bool=false) {
        self.id=id;self.name=name;self.productReference=productReference;self.assetVersion=assetVersion
        self.roomID=roomID;self.positionMM=positionMM;self.ports=ports;self.channelCount=channelCount
        self.requiresNeutral=requiresNeutral;self.gatewayRequirement=gatewayRequirement
        self.providedGatewayProfile=providedGatewayProfile;self.isSpare=isSpare
    }
}
public struct SmartHomeConnection: Codable, Equatable, Sendable, Identifiable {
    public var id:UUID
    public var firstPortID:UUID
    public var secondPortID:UUID
    public var segmentID:UUID?
    public var label:String
    public var cableProduct:String?
    public var routeMM:[SystemPointMM]
    public init(id:UUID=UUID(),firstPortID:UUID,secondPortID:UUID,segmentID:UUID?=nil,
                label:String="",cableProduct:String?=nil,routeMM:[SystemPointMM]=[]) {
        self.id=id;self.firstPortID=firstPortID;self.secondPortID=secondPortID;self.segmentID=segmentID
        self.label=label;self.cableProduct=cableProduct;self.routeMM=routeMM
    }
    public var routedLengthM:Double? {
        guard routeMM.count>=2,routeMM.allSatisfy(\.isFinite) else{return nil}
        let value=zip(routeMM,routeMM.dropFirst()).reduce(0.0){sum,pair in
            let x=pair.1.x-pair.0.x,y=pair.1.y-pair.0.y,z=pair.1.z-pair.0.z
            return sum+sqrt(x*x+y*y+z*z)/1000
        }
        return value.isFinite ? value:nil
    }
}
public struct SmartHomeSegment: Codable, Equatable, Sendable, Identifiable {
    public var id:UUID
    public var name:String
    public var medium:SystemPortMedium
    public var protocolName:String?
    public var terminationEvidenceID:String?
    public init(id:UUID=UUID(),name:String,medium:SystemPortMedium,protocolName:String?=nil,terminationEvidenceID:String?=nil) {
        self.id=id;self.name=name;self.medium=medium;self.protocolName=protocolName;self.terminationEvidenceID=terminationEvidenceID
    }
}
public struct SmartHomeScenePlan: Codable, Equatable, Sendable, Identifiable {
    public var id:UUID
    public var name:String
    public var triggerDescription:String
    public var conditionDescription:String
    public var actionDescription:String
    public var equipmentIDs:[UUID]
    public init(id:UUID=UUID(),name:String,triggerDescription:String,conditionDescription:String="",actionDescription:String,equipmentIDs:[UUID]) {
        self.id=id;self.name=name;self.triggerDescription=triggerDescription;self.conditionDescription=conditionDescription
        self.actionDescription=actionDescription;self.equipmentIDs=equipmentIDs
    }
}
public struct SmartHomePlan: Codable, Equatable, Sendable {
    public var id:UUID
    public var projectID:UUID
    public var revision:Int
    public var roomIDs:[UUID]
    public var equipment:[SmartHomeEquipment]
    public var connections:[SmartHomeConnection]
    public var segments:[SmartHomeSegment]
    public var scenes:[SmartHomeScenePlan]
    public init(id:UUID=UUID(),projectID:UUID,revision:Int=0,roomIDs:[UUID]=[],equipment:[SmartHomeEquipment]=[],
                connections:[SmartHomeConnection]=[],segments:[SmartHomeSegment]=[],scenes:[SmartHomeScenePlan]=[]) {
        self.id=id;self.projectID=projectID;self.revision=revision;self.roomIDs=roomIDs;self.equipment=equipment
        self.connections=connections;self.segments=segments;self.scenes=scenes
    }
    public func encoded() throws -> Data {
        guard revision>=0,equipment.count<=4096,connections.count<=16384 else{throw SmartHomePlanError.invalidSnapshot}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(self)
    }
    public static func reopen(_ data:Data) throws -> Self {
        guard data.count<=16*1024*1024 else{throw SmartHomePlanError.invalidSnapshot}
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.revision>=0,value.equipment.count<=4096,value.connections.count<=16384 else{throw SmartHomePlanError.invalidSnapshot}
        return value
    }
    public func renamedEquipment(_ id:UUID,to name:String,expectedRevision:Int) throws -> Self {
        guard expectedRevision==revision else{throw SmartHomePlanError.staleRevision}
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.utf8.count<=4096,
              let index=equipment.firstIndex(where:{$0.id==id}),revision<Int.max else{throw SmartHomePlanError.invalidSnapshot}
        var copy=self;copy.equipment[index].name=name;copy.revision+=1;return copy
    }
}
public enum SmartHomePlanError: Error, Equatable, Sendable {case staleRevision,invalidSnapshot}
