// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics

public struct LaTeXApplePDFNavigationReceipt: Codable, Sendable {
    public let metadataKeys: [String]
    public let namedDestinationCount: Int
    public let outlineCount: Int
    public let linkAnnotationCount: Int
    public let emittedVersion: String
    public let compatibilityNotes: [String]
}

// Pure data only. This parser never interprets PDF content streams, PS, JS,
// executable actions or external resources. It reads special operands and the
// small dictionaries/classic xref of THIS renderer's own unpublished CG PDF.
indirect enum NativePDFValue: Equatable {
    case number(String), name(String), string(Data), array([NativePDFValue])
    case dictionary([String: NativePDFValue]), reference(Int, Int), atom(String), null
    var int: Int? { if case .number(let n) = self { Int(n) } else { nil } }
    var real: Double? { if case .number(let n) = self { Double(n) } else { nil } }
    var name: String? { if case .name(let n) = self { n } else { nil } }
    var array: [Self]? { if case .array(let a) = self { a } else { nil } }
    var dictionary: [String: Self]? { if case .dictionary(let d) = self { d } else { nil } }
    var text: String? {
        guard case .string(let bytes) = self else { return nil }
        if bytes.starts(with: [0xfe, 0xff]) { return String(data: bytes.dropFirst(2), encoding: .utf16BigEndian) }
        // Never guess a high-byte PDFDocEncoding value as Unicode.
        guard bytes.allSatisfy({ $0 < 128 }) else { return nil }
        return String(data: bytes, encoding: .ascii)
    }
    static func numeric(_ n: Double) -> Self {
        .number(String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), n))
    }
    static func text(_ text: String) -> Self {
        if text.utf8.allSatisfy({ $0 < 128 }) { return .string(Data(text.utf8)) }
        var data = Data([0xfe, 0xff])
        for c in text.utf16 { data.append(UInt8(c >> 8)); data.append(UInt8(c & 255)) }
        return .string(data)
    }
    func encoded() throws -> Data {
        func escaped(_ s: String) -> String {
            s.utf8.map { b in
                (33...126).contains(b) && ![35,37,40,41,47,60,62,91,93,123,125].contains(b)
                    ? String(UnicodeScalar(b)) : String(format: "#%02X", b)
            }.joined()
        }
        switch self {
        case .number(let n): return Data(n.utf8)
        case .name(let s): return Data(("/" + escaped(s)).utf8)
        case .string(let d): return Data(("<" + d.map { String(format: "%02X", $0) }.joined() + ">").utf8)
        case .reference(let n, let g): return Data("\(n) \(g) R".utf8)
        case .null: return Data("null".utf8)
        case .atom(let a):
            guard a == "true" || a == "false" else { throw LaTeXApplePDFError.invalidResource("PDF dictionary atom") }
            return Data(a.utf8)
        case .array(let a):
            var d = Data("[".utf8)
            for v in a { d.append(try v.encoded()); d.append(32) }
            d.append(93); return d
        case .dictionary(let object):
            var d = Data("<<".utf8)
            for k in object.keys.sorted() {
                d.append(32); d.append(try Self.name(k).encoded()); d.append(32)
                d.append(try object[k]!.encoded())
            }
            d.append(contentsOf: [32,62,62]); return d
        }
    }
}

