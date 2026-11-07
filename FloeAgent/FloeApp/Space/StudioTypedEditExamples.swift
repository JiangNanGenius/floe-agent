// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeMusicCore
import FloeMusicNative
import FloeChemistryCore
import FloeWorkbench

struct StudioChemistryContractSnapshot: Decodable { let project: ChemistryProject }

/// Examples are encoded by the same model types that studio.edit decodes.
/// They are tool documentation, never implicit edits or generated run results.
enum StudioTypedEditExamples {
    static func encode<T:Encodable>(_ value:T) throws -> String {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return String(decoding:try encoder.encode(value),as:UTF8.self)
    }
    static func cadFormat(kind: PersonalContentKind, snapshot: Data?) -> String {
        var guide = "This is the CURRENT managed Space " + (kind == .cad2D ? "2D sketch" : "3D model") + " original. Call studio.read/studio.edit with this projectID and the exact fresh read revision. Do not guess a .floeproject/.floecad filename or use cad.document for this original. operationsJSON is ONE typed native {op,args} object. Rename an existing body with scene.object.rename {id:UUID,name:string}, or an existing sketch with sketch.rename {id:UUID,name:string}; use only the actual IDs in bodies or nativeCAD.sketches. Names are nonempty and at most 60 characters. It changes only the selected item's label, preserves geometry/other items, and uses the native undo stack. Every successful CAD edit awaits an actual save. document.save with empty args {} explicitly saves this current work without creating a file or geometry/undo command; inspect nativeCAD.savedRevision/contentSHA256/hasUnsavedChanges in the returned read state. nativeCAD.changeCount participates in the outer revision guard, including unsaved UI edits/undo. Other supported native geometry op names: sketch.create, sketch.addEntities, sketch.addText, feature.extrude, feature.revolve, feature.hole, feature.pattern, feature.mirror, feature.transform. New sketch args {name,origin:[0,0,0],xAxis:[1,0,0],yAxis:[0,1,0]}; imports remain in the existing editor. Sketch entityRows are actual native geometry; respect their complete/truncated markers."
        if let snapshot, let state = (try? JSONSerialization.jsonObject(with: snapshot)) as? [String: Any] {
            let bodies = state["bodies"] as? [[String: Any]] ?? []
            let sketches = (state["nativeCAD"] as? [String: Any])?["sketches"] as? [[String: Any]] ?? []
            let body = bodies.first(where: { $0["brep"] as? Bool == true }) ?? bodies.first
            if let row = body ?? sketches.first, let raw = row["id"] as? String, let id = UUID(uuidString: raw),
               let rename = try? encode(StudioCADRenameCommand(op: body == nil ? .sketch : .body, args: .init(id: id, name: "Renamed item"))) {
                guide += "\nRename example operationsJSON using this work's ACTUAL item ID:\n" + rename
            }
        }
        if let save = try? encode(StudioCADSaveCommand()) { guide += "\nSave example operationsJSON:\n" + save }
        return guide
    }
    static func mediaInput(kind: PersonalContentKind, revision: Int64) -> MediaV2ToolInput {
        var input = MediaV2ToolInput()
        input.expectedRevision = revision
        input.text = kind == .video ? "Caption" : "Text"
        if kind == .video {
            input.start = 0; input.duration = 3
            input.captionStyle = CaptionStyle(fontSize: 36, colorHex: "#FFFFFFFF",
                backgroundHex: "#00000000", positionY: 0.5, alignment: .center, respectsSafeArea: true)
        } else { input.number = 72; input.color = "#166F74" }
        return input
    }
    static func mediaFormat(kind: PersonalContentKind, revision: Int64?) -> String {
        let tool = kind == .video ? "video.caption" : "image.text"
        var guide = "studio.media runs ONE native local command against this original. inputJSON is one object, not an array. REQUIRED expectedRevision is the current studio.read revision (exact decimal string or integer). objectID:UUID-string; objectIDs:[UUID-string]; number/secondary/start/duration:JSON numbers; text/color/property:strings; flag:boolean; points:[{x:number,y:number}]. Time is seconds; selection points are normalized 0...1. Use actual existing IDs when editing. Read localToolIDs/catalog for local commands and hostToolIDs for host commands. media.import is an explicit host route; it is not a local catalog command. Direct studio.edit instead accepts an array of Codable MediaPreparedOperation; do not mix the two contracts. ExportOriginal returns the layered original and exportMedia renders PNG or MP4."
        if kind == .video {
            guide += " video.caption creates or updates caption text/time and can set the GLOBAL caption style. captionStyle is a complete object {fontSize:number,colorHex:string,backgroundHex?:string,positionY:number,alignment?:leading|center|trailing,respectsSafeArea?:boolean}. positionY is normalized 0...1. A style-only call omits text/start/duration and preserves every caption. Legacy color changes colorHex; property=positionY or fontSize with number changes that style field. Do not combine captionStyle with legacy style fields. For existing text select its actual caption clip objectID."
        }
        if let revision, let importExample = try? encode(StudioMediaImportInput(expectedRevision: revision,
            source: .init(workspacePath: "Attachments/actual-attachment-id/source." + (kind == .video ? "mp4" : "png"), expectedSHA256: nil))) {
            guide += " Host media.import requires {expectedRevision,source:{workspacePath:string,expectedSHA256?:lowercaseSHA256}}. Use an actual authorized task-relative file returned by file tools or the existing attachment handoff, not the illustrative path below. No absolute/App Documents paths or raw SharedDocs/RunOutput tokens. Copying preserves source bytes; a changed source or target revision refuses the commit. Import toolID: media.import. Import inputJSON:\n" + importExample
        }
        guard let revision, let example = try? encode(mediaInput(kind: kind, revision: revision)) else { return guide }
        return guide + "\nExample toolID: " + tool + "\nExample inputJSON:\n" + example
    }
    static func musicOperations(ticksPerQuarter:Int) throws -> [MusicEditOp] {
        guard (MusicTempoMap.minTicksPerQuarter...MusicTempoMap.maxTicksPerQuarter).contains(ticksPerQuarter) else {
            throw MusicError.invalidTempoMap(reason:"Read the current document's ticksPerQuarter")
        }
        let quarter = Int64(ticksPerQuarter),trackID = MusicTrackID()
        let notes = try [60,64,67].enumerated().map { index,pitch in
            try MusicMIDINote(pitch:pitch,startTick:.init(Int64(index)*quarter),durationTicks:quarter,velocity:96)
        }
        let clip = try MusicClip(name:"Three notes",trackID:trackID,offset:.init(0),
            body:.midi(.init(durationTicks:quarter*4,notes:notes)))
        let track = try FloeMusicCore.MusicTrack(id:trackID,name:"Instrument",kind:.midi,clips:[clip],
            instrument:.init(pluginID:MusicNativeBuiltins.synth))
        return [.insertTrack(track)]
    }
    static func musicFormat(ticksPerQuarter:Int, firstAudioAsset: MusicAsset? = nil) -> String {
        var guide = "JSON array of Codable MusicEditOp against this document and expectedRevision. The complete example inserts ONE NEW MIDI track, one four-quarter clip, and three notes using this document's ticksPerQuarter=\(ticksPerQuarter). It is encoded from real MusicTrack/MusicClip/MusicMIDINote types, including strip/routing/plugin fields. IDs are objects {rawValue:UUID-string}; offset is sample time {value:Int64}; startTick is musical time {value:Int64}; MIDI body is {kind:midi,midi:{durationTicks,notes,controllerPoints}}. Do not replace those wrappers with strings/numbers or invent reduced track/clip fields. The example has fresh IDs; reuse actual existing track/clip/note IDs for updates and create fresh IDs only for new entities. Existing-clip edits use updateClip(_0), not a duplicate insert. Other cases: renameTrack(_0,_1), setStrip(_0,_1), setInstrument(_0,_1), setEffects(_0,_1), insertClip(_0), removeClip(_0), removeTrack(_0), setTempo(atTick,bpm,beatsPerBar,beatUnit), setTempoMap(_0), insertBus(_0), setTrackRouting(_0,output,sends), upsertAutomationLane(_0). Commit with studio.edit, read the saved revision, then use studio.run renderWAV/renderMP3 only if requested. Existing asset bytes remain verified by the native repository."
        guide += " studio.run action=inspectAudio is read-only and uses a real audio asset ID from this document: inputJSON {assetID:{rawValue:String},startSeconds?:number,endSeconds?:number,bins?:integer}. It returns measured per-channel PCM bins and source SHA with this project revision, never playback/listening claims. MIDI note events must first be synthesized with renderWAV. renderWAV/renderMP3 receipts include audioObservation of the actual rendered mix (default first 30 seconds), plus its sourceRevision; no host path is exposed or guessed."
        if let firstAudioAsset, let audioExample = try? encode(StudioAudioInspectInput(assetID: firstAudioAsset.id, startSeconds: 0, endSeconds: nil, bins: 64)) {
            guide += "\ninspectAudio inputJSON using this document's actual audio asset:\n" + audioExample
        }
        guard let example = try? encode(musicOperations(ticksPerQuarter:ticksPerQuarter)) else {
            return guide + " A validated example could not be encoded; read the document again before editing."
        }
        return guide + "\nExample JSON:\n" + example
    }
    static func chemistryImport() -> ChemistryHostEdit {
        var edit = ChemistryHostEdit(action:.importObject)
        edit.title = "Benzene";edit.kind = .molecule;edit.format = "smiles";edit.source = "c1ccccc1"
        edit.deferPreparation = false
        return edit
    }
    static func chemistryAnalyze(_ object:ChemicalObject) -> ChemistryNativeInput {
        var input = ChemistryNativeInput()
        input.objectID = object.id;input.expectedObjectRevision = object.revision
        input.method = "analyze";input.options = .object([:]);input.environmentID = "native.local"
        return input
    }
    static func chemistryBondOrder(_ object:ChemicalObject,index:Int,order:Int) -> ChemistryHostEdit {
        var edit = ChemistryHostEdit(action:.editObject)
        edit.objectID = object.id;edit.expectedObjectRevision = object.revision
        edit.edits = .array([.object(["op":.string("bond.order"),"index":.number(Double(index)),"order":.number(Double(order))])])
        return edit
    }
    static func firstCarbonBond(_ object:ChemicalObject) -> (index:Int,order:Int)? {
        guard let text = object.facts?["cjson"]?.string,
              let graph = try? JSONDecoder().decode(FloeChemistryCore.JSONValue.self,from:Data(text.utf8)),
              let atoms = graph["atoms"]?["elements"]?["number"]?.array,
              let edges = graph["bonds"]?["connections"]?["index"]?.array,
              let orders = graph["bonds"]?["order"]?.array else { return nil }
        for index in orders.indices where edges.indices.contains(index*2+1) {
            guard let a = edges[index*2].number,let b = edges[index*2+1].number,let order = orders[index].number,
                  a.rounded() == a,b.rounded() == b,order.rounded() == order,
                  a>=0,b>=0,a<Double(atoms.count),b<Double(atoms.count),(1...3).contains(order) else { continue }
            if atoms[Int(a)].number == 6,atoms[Int(b)].number == 6 { return (index,Int(order)) }
        }
        return nil
    }
    static func chemistryFormat(project:ChemistryProject?) -> String {
        var guide = "One ChemistryHostEdit JSON, not an array. Actions: importObject(title,kind,format,source,deferPreparation), replaceObject(objectID,expectedObjectRevision,format,source), editObject(objectID,expectedObjectRevision,edits), addText(text), updateText(blockID,expectedText,text), saveDocument(blocks), setEnvironment(environmentID), restore(historyRevision,historyDigest). The complete import example uses the native SMILES parser and a real benzene ring c1ccccc1; it is not an atom-count/formula substitute. Read project.objects, object facts.cjson and their saved revisions after committing. Benzene imported from this SMILES has a bonded graph and explicit hydrogens but NO generated spatial coordinates. Missing coordinates do not erase its bonds. Formula/mass alone never prove connectivity, stereochemistry or 3D preparation. Never invent coordinates or report a planar seed as generated/optimized 3D."
        guide += " Existing native edits use a JSON edits ARRAY of {op:atom.add,atomicNumber,position:[x,y,z]}, {op:atom.replace,index,atomicNumber}, {op:atom.position,index,position:[x,y,z]}, {op:atom.remove,index}, {op:bond.add,a,b,order}, {op:bond.remove,a,b}, {op:bond.order,index,order}. Atom/bond indices are zero-based in the inspected cjson; atom/element UUIDs are not accepted here. Order is 1...3. Do not rebuild all atoms to change one bond. Rich KET groups remain preserved and unsupported numerical edits reject."
        guide += " studio.chemistry actions capabilities/history/calculate/status/cancel/apply/export use real project/object/run IDs. Native calculate inputJSON uses objectID,expectedObjectRevision,method,options and optional environmentID; this tool runs native.local only. Analyze works on a graph without 3D. UFF needs prepared coordinates and explicit hydrogens. native.local does NOT advertise rdkit.embed: do not send it to native calculate or silently use a host interpreter. If an enabled configured environment advertises 3D preparation, use the existing configured chemistry/environment job path and apply that real result; otherwise report that preparation is unavailable while retaining the graph. The project default environment remains authoritative."
        if let object = project?.objects.first(where:{ $0.kind == .molecule }) {
            if let example = try? encode(chemistryAnalyze(object)) {
                guide += "\nNative analyze inputJSON using this object's actual ID/revision (studio.chemistry action=calculate):\n" + example
            }
            if let bond = firstCarbonBond(object),let example = try? encode(chemistryBondOrder(object,index:bond.index,order:bond.order)) {
                guide += "\nExisting-object edit JSON (preserves the current inspected bond order; change order only when requested):\n" + example
            }
        }
        guard let example = try? encode(chemistryImport()) else { return guide }
        return guide + "\nExample JSON:\n" + example
    }
}
#endif
