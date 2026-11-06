import SwiftUI
import FloeChemistryCore
#if os(iOS)
import UIKit
#endif

@MainActor struct NativeDrawingWorkbench:View {
    let session:NativeDrawingSession
    @State private var showElements = false
    @State private var showDetails = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    var body:some View {
        VStack(spacing:0) {
            ScrollView(.horizontal) {
                HStack(spacing:4) {
                    command(chemistryText("Undo", "撤销"),"arrow.uturn.backward",disabled:!session.canUndo) {session.undo()}.keyboardShortcut("z",modifiers:.command)
                    command(chemistryText("Redo", "重做"),"arrow.uturn.forward",disabled:!session.canRedo) {session.redo()}.keyboardShortcut("z",modifiers:[.command,.shift])
                    Divider().frame(height:24)
                    Menu {
                        ForEach(ChemicalBondStyle.allCases,id:\.self) { style in Button(style.title){session.bondStyle = style;session.choose(.bond)} }
                    } label: {Label(session.bondStyle.title,systemImage:"line.diagonal").frame(minHeight:44)}.padding(.horizontal,8)
                    Menu {
                        Button(chemistryText("Lasso selection", "套索选择")){session.rectangleSelection = false;session.choose(.select)}
                        Button(chemistryText("Rectangle selection", "矩形选择")){session.rectangleSelection = true;session.choose(.select)}
                        Button(chemistryText("Select all atoms", "选择全部原子")){session.selection = Set(session.document.atoms.map(\.id));session.choose(.select)}
                    } label:{Image(systemName:"selection.pin.in.out").frame(width:44,height:44)}.accessibilityLabel(chemistryText("Selection tools", "选择工具"))
                    command(chemistryText("Clean up layout", "整理布局"),"point.3.connected.trianglepath.dotted") {Task {await session.cleanLayout()}}
                    command(chemistryText("Fit drawing", "绘图适合窗口"),"arrow.up.left.and.arrow.down.right") {session.fitToken = UUID()}
                    #if os(iOS)
                    command(chemistryText("Copy drawing", "复制绘图"),"doc.on.doc") {if let text = try? session.document.encoded(){UIPasteboard.general.string = text}}
                    #endif
                    PasteButton(payloadType:String.self) { strings in if let text = strings.first {Task {await session.pasteDrawing(text)}} }
                        .labelStyle(.iconOnly).help(chemistryText("Paste a structure", "粘贴结构"))
                        .disabled(!session.loaded)
                    Menu {
                        #if os(iOS)
                        Toggle(chemistryText("Draw with finger", "手指绘图"),isOn:Binding(get:{session.drawWithFinger},set:{session.drawWithFinger = $0}))
                        #endif
                        Button(chemistryText("Clear drawing", "清空绘图"),role:.destructive){session.commit {$0 = try ChemicalDrawing2D()}}.disabled(!session.loaded)
                    } label:{Image(systemName:"ellipsis.circle").frame(width:44,height:44)}.accessibilityLabel(chemistryText("Drawing options", "绘图选项"))
                }.font(.subheadline).padding(.horizontal,8)
            }.scrollIndicators(.hidden)
            Divider()
            GeometryReader { geometry in
                let columns = geometry.size.height < 520 ? 2 : 1
                HStack(spacing:0) {
                    toolPalette(columns:columns)
                    Divider()
                    NativeChemicalCanvas(session:session)
                        .overlay {if !session.loaded {ProgressView(chemistryText("Opening structure…", "正在打开结构…"))}}
                    Divider()
                    elementPalette(columns:columns)
                }
            }
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing:4) {
                    Button {session.ringSize = 6;session.aromaticRing = true;session.choose(.ring)} label:{ZStack {RingOutline(sides:6).stroke(lineWidth:1.6);Circle().stroke(lineWidth:1.2).padding(6)}.frame(width:24,height:24).frame(width:44,height:44)}
                        .accessibilityLabel(chemistryText("Benzene template", "苯环模板"))
                    ForEach(3...8,id:\.self) {size in
                        Button {session.ringSize = size;session.aromaticRing = false;session.choose(.ring)} label:{RingOutline(sides:size).stroke(lineWidth:1.6).frame(width:24,height:24).frame(width:44,height:44)}.accessibilityLabel(chemistryText("Ring", "环")+" \(size)")
                    }
                    Divider().frame(height:24)
                    Text(session.tool == .ring ? (session.aromaticRing ? chemistryText("Benzene", "苯环") : chemistryText("Ring", "环")+" \(session.ringSize)") : session.tool.title).font(.caption).foregroundStyle(.secondary).padding(.horizontal,8)
                }.padding(.horizontal,8)
            }.scrollIndicators(.hidden)
            Divider()
            HStack {
                Text("\(session.document.atoms.count) " + chemistryText("atoms", "个原子") + " · \(session.document.bonds.count) " + chemistryText("bonds", "条键"))
                    .accessibilityIdentifier("chemistry.drawingCounts")
                if !session.selection.isEmpty {Text("\(session.selection.count) " + chemistryText("selected", "已选"))}
                Spacer()
                if session.warning != nil {Button {showDetails = true} label:{Label(chemistryText("Details", "详情"),systemImage:"exclamationmark.triangle")}}
                #if os(iOS)
                Button(session.drawWithFinger ? chemistryText("Finger draws", "手指绘图") : chemistryText("Finger pans", "手指平移")) {session.drawWithFinger.toggle()}
                    .buttonStyle(.plain).foregroundStyle(.secondary).frame(minHeight:44)
                #endif
            }.font(.caption).padding(.horizontal,12).frame(minHeight:44)
        }
        .sheet(isPresented:$showElements) {PeriodicElementPicker {symbol in session.element = symbol;session.choose(.atom)}}
        .sheet(isPresented:$showDetails) {NavigationStack {ScrollView {Text(session.warning ?? "").textSelection(.enabled).padding()}.navigationTitle(chemistryText("Drawing details", "绘图详情")).toolbar {Button(chemistryText("Done", "完成")){showDetails = false}}}}
    }
    private func command(_ title:String,_ symbol:String,disabled:Bool = false,action:@escaping () -> Void) -> some View {
        Button(action:action){Image(systemName:symbol).frame(width:44,height:44)}.disabled(disabled || !session.loaded).accessibilityLabel(title).help(title)
    }
    private func toolButton(_ tool:ChemicalDrawTool) -> some View {
        Button {session.choose(tool)} label:{Image(systemName:tool.symbol).frame(width:44,height:44).background(session.tool == tool ? Color.accentColor.opacity(0.15) : .clear,in:RoundedRectangle(cornerRadius:8))}
            .buttonStyle(.plain).foregroundStyle(session.tool == tool ? Color.accentColor : .primary).accessibilityLabel(tool.title).help(tool.title)
    }
    private func toolPalette(columns:Int) -> some View {
        VStack(spacing:0) {
            ScrollView(.vertical) {
                LazyVGrid(columns:Array(repeating:GridItem(.fixed(44),spacing:2),count:columns),spacing:2) {
                    ForEach([ChemicalDrawTool.bond,.atom,.select,.erase,.chargePlus,.chargeMinus,.arrow,.reactionPlus,.text],id:\.self) {tool in toolButton(tool)}
                }.padding(4)
            }.scrollIndicatorsFlash(onAppear:true)
            Divider();toolButton(.pan).padding(.vertical,2)
        }.frame(width:CGFloat(columns)*44+CGFloat(columns-1)*2+8)
    }
    private func elementPalette(columns:Int) -> some View {
        VStack(spacing:0) {
            ScrollView(.vertical) {
                LazyVGrid(columns:Array(repeating:GridItem(.fixed(44),spacing:2),count:columns),spacing:2) {
                    ForEach(["H","C","N","O","S","P","F","Cl","Br","I"],id:\.self) {symbol in
                        Button {session.element = symbol;session.choose(.atom)} label:{Text(symbol).font(.system(.body,design:.rounded).weight(.semibold)).frame(width:44,height:44).foregroundStyle(Color(cgColor:ChemicalCanvasRenderer.atomColor(symbol,dark:colorScheme == .dark,highContrast:contrast == .increased))).background(session.element == symbol && session.tool == .atom ? Color.accentColor.opacity(0.15) : .clear,in:RoundedRectangle(cornerRadius:8))}
                            .buttonStyle(.plain).accessibilityLabel(chemistryText("Element", "元素")+" "+symbol)
                    }
                }.padding(4)
            }.scrollIndicatorsFlash(onAppear:true)
            Divider()
            Button {showElements = true} label:{Image(systemName:"tablecells").frame(width:44,height:44)}.padding(.vertical,2).accessibilityLabel(chemistryText("Periodic table", "元素周期表"))
        }.frame(width:CGFloat(columns)*44+CGFloat(columns-1)*2+8)
    }
}
private struct RingOutline:Shape {
    let sides:Int
    func path(in rect:CGRect) -> Path {Path {path in
        for i in 0..<sides {let angle = Double(i)*2 * .pi/Double(sides) - .pi/2;let p = CGPoint(x:rect.midX+cos(angle)*rect.width*0.45,y:rect.midY+sin(angle)*rect.height*0.45);if i == 0 {path.move(to:p)}else{path.addLine(to:p)}};path.closeSubpath()
    }}
}
@MainActor private struct PeriodicElementPicker:View {
    let choose:(String) -> Void
    @Environment(\.dismiss) private var dismiss
    private let symbols = "H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr Rf Db Sg Bh Hs Mt Ds Rg Cn Nh Fl Mc Lv Ts Og".split(separator:" ").map(String.init)
    private var rows:[[Int]] {[
        [1]+Array(repeating:0,count:16)+[2],
        [3,4]+Array(repeating:0,count:10)+Array(5...10),
        [11,12]+Array(repeating:0,count:10)+Array(13...18),
        Array(19...36),Array(37...54),[55,56,57]+Array(72...86),[87,88,89]+Array(104...118),
        [0,0]+Array(58...71)+[0,0],[0,0]+Array(90...103)+[0,0]
    ]}
    var body:some View {
        NavigationStack {
            ScrollView([.horizontal,.vertical]) {
                Grid(horizontalSpacing:3,verticalSpacing:3) {
                    GridRow {ForEach(1...18,id:\.self){Text(String($0)).font(.caption).frame(width:44)}}
                    ForEach(Array(rows.enumerated()),id:\.offset) {_,row in
                        GridRow {ForEach(Array(row.enumerated()),id:\.offset){_,z in
                            if z == 0 {Color.clear.frame(width:44,height:48)}
                            else {Button {choose(symbols[z-1]);dismiss()} label:{VStack(spacing:1){Text(String(z)).font(.caption2);Text(symbols[z-1]).font(.body.weight(.semibold))}.frame(width:44,height:48)}.buttonStyle(.bordered).accessibilityLabel("\(symbols[z-1]), \(z)")}
                        }}
                    }
                }.padding()
            }
            .navigationTitle(chemistryText("Periodic table", "元素周期表"))
            .toolbar {Button(chemistryText("Done", "完成")){dismiss()}}
        }.presentationDetents([.large])
    }
}