struct NativePDFParser {
    let data: Data
    var position: Int = 0
    private var nodes = 0
    var check: () throws -> Void
    init(_ data: Data, at position: Int = 0, check: @escaping () throws -> Void) {
        self.data = data; self.position = position; self.check = check
    }
    func byte(_ i: Int) -> UInt8 { data[data.startIndex+i] }
    func delimiter(_ b: UInt8) -> Bool { [0,9,10,12,13,32,37,40,41,47,60,62,91,93,123,125].contains(b) }
    mutating func whitespace() {
        while position < data.count {
            let b = byte(position)
            if [0,9,10,12,13,32].contains(b) { position += 1 }
            else if b == 37 { while position < data.count && ![10,13].contains(byte(position)) { position += 1 } }
            else { break }
        }
    }
    mutating func word() throws -> String {
        whitespace(); let start = position
        while position < data.count && !delimiter(byte(position)) { position += 1 }
        guard position > start, position-start <= 4096,
              let s = String(data: data.subdata(in: start..<position), encoding: .ascii) else {
            throw LaTeXApplePDFError.invalidResource("PDF token")
        }
        return s
    }
    mutating func all() throws -> [NativePDFValue] {
        var values = [NativePDFValue]()
        while true {
            whitespace(); if position == data.count { return values }
            guard values.count < 256 else { throw LaTeXApplePDFError.limit("special operands") }
            values.append(try value())
        }
    }
    mutating func value(_ depth: Int = 0) throws -> NativePDFValue {
        try check(); nodes += 1
        guard depth <= 32, nodes <= 100_000 else { throw LaTeXApplePDFError.limit("PDF data structure") }
        whitespace(); guard position < data.count else { throw LaTeXApplePDFError.invalidDisplayList }
        let b = byte(position); position += 1
        if b == 40 {
            var d = Data(), nesting = 1
            while position < data.count && nesting > 0 {
                var c = byte(position); position += 1
                if c == 92 {
                    guard position < data.count else { throw LaTeXApplePDFError.invalidDisplayList }
                    c = byte(position); position += 1
                    if (48...55).contains(c) {
                        var n = Int(c-48), count = 1
                        while count < 3 && position < data.count && (48...55).contains(byte(position)) {
                            n=n*8+Int(byte(position)-48); position += 1; count += 1
                        }
                        d.append(UInt8(n & 255))
                    } else {
                        switch c {
                        case 110: d.append(10)
                        case 114: d.append(13)
                        case 116: d.append(9)
                        case 98: d.append(8)
                        case 102: d.append(12)
                        case 10: break
                        case 13: if position < data.count && byte(position)==10 { position += 1 }
                        default: d.append(c)
                        }
                    }
                } else if c == 40 { nesting += 1; d.append(c) }
                else if c == 41 { nesting -= 1; if nesting > 0 { d.append(c) } }
                else if c == 13 { if position < data.count && byte(position)==10 { position += 1 }; d.append(10) }
                else { d.append(c) }
                guard d.count <= 65_536, nesting <= 32 else { throw LaTeXApplePDFError.limit("PDF string") }
            }
            guard nesting == 0 else { throw LaTeXApplePDFError.invalidDisplayList }
            return .string(d)
        }
        if b == 91 {
            var a = [NativePDFValue]()
            while true {
                whitespace(); guard position < data.count else { throw LaTeXApplePDFError.invalidDisplayList }
                if byte(position)==93 { position += 1; return .array(a) }
                guard a.count < 100_000 else { throw LaTeXApplePDFError.limit("PDF array") }
                a.append(try value(depth+1))
            }
        }
        if b == 60 {
            if position < data.count && byte(position)==60 {
                position += 1; var d = [String: NativePDFValue]()
                while true {
                    whitespace(); guard position+1 < data.count else { throw LaTeXApplePDFError.invalidDisplayList }
                    if byte(position)==62 && byte(position+1)==62 { position += 2; return .dictionary(d) }
                    guard d.count < 4096, case .name(let k) = try value(depth+1), d[k]==nil else {
                        throw LaTeXApplePDFError.invalidDisplayList
                    }
                    d[k] = try value(depth+1)
                }
            }
            var hex = [UInt8]()
            while position < data.count && byte(position) != 62 {
                let c=byte(position); position += 1
                if [0,9,10,12,13,32].contains(c) { continue }
                guard let n=Int(String(UnicodeScalar(c)),radix:16), hex.count<131072 else { throw LaTeXApplePDFError.invalidDisplayList }
                hex.append(UInt8(n))
            }
            guard position<data.count else { throw LaTeXApplePDFError.invalidDisplayList };position += 1
            if hex.count%2 != 0 { hex.append(0) }
            return .string(Data(stride(from:0,to:hex.count,by:2).map { hex[$0]*16+hex[$0+1] }))
        }
        if b == 47 {
            var bytes=Data()
            while position<data.count && !delimiter(byte(position)) {
                let c=byte(position);position += 1
                if c==35 {
                    guard position+1<data.count,
                          let n=Int(String(bytes:[byte(position),byte(position+1)],encoding:.ascii) ?? "",radix:16) else { throw LaTeXApplePDFError.invalidDisplayList }
                    bytes.append(UInt8(n));position += 2
                } else {bytes.append(c)}
                guard bytes.count<=4096 else { throw LaTeXApplePDFError.limit("PDF name") }
            }
            guard !bytes.isEmpty,let s=String(data:bytes,encoding:.utf8) else { throw LaTeXApplePDFError.invalidDisplayList }
            return .name(s)
        }
        position -= 1;let token=try word()
        if token=="null" { return .null }
        if token.range(of:#"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#,options:.regularExpression) != nil,
           let number=Double(token),number.isFinite,abs(number)<=10_000_000_000 {
            let saved=position
            if let n=Int(token),n>=0 {
                if let g=try? word(),let generation=Int(g),generation>=0,generation<65535,
                   let r=try? word(),r=="R" { return .reference(n,generation) }
                position=saved
            }
            return .number(token)
        }
        return .atom(token)
    }
}

struct NativePDFDestination {
    let page: Int
    let kind: String
    let x: Double?, y: Double?, zoom: Double?
    func value(pages: [NativePDFValue]) -> NativePDFValue {
        if kind=="Fit" { return .array([pages[page],.name("Fit")]) }
        return .array([pages[page],.name("XYZ"),x.map(NativePDFValue.numeric) ?? .null,
                       y.map(NativePDFValue.numeric) ?? .null,zoom.map(NativePDFValue.numeric) ?? .null])
    }
}
struct NativePDFInk { let model: String; let components: [Double] }
private struct NativePDFOutline { let title: NativePDFValue;let target:String;let level:Int;let open:Bool }
private struct NativePDFLink { let dictionary:[String:NativePDFValue];let target:String }
private struct NativePDFResolvedLink { let page:Int;let link:NativePDFLink;let rect:CGRect }

final class NativePDFDocumentSemantics {
    enum Command { case observed, color(NativePDFInk), begin([String:NativePDFValue],String), end }
    private(set) var commands=[String:Command]()
    private(set) var info=[String:NativePDFValue]()
    private var destinations=[String:NativePDFDestination]()
    private var outlines=[NativePDFOutline]()
    private var links=[NativePDFResolvedLink]()
    private var view=[String:NativePDFValue]()
    private var openAction: NativePDFDestination?
    private var active:(Int,NativePDFLink,CGRect?)?
    private var initialInk: NativePDFInk?
    private var requestedMajor:Int?,requestedMinor:Int?
    private var stackInitialized=false
    private var notes=[String]()
    private let pageCount:Int
    private let check:() throws -> Void
    init(pages:Int,check:@escaping () throws -> Void) {pageCount=pages;self.check=check}
    static func key(_ page:Int,_ operation:Int)->String {"\(page):\(operation)"}
    var isAnnotationActive:Bool { active != nil }
    var pageInk:NativePDFInk? {initialInk}
    var auxiliaryInfo:[String:Any] {
        let keys=["Title":kCGPDFContextTitle,"Subject":kCGPDFContextSubject,"Creator":kCGPDFContextCreator,
                  "Author":kCGPDFContextAuthor,"Keywords":kCGPDFContextKeywords]
        var result:[String:Any]=[kCGPDFContextCreator as String:"Floe Native Typesetting"]
        for (k,v) in info { if let key=keys[k],let text=v.text {result[key as String]=text} }
        return result
    }
    private func fail(_ s:String)throws->Never {throw LaTeXApplePDFError.unsupportedSpecial(s)}
    private func exact(_ d:[String:NativePDFValue],_ allowed:Set<String>)throws {
        guard Set(d.keys).isSubset(of:allowed) else {try fail("PDF dictionary keys")}
    }
    private func target(_ value:NativePDFValue?)throws->String {
        guard let d=value?.dictionary,Set(d.keys)==["S","D"],d["S"]?.name=="GoTo",
              let name=d["D"]?.text,!name.isEmpty,name.utf8.count<=4096 else {try fail("non-GoTo action")}
        return name
    }
    private func destination(_ v:NativePDFValue,page:Int,point:CGPoint)throws->NativePDFDestination {
        guard let a=v.array,a.count>=2 else {try fail("destination array")}
        let p:Int
        if a[0] == .atom("@thispage") {p=page}
        else if case .atom(let name)=a[0],name.hasPrefix("@page"),let n=Int(name.dropFirst(5)) {p=n-1}
        else {try fail("destination page")}
        guard (0..<pageCount).contains(p) else {try fail("destination page range")}
        if a[1].name=="Fit",a.count==2 {return .init(page:p,kind:"Fit",x:nil,y:nil,zoom:nil)}
        guard a[1].name=="XYZ",a.count==5 else {try fail("destination mode")}
        func coordinate(_ v:NativePDFValue,_ variable:String,_ current:Double)throws->Double? {
            if v == .null {return nil};if v == .atom(variable) {return current}
            guard let n=v.real,n.isFinite,abs(n)<=1_000_000 else {try fail("destination coordinate")};return n
        }
        let x=try coordinate(a[2],"@xpos",point.x),y=try coordinate(a[3],"@ypos",point.y)
        let z=try coordinate(a[4],"@zoom",0)
        guard z == nil || z! > 0 else {try fail("destination zoom")}
        return .init(page:p,kind:"XYZ",x:x,y:y,zoom:z)
    }
    @discardableResult func record(_ text:String,key:String,page:Int,point:CGPoint)throws->Bool {
        try check()
        let prefixes=["pdf:docinfo","pdfcolorstackinit","pdf:dest","pdf:majorversion","pdf:minorversion",
                      "dvipdfmx:config","pdf:outline","pdf:docview","pdf:bann","pdf:eann"]
        guard let prefix=prefixes.first(where:{text.hasPrefix($0)}) else {return false}
        var parser=NativePDFParser(Data(text.dropFirst(prefix.count).utf8),check:check)
        var a=try parser.all();commands[key] = .observed
        switch prefix {
        case "pdf:docinfo":
            guard a.count==1,let d=a[0].dictionary else {try fail(prefix)}
            try exact(d,["Title","Subject","Creator","Author","Keywords"])
            for (k,v) in d {
                guard let t=v.text,t.utf8.count<=32768,info[k]==nil || info[k]==v else {try fail("document text encoding/conflict")}
                info[k]=v
            }
        case "pdf:majorversion","pdf:minorversion":
            guard a.count==1,let n=a[0].int else {try fail(prefix)}
            if prefix=="pdf:majorversion" {guard [1,2].contains(n),requestedMajor==nil || requestedMajor==n else {try fail(prefix)};requestedMajor=n}
            else {guard (0...7).contains(n),requestedMinor==nil || requestedMinor==n else {try fail(prefix)};requestedMinor=n}
        case "dvipdfmx:config":
            guard a==[.atom("C"),.atom("0x0010")] else {try fail("dvipdfmx config")}
            notes.append("dvipdfmx C 0x0010: all declared named destinations retained; native writer never prunes them.")
        case "pdfcolorstackinit":
            guard !stackInitialized,a.count==4,a[0].int==1,a[1] == .atom("page"),a[2] == .atom("direct"),
                  case .string(let program)=a[3] else {try fail(prefix)}
            stackInitialized=true
            var p=NativePDFParser(program,check:check);let ops=try p.all()
            // The actual page stack initializes identical fill/stroke colors.
            // This restricted color data grammar is never a PS interpreter.
            let half=ops.count/2
            guard ops.count%2==0,[2,4,5].contains(half),let f=ops[half-1].atomValue,
                  let s=ops.last?.atomValue,[("g","G"),("rg","RG"),("k","K")].contains(where:{$0.0==f && $0.1==s}) else {try fail("color stack program")}
            let values=ops.prefix(half-1).compactMap(\.real),stroke=ops.dropFirst(half).dropLast().compactMap(\.real)
            guard values.count==half-1,values.count==["g":1,"rg":3,"k":4][f],values==stroke,
                  values.allSatisfy({(0...1).contains($0)}) else {try fail("color stack components")}
            commands[key] = .color(.init(model:f,components:values))
        case "pdf:dest":
            guard a.count==2,let name=a[0].text,!name.isEmpty,name.utf8.count<=4096,
                  destinations[name]==nil,destinations.count<10000 else {try fail(prefix)}
            destinations[name]=try destination(a[1],page:page,point:point)
        case "pdf:outline":
            var open=true
            if let flags=a.first?.array {
                guard flags.isEmpty || flags == [.atom("-")] else {try fail(prefix)}
                open=flags.isEmpty;a.removeFirst()
            }
            guard a.count==2,let level=a[0].int,(1...32).contains(level),let d=a[1].dictionary,
                  let title=d["Title"],let decoded=title.text,decoded.utf8.count<=32768,
                  outlines.count<4096,level <= (outlines.last?.level ?? 0)+1 else {try fail(prefix)}
            try exact(d,["Title","A"])
            outlines.append(.init(title:title,target:try target(d["A"]),level:level,open:open))
        case "pdf:docview":
            guard a.count==1,let d=a[0].dictionary,view.isEmpty || view==d else {try fail(prefix)}
            try exact(d,["OpenAction","PageMode","PageLayout"])
            if let mode=d["PageMode"]?.name {guard ["UseNone","UseOutlines","UseThumbs","FullScreen"].contains(mode) else {try fail("PageMode")}}
            else if d["PageMode"] != nil {try fail("PageMode")}
            if let layout=d["PageLayout"]?.name {guard ["SinglePage","OneColumn","TwoColumnLeft","TwoColumnRight","TwoPageLeft","TwoPageRight"].contains(layout) else {try fail("PageLayout")}}
            else if d["PageLayout"] != nil {try fail("PageLayout")}
            if let value=d["OpenAction"] {openAction=try destination(value,page:page,point:point)}
            view=d
        case "pdf:bann":
            guard a.count==1,let d=a[0].dictionary,d["Subtype"]?.name=="Link",
                  d["Type"]==nil || d["Type"]?.name=="Annot" else {try fail(prefix)}
            try exact(d,["Type","Subtype","Border","H","C","A"])
            if let border=d["Border"]?.array {guard border.count==3,border.allSatisfy({($0.real ?? -1)>=0 && ($0.real ?? 101)<=100}) else {try fail("link border")}}
            else if d["Border"] != nil {try fail("link border")}
            if let c=d["C"]?.array {guard [0,1,3,4].contains(c.count),c.allSatisfy({(0...1).contains($0.real ?? -1)}) else {try fail("link color")}}
            else if d["C"] != nil {try fail("link color")}
            if let h=d["H"]?.name {guard ["N","I","O","P"].contains(h) else {try fail("link highlight")}}
            else if d["H"] != nil {try fail("link highlight")}
            commands[key] = .begin(d,try target(d["A"]))
        case "pdf:eann":guard a.isEmpty else {try fail(prefix)};commands[key] = .end
        default:try fail(prefix)
        }
        return true
    }
    func validateReferences()throws {
        for o in outlines {guard destinations[o.target] != nil else {try fail("unresolved outline target")}}
        for c in commands.values {if case .begin(_,let t)=c {guard destinations[t] != nil else {try fail("unresolved link target")}}}
        let major=requestedMajor ?? 1,minor=requestedMinor ?? (major==2 ? 0:3)
        guard (major==1 && (3...7).contains(minor)) || (major==2 && minor==0) else {try fail("PDF version")}
    }
    func perform(_ c:Command,page:Int)throws->NativePDFInk? {
        try check()
        switch c {
        case .observed:return nil
        case .color(let ink):initialInk=ink;return ink
        case .begin(let d,let target):guard active==nil else {throw LaTeXApplePDFError.unbalancedState};active=(page,.init(dictionary:d,target:target),nil);return nil
        case .end:
            guard let (p,link,rect)=active,p==page,let rect,!rect.isEmpty,!rect.isNull,links.count<10000 else {throw LaTeXApplePDFError.unbalancedState}
            links.append(.init(page:p,link:link,rect:rect));active=nil;return nil
        }
    }
    func includeInk(_ rect:CGRect)throws {
        guard let (page,link,old)=active else {return}
        guard !rect.isInfinite,rect.origin.x.isFinite,rect.origin.y.isFinite,
              abs(rect.minX)<=1_000_000,abs(rect.maxX)<=1_000_000,abs(rect.minY)<=1_000_000,abs(rect.maxY)<=1_000_000 else {throw LaTeXApplePDFError.invalidDisplayList}
        if !rect.isNull && !rect.isEmpty {active=(page,link,old.map{$0.union(rect)} ?? rect)}
    }
    func endPage()throws {guard active==nil else {throw LaTeXApplePDFError.unbalancedState}}

