// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

@MainActor
struct EDCanvasInputTests {
    @Test func cancelledOrFailedNativeDragNeverCommitsAnEdit() {
        var moves:[(CGPoint,CGPoint)]=[],cancellations=0
        let identity=EDCanvasInputIdentity(context:.board(boardID:UUID()),mode:.board(.select),generation:UUID(),center:.zero,scale:1,size:.init(width:400,height:300))
        let input=EDAInputSurface(fingerDrawing:true,identity:identity,editingEnabled:true,tap:{_ in},move:{moves.append(($0,$1))},stroke:nil,
                                  hover:{_ in},select:{_ in},cancel:{cancellations += 1},command:{_ in},canCommand:{_ in true},pan:{_ in},zoom:{_ in})
        let view=EDAInputSurface.InputView(frame:.zero);view.update(input)
        let start=CGPoint(x:10,y:20),end=CGPoint(x:60,y:70)
        view.beginEditGesture(at:start);view.finishEditGesture(state:.cancelled,from:start,to:end)
        view.beginEditGesture(at:start);view.finishEditGesture(state:.failed,from:start,to:end)
        #expect(moves.isEmpty);#expect(cancellations==2)
        view.beginEditGesture(at:start);view.finishEditGesture(state:.ended,from:start,to:end)
        #expect(moves.count==1);#expect(moves.first?.0==start);#expect(moves.first?.1==end)
    }
    @Test func oldDragCannotMoveAnObjectInANewCanvas() {
        var oldMoves=0,newMoves=0,cancellations=0
        func surface(_ context:EDADocumentContext,_ move:@escaping(CGPoint,CGPoint)->Void)->EDAInputSurface{
            .init(fingerDrawing:true,identity:.init(context:context,mode:.board(.select),generation:UUID(),center:.zero,scale:1,size:.init(width:400,height:300)),editingEnabled:true,
                  tap:{_ in},move:move,stroke:nil,hover:{_ in},select:{_ in},cancel:{cancellations += 1},command:{_ in},canCommand:{_ in true},pan:{_ in},zoom:{_ in})
        }
        let view=EDAInputSurface.InputView(frame:.zero),start=CGPoint(x:10,y:10),end=CGPoint(x:50,y:50)
        view.update(surface(.board(boardID:UUID())){_,_ in oldMoves += 1});view.beginEditGesture(at:start)
        view.update(surface(.board(boardID:UUID())){_,_ in newMoves += 1})
        view.finishEditGesture(state:.ended,from:start,to:end)
        #expect(cancellations==1);#expect(oldMoves==0);#expect(newMoves==0)
        view.beginEditGesture(at:start);view.finishEditGesture(state:.ended,from:start,to:end)
        #expect(newMoves==1)
    }
    @Test func pencilAndMouseEditWithoutEnablingFingerDrawing() {
        let standard=Set(EDAInputSurface.InputView.editingTouchTypes(fingerDrawing:false).map(\.intValue))
        let touch=Set(EDAInputSurface.InputView.editingTouchTypes(fingerDrawing:true).map(\.intValue))
        #expect(standard==[UITouch.TouchType.pencil.rawValue,UITouch.TouchType.indirectPointer.rawValue])
        #expect(touch==standard.union([UITouch.TouchType.direct.rawValue]))
    }
    @Test func zoomedHitToleranceStaysCloseToThePointer() {
        let projection=EDAProjection(bounds:CGRect(x:0,y:0,width:30,height:25),size:CGSize(width:600,height:500),zoom:10)
        #expect(abs(EDCanvasEditor.hitTolerance(for:projection)*projection.scale-14)<0.001)
    }
    @Test func oldRoutingRevisionAndCancelledCanvasEditPreserveTheSavedOriginal() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EDCanvasSource-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let (session,original)=try await EDWorkbenchSession.createNew(root:root,title:"Source fence")
        let oldRevision=session.revision
        try await session.apply([.rename("Changed outside the gesture")],expectedRevision:oldRevision)
        let saved=try await session.store.load()
        let board=try #require(original.boards.first)
        do{
            try await session.route(boardID:board.id,from:.zero,to:.init(10,10),layer:"F.Cu",width:0.25,expectedRevision:oldRevision)
            Issue.record("An old routing anchor was reinterpreted against the new revision")
        }catch let error as EDAError{
            guard case .staleRevision=error else{Issue.record("Unexpected routing error: \(error)");return}
        }
        let pending=Task{@MainActor in
            try await session.apply([.rename("Cancelled gesture")],expectedRevision:saved.project.revision,cancelBeforeCommit:true)
        }
        pending.cancel()
        do{try await pending.value;Issue.record("A cancelled edit was admitted")}
        catch is CancellationError{}
        #expect(try await session.store.load()==saved)
        #expect(session.project==saved.project && !session.isDirty)
        await session.close()
    }
}
#endif
