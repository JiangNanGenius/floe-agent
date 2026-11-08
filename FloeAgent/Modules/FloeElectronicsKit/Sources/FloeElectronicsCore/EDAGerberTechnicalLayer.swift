// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Explicit export selection; these layer IDs are not new document records.
public enum EDAGerberTechnicalLayer:String,Codable,CaseIterable,Sendable {
    case frontMask="F.Mask",backMask="B.Mask",frontPaste="F.Paste",backPaste="B.Paste"
    case frontSilk="F.SilkS",backSilk="B.SilkS",frontAssembly="F.Fab",backAssembly="B.Fab"
    public static var maskPasteSilk:[Self]{[.frontMask,.backMask,.frontPaste,.backPaste,.frontSilk,.backSilk]}
    public static var assemblyOutlines:[Self]{[.frontAssembly,.backAssembly]}
    var kind:EDALayerKind{switch self{case .frontMask,.backMask:.mask;case .frontPaste,.backPaste:.paste;case .frontSilk,.backSilk:.silkscreen;case .frontAssembly,.backAssembly:.fabrication}}
    var side:String{rawValue.hasPrefix("F.") ? "Top":"Bot"}
    var fileName:String{let role=switch kind{case .mask:"Mask";case .paste:"Paste";case .silkscreen:"Legend";default:"AssemblyOutline"};return role+"-"+side+".gbr"}
    var function:String{let role=switch kind{case .mask:"Soldermask";case .paste:"Paste";case .silkscreen:"Legend";default:"AssemblyDrawing"};return role+","+side}
    var polarity:String{kind == .mask ? "Negative":"Positive"}
}
