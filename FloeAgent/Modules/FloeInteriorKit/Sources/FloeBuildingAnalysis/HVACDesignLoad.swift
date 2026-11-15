// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum HVACDesignMode: String, Codable, Sendable { case heating,cooling }
public struct HVACEnvelopeTerm: Codable, Equatable, Sendable {
    public var id: String
    public var areaM2: Double
    public var transmittanceWPerM2K: Double
    public var evidenceID: String
    public init(id:String,areaM2:Double,transmittanceWPerM2K:Double,evidenceID:String) {
        self.id=id;self.areaM2=areaM2;self.transmittanceWPerM2K=transmittanceWPerM2K;self.evidenceID=evidenceID
    }
}
public struct HVACDesignLoadRequest: Codable, Equatable, Sendable {
    public var roomID: String
    public var projectRevision: Int
    public var mode: HVACDesignMode
    public var indoorC: Double
    public var outdoorC: Double
    public var envelope: [HVACEnvelopeTerm]
    public var outdoorAirM3PerS: Double
    public var airDensityKgPerM3: Double
    public var airHeatCapacityJPerKgK: Double
    public var internalSensibleW: Double
    public var solarSensibleW: Double
    public var explicitLatentW: Double
    public var conditionsEvidenceID: String
    public init(roomID:String,projectRevision:Int,mode:HVACDesignMode,indoorC:Double,outdoorC:Double,
                envelope:[HVACEnvelopeTerm],outdoorAirM3PerS:Double,airDensityKgPerM3:Double,
                airHeatCapacityJPerKgK:Double,internalSensibleW:Double,solarSensibleW:Double,
                explicitLatentW:Double,conditionsEvidenceID:String) {
        self.roomID=roomID;self.projectRevision=projectRevision;self.mode=mode;self.indoorC=indoorC;self.outdoorC=outdoorC
        self.envelope=envelope;self.outdoorAirM3PerS=outdoorAirM3PerS;self.airDensityKgPerM3=airDensityKgPerM3
        self.airHeatCapacityJPerKgK=airHeatCapacityJPerKgK;self.internalSensibleW=internalSensibleW
        self.solarSensibleW=solarSensibleW;self.explicitLatentW=explicitLatentW;self.conditionsEvidenceID=conditionsEvidenceID
    }
}
public struct HVACDesignLoadResult: Codable, Equatable, Sendable {
    public var inputFingerprint: String
    public var roomID: String
    public var transmissionW: Double
    public var outdoorAirSensibleW: Double
    public var internalAndSolarW: Double
    public var latentW: Double
    public var totalW: Double
    public var method: String
    public var limitations: [String]
    public func isStale(for input:HVACDesignLoadRequest) throws -> Bool {
        inputFingerprint != (try BuildingAnalysisFingerprint.hash(input))
    }
}

/// An explicitly supplied-condition screening calculation, not dynamic HVAC
/// simulation, moisture/psychrometric sizing or complete equipment selection.
public enum HVACDesignLoadCalculator {
    public static func calculate(_ input:HVACDesignLoadRequest) throws -> HVACDesignLoadResult {
        let values=[input.indoorC,input.outdoorC,input.outdoorAirM3PerS,input.airDensityKgPerM3,
                    input.airHeatCapacityJPerKgK,input.internalSensibleW,input.solarSensibleW,input.explicitLatentW]
        guard !input.roomID.isEmpty,input.projectRevision>=0,!input.conditionsEvidenceID.isEmpty,
              values.allSatisfy(\.isFinite),(-100...100).contains(input.indoorC),(-100...100).contains(input.outdoorC),
              input.outdoorAirM3PerS>=0,input.airDensityKgPerM3>0,input.airHeatCapacityJPerKgK>0,
              input.internalSensibleW>=0,input.solarSensibleW>=0,input.explicitLatentW>=0,
              !input.envelope.isEmpty,input.envelope.count<=4096,
              Set(input.envelope.map(\.id)).count==input.envelope.count else {
            throw BuildingAnalysisError.invalidInput("HVAC conditions")
        }
        for term in input.envelope {
            guard !term.id.isEmpty,!term.evidenceID.isEmpty,term.areaM2.isFinite,term.areaM2>0,
                  term.transmittanceWPerM2K.isFinite,term.transmittanceWPerM2K>=0 else {
                throw BuildingAnalysisError.invalidInput("envelope term")
            }
        }
        let delta=max(0,input.mode == .heating ? input.indoorC-input.outdoorC:input.outdoorC-input.indoorC)
        let transmission=input.envelope.reduce(0){$0+$1.areaM2*$1.transmittanceWPerM2K*delta}
        let outdoor=input.outdoorAirM3PerS*input.airDensityKgPerM3*input.airHeatCapacityJPerKgK*delta
        let gains=input.internalSensibleW+input.solarSensibleW
        let sensible=input.mode == .cooling ? transmission+outdoor+gains:max(0,transmission+outdoor-gains)
        let total=sensible+input.explicitLatentW
        guard [transmission,outdoor,gains,total].allSatisfy(\.isFinite) else {
            throw BuildingAnalysisError.invalidInput("HVAC result overflow")
        }
        return .init(inputFingerprint:try BuildingAnalysisFingerprint.hash(input),roomID:input.roomID,
            transmissionW:transmission,outdoorAirSensibleW:outdoor,internalAndSolarW:gains,
            latentW:input.explicitLatentW,totalW:total,method:"supplied-condition-steady-screen-v1",
            limitations:["no dynamic schedules or thermal storage","no calculated humidity/latent model","no network pressure or equipment sizing","no regional compliance assertion"])
    }
}
