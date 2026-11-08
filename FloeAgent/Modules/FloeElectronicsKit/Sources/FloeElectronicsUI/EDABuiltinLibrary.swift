// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeElectronicsCore

/// Self-authored generic geometry. These are not imported vendor libraries.
public enum EDABuiltinLibrary {
    public static func makeProject(id: UUID = UUID(), title: String) -> EDAProject {
        var project = EDAProject(id: id, title: title)
        project.symbols = makeSymbols(); project.footprints = makeFootprints()
        return project
    }
    public static func nextReference(_ prefix: String, in project: EDAProject) -> String {
        let used = Set(project.components.map(\.reference))
        var number = 1
        while used.contains(prefix + String(number)) { number += 1 }
        return prefix + String(number)
    }
    public static func makeSymbols() -> [EDASymbolDefinition] {
        let pair = [EDAPin(number: "1", position: .init(-5.08, 0)), EDAPin(number: "2", position: .init(5.08, 0))]
        let leads: [EDAGraphic] = [.line(.init(-5.08,0), .init(-2.54,0), width:0.2), .line(.init(2.54,0), .init(5.08,0), width:0.2)]
        let resistor: EDASymbolDefinition = .init(name:"Resistor",referencePrefix:"R",pins:pair,graphics:leads + [.rectangle(.init(-2.54,-1.27),.init(2.54,1.27),width:0.25)])
        let capacitor: EDASymbolDefinition = .init(name:"Capacitor",referencePrefix:"C",pins:pair,graphics:[.line(.init(-5.08,0),.init(-0.8,0),width:0.2),.line(.init(0.8,0),.init(5.08,0),width:0.2),.line(.init(-0.8,-2.54),.init(-0.8,2.54),width:0.3),.line(.init(0.8,-2.54),.init(0.8,2.54),width:0.3)])
        let diode: EDASymbolDefinition = .init(name:"Diode",referencePrefix:"D",pins:pair,graphics:leads + [.line(.init(-2.54,-2),.init(-2.54,2),width:0.2),.line(.init(-2.54,2),.init(2.54,0),width:0.2),.line(.init(2.54,0),.init(-2.54,-2),width:0.2),.line(.init(2.54,-2),.init(2.54,2),width:0.3)])
        let transistor: EDASymbolDefinition = .init(name:"Transistor",referencePrefix:"Q",pins:[.init(number:"1",name:"B",position:.init(-5.08,0),type:.input),.init(number:"2",name:"C",position:.init(2.54,5.08)),.init(number:"3",name:"E",position:.init(2.54,-5.08))],graphics:[.circle(center:.zero,radius:3.8,width:0.2),.line(.init(-5.08,0),.zero,width:0.2),.line(.zero,.init(2.54,5.08),width:0.2),.line(.zero,.init(2.54,-5.08),width:0.2)])
        let connector: EDASymbolDefinition = .init(name:"Connector 1x02",referencePrefix:"J",pins:[.init(number:"1",position:.init(-5.08,1.27)),.init(number:"2",position:.init(-5.08,-1.27))],graphics:[.rectangle(.init(-2.54,-3.81),.init(2.54,3.81),width:0.2),.line(.init(-5.08,1.27),.init(0,1.27),width:0.2),.line(.init(-5.08,-1.27),.init(0,-1.27),width:0.2)])
        var icPins: [EDAPin] = []
        for i in 0..<8 {
            let x: Double = i<4 ? -7.62:7.62
            let y = Double(i<4 ? 3-i:i-4)*2.54-3.81
            icPins.append(EDAPin(number:String(i+1),position:EDAPoint(x,y)))
        }
        let ic: EDASymbolDefinition = .init(name:"IC 8 pins",referencePrefix:"U",pins:icPins,graphics:[.rectangle(.init(-5.08,-6.35),.init(5.08,6.35),width:0.2)])
        let ground: EDASymbolDefinition = .init(name:"Ground",referencePrefix:"GND",pins:[.init(number:"1",name:"GND",position:.zero,type:.powerInput)],graphics:[.line(.zero,.init(0,-2.54),width:0.2),.line(.init(-2.54,-2.54),.init(2.54,-2.54),width:0.3)])
        let power: EDASymbolDefinition = .init(name:"Power",referencePrefix:"PWR",pins:[.init(number:"1",name:"VCC",position:.zero,type:.powerOutput)],graphics:[.line(.zero,.init(0,2.54),width:0.2),.line(.init(-1.27,1.27),.init(0,2.54),width:0.2),.line(.init(0,2.54),.init(1.27,1.27),width:0.2)])
        return [resistor, capacitor, diode, transistor, connector, ic, ground, power]
    }
    public static func makeFootprints() -> [EDAFootprintDefinition] {
        func passive(_ name:String,_ spacing:Double,_ size:EDAPoint)->EDAFootprintDefinition {
            .init(name:name,pads:[.init(number:"1",position:.init(-spacing/2,0),size:size,shape:.rectangle),.init(number:"2",position:.init(spacing/2,0),size:size,shape:.rectangle)],graphics:[.rectangle(.init(-spacing/2-1,-1),.init(spacing/2+1,1),width:0.15)])
        }
        let small = passive("0603",1.6,.init(0.9,0.95))
        let medium = passive("0805",2.0,.init(1.2,1.4))
        let transistor = EDAFootprintDefinition(name:"SOT-23",pads:[
            EDAPad(number:"1",position:.init(-0.95,-1.1),size:.init(0.7,1),shape:.rectangle),
            EDAPad(number:"2",position:.init(0.95,-1.1),size:.init(0.7,1),shape:.rectangle),
            EDAPad(number:"3",position:.init(0,1.1),size:.init(0.7,1),shape:.rectangle)])
        var dipPads: [EDAPad] = []
        for i in 0..<8 {
            let x: Double = i<4 ? -3.81:3.81
            let y = Double(i<4 ? i:7-i)*2.54
            dipPads.append(EDAPad(number:String(i+1),position:EDAPoint(x,y),size:.init(1.8,1.8),drill:0.8,layers:["F.Cu","B.Cu"]))
        }
        let dip = EDAFootprintDefinition(name:"DIP-8",pads:dipPads,graphics:[.rectangle(.init(-2.54,-1.27),.init(2.54,8.89),width:0.2)])
        let header = EDAFootprintDefinition(name:"Header 1x02",pads:[
            EDAPad(number:"1",position:.zero,size:.init(1.8,1.8),drill:1,layers:["F.Cu","B.Cu"]),
            EDAPad(number:"2",position:.init(0,2.54),size:.init(1.8,1.8),drill:1,layers:["F.Cu","B.Cu"])])
        return [small,medium,transistor,dip,header]
    }
}
