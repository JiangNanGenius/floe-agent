// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Lumped rotational drive, SI units. This is an explicit-input research model,
/// not a fitted servo controller, bearing model, or machine feedback signal.
public struct SpindleDriveConfiguration:Codable,Equatable,Sendable {
    public var inertiaKgM2:Double
    public var maxRPM:Double
    public var motoringTorqueNM:Double
    public var brakingTorqueNM:Double
    public var motoringPowerKW:Double
    public var brakingPowerKW:Double
    public var dragTorqueNM:Double
    public var viscousNMPerRadPerSecond:Double
    public var loadTorqueNM:Double
    public var motorEfficiency:Double
    public var regenerationEfficiency:Double
    public init(inertiaKgM2:Double,maxRPM:Double,motoringTorqueNM:Double,brakingTorqueNM:Double,
                motoringPowerKW:Double,brakingPowerKW:Double,dragTorqueNM:Double = 0,
                viscousNMPerRadPerSecond:Double = 0,loadTorqueNM:Double = 0,
                motorEfficiency:Double = 1,regenerationEfficiency:Double = 0) {
        self.inertiaKgM2 = inertiaKgM2;self.maxRPM = maxRPM;self.motoringTorqueNM = motoringTorqueNM
        self.brakingTorqueNM = brakingTorqueNM;self.motoringPowerKW = motoringPowerKW;self.brakingPowerKW = brakingPowerKW
        self.dragTorqueNM = dragTorqueNM;self.viscousNMPerRadPerSecond = viscousNMPerRadPerSecond;self.loadTorqueNM = loadTorqueNM
        self.motorEfficiency = motorEfficiency;self.regenerationEfficiency = regenerationEfficiency
    }
    public func validate() throws {
        guard inertiaKgM2.isFinite && (1e-9...1e6).contains(inertiaKgM2),maxRPM.isFinite && (1...1e7).contains(maxRPM),
              [motoringTorqueNM,brakingTorqueNM].allSatisfy({ $0.isFinite && (0...1e7).contains($0) }),
              [motoringPowerKW,brakingPowerKW].allSatisfy({ $0.isFinite && (0...1e7).contains($0) }),
              [dragTorqueNM,viscousNMPerRadPerSecond,loadTorqueNM].allSatisfy({ $0.isFinite && (0...1e7).contains($0) }),
              motorEfficiency.isFinite && motorEfficiency > 0 && motorEfficiency <= 1,
              regenerationEfficiency.isFinite && (0...1).contains(regenerationEfficiency) else {
            throw ManufacturingError.invalid("spindle drive configuration units/limits")
        }
    }
}

public struct SpindleDriveRequest:Codable,Equatable,Sendable {
    public var configuration:SpindleDriveConfiguration
    public var initialRPM:Double
    public var targetRPM:Double
    public var initialPhaseDegrees = 0.0
    public var maxDurationSeconds = 10.0
    public var stepSeconds = 0.001
    public var maxSteps = 200_000
    public var maxSamples = 10_000
    public var sampleEverySteps = 10
    public init(configuration:SpindleDriveConfiguration,initialRPM:Double,targetRPM:Double) {
        self.configuration = configuration;self.initialRPM = initialRPM;self.targetRPM = targetRPM
    }
    public func validate() throws {
        try configuration.validate()
        guard [initialRPM,targetRPM].allSatisfy({ $0.isFinite && abs($0) <= configuration.maxRPM }),
              initialPhaseDegrees.isFinite && abs(initialPhaseDegrees) <= 1e12,
              maxDurationSeconds.isFinite && (0.00001...3600).contains(maxDurationSeconds),
              stepSeconds.isFinite && (0.00001...0.05).contains(stepSeconds),
              (1...500_000).contains(maxSteps),(2...50_000).contains(maxSamples),(1...1000).contains(sampleEverySteps) else {
            throw ManufacturingError.invalid("spindle drive request speed/time/sample budget")
        }
    }
    public static func demonstration()->Self {
        .init(configuration:.init(inertiaKgM2:0.02,maxRPM:6000,motoringTorqueNM:8,brakingTorqueNM:10,
            motoringPowerKW:3,brakingPowerKW:2,dragTorqueNM:0.15,viscousNMPerRadPerSecond:0.001,loadTorqueNM:0.4,
            motorEfficiency:0.9,regenerationEfficiency:0.7),initialRPM:0,targetRPM:1500)
    }
}