    /// Public CoreGraphics readback, invoked inside the caller's existing PDF
    /// gate/exception boundary before atomic publication.
    func validate(_ document:CGPDFDocument)throws {
        func dict(_ d:CGPDFDictionaryRef?,_ k:String)->CGPDFDictionaryRef? {var v:CGPDFDictionaryRef?;guard let d,CGPDFDictionaryGetDictionary(d,k,&v) else{return nil};return v}
        func array(_ d:CGPDFDictionaryRef?,_ k:String)->CGPDFArrayRef? {var v:CGPDFArrayRef?;guard let d,CGPDFDictionaryGetArray(d,k,&v) else{return nil};return v}
        func name(_ d:CGPDFDictionaryRef?,_ k:String)->String? {var v:UnsafePointer<CChar>?;guard let d,CGPDFDictionaryGetName(d,k,&v),let v else{return nil};return String(cString:v)}
        func text(_ d:CGPDFDictionaryRef?,_ k:String)->String? {var v:CGPDFStringRef?;guard let d,CGPDFDictionaryGetString(d,k,&v),let v else{return nil};return CGPDFStringCopyTextString(v).map{$0 as String}}
        func require(_ condition:Bool)throws {guard condition else{throw LaTeXApplePDFError.outputFailure}}
        func destination(_ a:CGPDFArrayRef,_ expected:NativePDFDestination)throws {
            var page:CGPDFDictionaryRef?,kind:UnsafePointer<CChar>?
            try require(CGPDFArrayGetCount(a)==(expected.kind=="Fit" ? 2:5))
            try require(CGPDFArrayGetDictionary(a,0,&page) && page==document.page(at:expected.page+1)?.dictionary)
            try require(CGPDFArrayGetName(a,1,&kind));try require(kind.map{String(cString:$0)}==expected.kind)
            if expected.kind=="XYZ" {
                for (index,value) in [(2,expected.x),(3,expected.y),(4,expected.zoom)] {
                    var actual:CGPDFReal=0;let present=CGPDFArrayGetNumber(a,index,&actual)
                    if let value {try require(present && abs(Double(actual)-value)<0.0001)}else{try require(!present)}
                }
            }
        }
        for (k,v) in info {try require(text(document.info,k)==v.text)}
        let catalog=document.catalog
        if !destinations.isEmpty {
            guard let entries=array(dict(dict(catalog,"Names"),"Dests"),"Names") else{throw LaTeXApplePDFError.outputFailure}
            try require(CGPDFArrayGetCount(entries)==destinations.count*2)
            var seen=Set<String>()
            for index in stride(from:0,to:CGPDFArrayGetCount(entries),by:2) {
                try check();var key:CGPDFStringRef?,value:CGPDFArrayRef?
                try require(CGPDFArrayGetString(entries,index,&key) && CGPDFArrayGetArray(entries,index+1,&value))
                guard let key,let value,let s=CGPDFStringCopyTextString(key).map({$0 as String}),let expected=destinations[s] else{throw LaTeXApplePDFError.outputFailure}
                try require(seen.insert(s).inserted);try destination(value,expected)
            }
        }
        var titles=[String](),targets=[String]()
        func outlinesFrom(_ first:CGPDFDictionaryRef?,_ depth:Int)throws {
            guard depth<=32 else{throw LaTeXApplePDFError.outputFailure};var item=first
            while let current=item {
                try check();guard titles.count<4096,let t=text(current,"Title"),let a=dict(current,"A"),name(a,"S")=="GoTo",let target=text(a,"D") else{throw LaTeXApplePDFError.outputFailure}
                titles.append(t);targets.append(target);try outlinesFrom(dict(current,"First"),depth+1);item=dict(current,"Next")
            }
        }
        try outlinesFrom(dict(dict(catalog,"Outlines"),"First"),0)
        try require(titles==outlines.map{$0.title.text!} && targets==outlines.map(\.target))
        for page in 0..<pageCount {
            let expected=links.filter{$0.page==page};guard !expected.isEmpty else{continue}
            guard let a=array(document.page(at:page+1)?.dictionary,"Annots") else{throw LaTeXApplePDFError.outputFailure}
            try require(CGPDFArrayGetCount(a)==expected.count)
            for (index,link) in expected.enumerated() {
                var d:CGPDFDictionaryRef?;try require(CGPDFArrayGetDictionary(a,index,&d))
                try require(name(d,"Subtype")=="Link" && name(dict(d,"A"),"S")=="GoTo" && text(dict(d,"A"),"D")==link.link.target)
                guard let r=array(d,"Rect") else{throw LaTeXApplePDFError.outputFailure};try require(CGPDFArrayGetCount(r)==4)
                for (i,n) in [link.rect.minX,link.rect.minY,link.rect.maxX,link.rect.maxY].enumerated() {var actual:CGPDFReal=0;try require(CGPDFArrayGetNumber(r,i,&actual) && abs(actual-n)<0.0001)}
            }
        }
        for k in ["PageMode","PageLayout"] {if let v=view[k] {try require(name(catalog,k)==v.name)}}
        if let expected=openAction {guard let a=array(catalog,"OpenAction") else{throw LaTeXApplePDFError.outputFailure};try destination(a,expected)}
    }

    func revision(_ data:Data)throws->(Data,Data?,LaTeXApplePDFNavigationReceipt) {
        try check()
        let header=String(data:data.prefix(8),encoding:.ascii) ?? ""
        guard header.range(of:#"^%PDF-[12]\.[0-7]$"#,options:.regularExpression) != nil else {throw LaTeXApplePDFError.invalidResource("native PDF header")}
        let native=String(header.dropFirst(5)),requested=requestedMajor.map{"\($0).\(requestedMinor ?? ($0==2 ? 0:3))"} ?? requestedMinor.map{"1.\($0)"}
        let version=max(Double(native)!,requested.flatMap(Double.init) ?? 0)
        let emitted=String(format:"%.1f",locale:Locale(identifier:"en_US_POSIX"),version)
        var compatibility=notes
        if let requested {compatibility.append("PDF version request \(requested); native \(native); emitted \(emitted). Version is an explicit header floor, never a downgrade.")}
        let receipt=LaTeXApplePDFNavigationReceipt(metadataKeys:info.keys.sorted(),namedDestinationCount:destinations.count,
            outlineCount:outlines.count,linkAnnotationCount:links.count,emittedVersion:emitted,compatibilityNotes:compatibility)
        guard !info.isEmpty || !destinations.isEmpty || !outlines.isEmpty || !links.isEmpty || !view.isEmpty else {
            return (Data(),requested == nil ? nil:Data("%PDF-\(emitted)".utf8),receipt)
        }
        let pdf=try NativeGeneratedPDF(data,check:check)
        guard pdf.pages.count==pageCount else {throw LaTeXApplePDFError.outputFailure}
        var root=pdf.catalog,objects=[Int:(Int,NativePDFValue)](),next=pdf.size
        func allocate(_ value:NativePDFValue)->NativePDFValue {
            let n=next;next += 1;objects[n]=(0,value);return .reference(n,0)
        }
        func replace(_ ref:NativePDFValue,_ value:NativePDFValue)throws {
            guard case .reference(let n,let g)=ref else {throw LaTeXApplePDFError.invalidResource("native object reference")};objects[n]=(g,value)
        }
        guard root["OpenAction"]==nil,root["AA"]==nil,root["Dests"]==nil,root["Outlines"]==nil else {throw LaTeXApplePDFError.invalidResource("unexpected native navigation")}
        if !destinations.isEmpty {
            var names=try pdf.dictionary(root["Names"] ?? .dictionary([:]))
            guard names["Dests"]==nil,names["JavaScript"]==nil,names["EmbeddedFiles"]==nil else {throw LaTeXApplePDFError.invalidResource("unexpected native name tree")}
            let ordered=destinations.keys.sorted { a,b in
                guard case .string(let x)=NativePDFValue.text(a),case .string(let y)=NativePDFValue.text(b) else {return a<b}
                return x.lexicographicallyPrecedes(y)
            }
            var pairs=[NativePDFValue]()
            for name in ordered {try check();pairs.append(.text(name));pairs.append(destinations[name]!.value(pages:pdf.pages))}
            names["Dests"]=allocate(.dictionary(["Names":.array(pairs)]));root["Names"] = .dictionary(names)
        }
        if !outlines.isEmpty {
            let rootNumber=next;next += 1
            let ids=outlines.map{_ ->Int in let n=next;next += 1;return n}
            var children=[Int:[Int]](),parents=[Int:Int](),stack=[Int]()
            for i in outlines.indices {
                while stack.count>=outlines[i].level {stack.removeLast()}
                let parent=stack.last ?? -1;children[parent,default:[]].append(i);parents[i]=parent;stack.append(i)
            }
            func visible(_ i:Int)->Int { (children[i] ?? []).reduce(0){$0+1+(outlines[$1].open ? visible($1):0)} }
            for i in outlines.indices {
                try check();let parent=parents[i]!,siblings=children[parent]!,index=siblings.firstIndex(of:i)!
                var d:[String:NativePDFValue]=["Title":outlines[i].title,"Parent":.reference(parent<0 ? rootNumber:ids[parent],0),
                    "A":.dictionary(["S":.name("GoTo"),"D":.text(outlines[i].target)])]
                if index>0 {d["Prev"] = .reference(ids[siblings[index-1]],0)}
                if index+1<siblings.count {d["Next"] = .reference(ids[siblings[index+1]],0)}
                if let list=children[i],let first=list.first,let last=list.last {
                    d["First"] = .reference(ids[first],0);d["Last"] = .reference(ids[last],0)
                    d["Count"] = .number(String((outlines[i].open ? 1:-1)*visible(i)))
                }
                objects[ids[i]]=(0,.dictionary(d))
            }
            let top=children[-1]!
            objects[rootNumber]=(0,.dictionary(["Type":.name("Outlines"),"First":.reference(ids[top.first!],0),
                "Last":.reference(ids[top.last!],0),"Count":.number(String(top.reduce(0){$0+1+(outlines[$1].open ? visible($1):0)}))]))
            root["Outlines"] = .reference(rootNumber,0)
        }
        for page in Set(links.map(\.page)).sorted() {
            try check();var d=try pdf.dictionary(pdf.pages[page]);guard d["Annots"]==nil else {throw LaTeXApplePDFError.invalidResource("unexpected native annotations")}
            let annotations=links.filter{$0.page==page}.map { link ->NativePDFValue in
                var a=link.link.dictionary;a["Type"] = .name("Annot")
                a["Rect"] = .array([.numeric(link.rect.minX),.numeric(link.rect.minY),.numeric(link.rect.maxX),.numeric(link.rect.maxY)])
                return allocate(.dictionary(a))
            }
            d["Annots"] = .array(annotations);try replace(pdf.pages[page],.dictionary(d))
        }
        for key in ["PageMode","PageLayout"] {if let value=view[key] {root[key]=value}}
        if let openAction {root["OpenAction"]=openAction.value(pages:pdf.pages)}
        var trailer=pdf.trailer
        if !info.isEmpty {
            var d=try pdf.dictionary(trailer["Info"] ?? .dictionary([:]))
            for (k,v) in info {d[k]=v}
            if let ref=trailer["Info"] {try replace(ref,.dictionary(d))}else {trailer["Info"]=allocate(.dictionary(d))}
        }
        try replace(pdf.root,.dictionary(root));trailer["Size"] = .number(String(next));trailer["Prev"] = .number(String(pdf.xref))
        var extra=Data("\n".utf8),offsets=[Int:(Int,Int)]()
        for n in objects.keys.sorted() {
            try check();let (g,value)=objects[n]!,offset=data.count+extra.count
            offsets[n]=(offset,g);extra.append(Data("\(n) \(g) obj\n".utf8));extra.append(try value.encoded());extra.append(Data("\nendobj\n".utf8))
            guard data.count+extra.count<=256*1024*1024 else {throw LaTeXApplePDFError.limit("PDF bytes")}
        }
        let xref=data.count+extra.count;extra.append(Data("xref\n0 1\n0000000000 65535 f \n".utf8))
        for n in offsets.keys.sorted() {let (o,g)=offsets[n]!;extra.append(Data(String(format:"%d 1\n%010d %05d n \n",n,o,g).utf8))}
        extra.append(Data("trailer\n".utf8));extra.append(try NativePDFValue.dictionary(trailer).encoded())
        extra.append(Data("\nstartxref\n\(xref)\n%%EOF\n".utf8))
        guard data.count+extra.count<=256*1024*1024 else {throw LaTeXApplePDFError.limit("PDF bytes")}
        return (extra,requested == nil ? nil:Data("%PDF-\(emitted)".utf8),receipt)
    }
}

private extension NativePDFValue {
    var atomValue:String? {if case .atom(let a)=self {a}else{nil}}
}

private final class NativeGeneratedPDF {
    let data:Data,check:()throws->Void
    private(set) var xref=0,size=0,root:NativePDFValue = .null,trailer=[String:NativePDFValue]()
    private var offsets=[Int:(Int,Int)]()
    private(set) var catalog=[String:NativePDFValue](),pages=[NativePDFValue]()
    init(_ data:Data,check:@escaping ()throws->Void)throws {
        self.data=data;self.check=check
        guard let marker=data.range(of:Data("startxref".utf8),options:.backwards),
              let tail=String(data:data.suffix(from:marker.upperBound),encoding:.ascii) else {throw LaTeXApplePDFError.invalidResource("native xref")}
        let parts=tail.split(whereSeparator:{$0.isWhitespace})
        guard parts.count==2,parts[1]=="%%EOF",let x=Int(parts[0]),x>=0,x<data.count else {throw LaTeXApplePDFError.invalidResource("native xref offset")}
        xref=x;var p=NativePDFParser(data,at:x,check:check)
        guard try p.word()=="xref" else {throw LaTeXApplePDFError.invalidResource("native classic xref required")}
        var total=0
        while true {
            try check();let word=try p.word();if word=="trailer" {break}
            guard let first=Int(word),let count=Int(try p.word()),first>=0,first<=500_000,count>0,count<=500_000-first else {throw LaTeXApplePDFError.invalidResource("native xref section")}
            total += count;guard total<=500_000 else {throw LaTeXApplePDFError.limit("native xref entries")}
            for n in first..<(first+count) {
                if n%256==0 {try check()}
                guard let offset=Int(try p.word()),let g=Int(try p.word()),(0...65535).contains(g) else {throw LaTeXApplePDFError.invalidResource("native xref record")}
                let flag=try p.word();guard flag=="n" || flag=="f" else {throw LaTeXApplePDFError.invalidResource("native xref flag")}
                if flag=="n" {guard offsets[n]==nil,offset>=0,offset<x,g<65535 else {throw LaTeXApplePDFError.invalidResource("native object offset")};offsets[n]=(offset,g)}
            }
        }
        guard let t=try p.value().dictionary,Set(t.keys).isSubset(of:["Size","Root","Info","ID"]),
              let s=t["Size"]?.int,s>0,s<=500_000,(offsets.keys.max() ?? 0)<s,let r=t["Root"],case .reference=r else {throw LaTeXApplePDFError.invalidResource("native trailer/encryption/revision")}
        trailer=t;size=s;root=r
        catalog=try dictionary(r)
        guard catalog["Type"]?.name=="Catalog",let pageRoot=catalog["Pages"] else {throw LaTeXApplePDFError.invalidResource("native catalog")}
        var visited=Set<Int>()
        func walk(_ ref:NativePDFValue,_ depth:Int)throws {
            try check();guard depth<=32,case .reference(let n,_)=ref,visited.insert(n).inserted else {throw LaTeXApplePDFError.invalidResource("native page tree")}
            let d=try dictionary(ref)
            if d["Type"]?.name=="Page" {guard pages.count<2000 else {throw LaTeXApplePDFError.limit("pages")};pages.append(ref);return}
            guard d["Type"]?.name=="Pages",let children=d["Kids"]?.array,children.count<=2000 else {throw LaTeXApplePDFError.invalidResource("native page branch")}
            let before=pages.count;for child in children {try walk(child,depth+1)}
            guard d["Count"]?.int==pages.count-before else {throw LaTeXApplePDFError.invalidResource("native page count")}
        }
        try walk(pageRoot,0)
    }
    func dictionary(_ value:NativePDFValue)throws->[String:NativePDFValue] {
        if let d=value.dictionary {return d}
        guard case .reference(let n,let g)=value,let (offset,generation)=offsets[n],g==generation else {throw LaTeXApplePDFError.invalidResource("native dictionary reference")}
        var p=NativePDFParser(data,at:offset,check:check)
        guard try p.word()==String(n),try p.word()==String(g),try p.word()=="obj",
              let d=try p.value().dictionary,try p.word()=="endobj",p.position-offset<=2*1024*1024 else {throw LaTeXApplePDFError.invalidResource("native dictionary object")}
        return d
    }
}