public struct SpindleDriveResult:Codable,Equatable,Sendable {
    public enum Termination:String,Codable,Sendable { case targetReached,timeLimit,stepLimit }
    public struct Sample:Codable,Equatable,Sendable {
        public var seconds:Double
        public var rpm:Double
        public var unwrappedPhaseDegrees:Double
        public var driveTorqueNM:Double
        public var mechanicalPowerKW:Double
    }
    public var inputSHA256:String
    public var termination:Termination
    public var samples:[Sample]
    public var steps:Int
    public var elapsedSeconds:Double
    public var finalRPM:Double
    public var finalPhaseDegrees:Double
    public var torqueLimited:Bool
    public var powerLimited:Bool
    public var kineticEnergyChangeJ:Double
    public var driveMechanicalWorkJ:Double
    public var resistanceWorkJ:Double
    public var electricalInputJ:Double
    public var regeneratedElectricalJ:Double
    public var driveConversionLossJ:Double
    public var energyBalanceResidualJ:Double
    public var method:String
    public var warnings:[String]
    public func validate(for request:SpindleDriveRequest) throws {
        try request.validate()
        guard inputSHA256 == (try ResearchArchive.digest(request)),!samples.isEmpty,samples.count <= request.maxSamples,
              samples.first?.seconds == 0,steps >= 0 && steps <= request.maxSteps,
              samples.first?.rpm == request.initialRPM,samples.first?.unwrappedPhaseDegrees == request.initialPhaseDegrees,
              samples.last?.rpm == finalRPM,samples.last?.seconds == elapsedSeconds,samples.last?.unwrappedPhaseDegrees == finalPhaseDegrees,
              [elapsedSeconds,finalRPM,finalPhaseDegrees,kineticEnergyChangeJ,driveMechanicalWorkJ,resistanceWorkJ,
               electricalInputJ,regeneratedElectricalJ,driveConversionLossJ,energyBalanceResidualJ].allSatisfy(\.isFinite),
              elapsedSeconds >= 0 && elapsedSeconds <= request.maxDurationSeconds+1e-8,
              abs(finalRPM) <= request.configuration.maxRPM+1e-6,
              [resistanceWorkJ,electricalInputJ,regeneratedElectricalJ,driveConversionLossJ].allSatisfy({ $0 >= -1e-7 }),
              samples.allSatisfy({ [$0.seconds,$0.rpm,$0.unwrappedPhaseDegrees,$0.driveTorqueNM,$0.mechanicalPowerKW].allSatisfy(\.isFinite) }),
              zip(samples,samples.dropFirst()).allSatisfy({ $0.seconds < $1.seconds }),
              termination != .targetReached || abs(finalRPM-request.targetRPM) <= 1e-6 else { throw ManufacturingError.archive("spindle drive source/result contract") }
    }
}

public enum SpindleDriveSolver {
    public static func solve(_ request:SpindleDriveRequest,control:ComputationControl = .init()) throws -> SpindleDriveResult {
        try request.validate();try control.check()
        let c = request.configuration,k = Double.pi/30,target = request.targetRPM*k
        var omega = request.initialRPM*k,phaseDegrees = request.initialPhaseDegrees,t = 0.0,steps = 0
        var motorJ = 0.0,regenJ = 0.0,conversionJ = 0.0,workJ = 0.0,resistanceJ = 0.0
        var torqueLimited = false,powerLimited = false
        var samples:[SpindleDriveResult.Sample] = [.init(seconds:0,rpm:request.initialRPM,unwrappedPhaseDegrees:request.initialPhaseDegrees,driveTorqueNM:0,mechanicalPowerKW:0)]
        let initialK = 0.5*c.inertiaKgM2*omega*omega
        func sign(_ x:Double)->Double { x < 0 ? -1 : 1 }
        func forces(_ w:Double,direction desired:Double)->(drive:Double,resistance:Double,powerLimited:Bool) {
            let rotation = abs(w)>1e-12 ? sign(w) : desired
            let braking = w*desired < 0,torque = braking ? c.brakingTorqueNM : c.motoringTorqueNM
            let power = (braking ? c.brakingPowerKW : c.motoringPowerKW)*1000
            let byPower = abs(w)>1e-12 ? power/abs(w) : (power>0 ? torque : 0)
            let drive = desired*min(torque,byPower)
            var resistance = rotation*(c.dragTorqueNM+c.loadTorqueNM)+c.viscousNMPerRadPerSecond*w
            // Opposing load/friction cannot spontaneously rotate a stopped shaft.
            if abs(w)<1e-12 && abs(drive) <= abs(resistance) { resistance = drive }
            return (drive,resistance,byPower < torque)
        }
        var lastTorque = 0.0,lastPower = 0.0
        while abs(omega-target)>1e-9 && t<request.maxDurationSeconds && steps<request.maxSteps {
            try control.check()
            var dt = min(request.stepSeconds,request.maxDurationSeconds-t)
            // The controller decision is held through one integration step.
            // Re-evaluating its sign at the RK midpoint can command a spurious
            // braking pulse when the predictor crosses the target.
            let desired = sign(target-omega),first = forces(omega,direction:desired),a0 = (first.drive-first.resistance)/c.inertiaKgM2
            let midpoint = omega+0.5*dt*a0,mid = forces(midpoint,direction:desired)
            var acceleration = (mid.drive-mid.resistance)/c.inertiaKgM2
            if abs(omega)<1e-12 && acceleration*(target-omega)<0 { acceleration = 0 }
            var next = omega+dt*acceleration
            // Split sign changes at zero, then re-evaluate resistance on the
            // next step; do not apply the old drag direction through reversal.
            if omega*next<0 { dt *= abs(omega/(next-omega));next = 0 }
            if (target-omega)*(target-next)<=0 && next != omega {
                dt *= (target-omega)/(next-omega);next = target
            }
            guard dt.isFinite && dt>0,next.isFinite else { throw ManufacturingError.native("spindle integration numeric range") }
            let average = (omega+next)/2,force = forces(average,direction:desired)
            let resistance = force.resistance,drive = c.inertiaKgM2*(next-omega)/dt+resistance
            let mechanical = drive*average*dt,loss = resistance*average*dt
            guard [drive,mechanical,loss].allSatisfy(\.isFinite),loss >= -1e-7 else { throw ManufacturingError.native("spindle energy numeric range") }
            phaseDegrees += average*dt*180/Double.pi;workJ += mechanical;resistanceJ += max(0,loss)
            if mechanical >= 0 { motorJ += mechanical/c.motorEfficiency;conversionJ += mechanical*(1/c.motorEfficiency-1) }
            else { regenJ += -mechanical*c.regenerationEfficiency;conversionJ += -mechanical*(1-c.regenerationEfficiency) }
            torqueLimited = torqueLimited || (!force.powerLimited && abs(omega-target)>1e-9)
            powerLimited = powerLimited || force.powerLimited
            t += dt;omega = next;steps += 1;lastTorque = drive;lastPower = drive*average/1000
            if steps%request.sampleEverySteps == 0 {
                guard samples.count < request.maxSamples-1 else { throw ManufacturingError.invalid("spindle drive retained sample budget") }
                samples.append(.init(seconds:t,rpm:omega/k,unwrappedPhaseDegrees:phaseDegrees,driveTorqueNM:drive,mechanicalPowerKW:lastPower))
            }
        }
        let final = SpindleDriveResult.Sample(seconds:t,rpm:steps == 0 ? request.initialRPM : omega/k,unwrappedPhaseDegrees:phaseDegrees,driveTorqueNM:lastTorque,mechanicalPowerKW:lastPower)
        if samples.last?.seconds == t { samples[samples.count-1] = final }
        else { guard samples.count < request.maxSamples else { throw ManufacturingError.invalid("spindle drive retained sample budget") };samples.append(final) }
        let deltaK = 0.5*c.inertiaKgM2*omega*omega-initialK
        let result = SpindleDriveResult(inputSHA256:try ResearchArchive.digest(request),termination:abs(omega-target)<=1e-9 ? .targetReached : (steps>=request.maxSteps ? .stepLimit : .timeLimit),
            samples:samples,steps:steps,elapsedSeconds:t,finalRPM:final.rpm,finalPhaseDegrees:phaseDegrees,torqueLimited:torqueLimited,powerLimited:powerLimited,
            kineticEnergyChangeJ:deltaK,driveMechanicalWorkJ:workJ,resistanceWorkJ:resistanceJ,electricalInputJ:motorJ,regeneratedElectricalJ:regenJ,
            driveConversionLossJ:conversionJ,energyBalanceResidualJ:workJ-resistanceJ-deltaK,
            method:"bounded explicit-midpoint rotational model with zero/target events; trapezoidal phase and work integration",
            warnings:["Explicit-input lumped drive model; no measured servo, jaw mechanics, bearing/thermal model or hardware feedback.","Nominal cell replay is separate and is not retimed by this drive calculation.","Target reached means first arrival, not sustained speed-holding capability.","Fixed-step dynamics is an approximation; torque/power changes within a step require convergence study for precision work."])
        try result.validate(for:request);return result
    }
}
