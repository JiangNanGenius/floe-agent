// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeWorkbench

/// Direct mouse/Pencil edits; finger clip moves require a brief hold so an
/// ordinary swipe keeps scrolling. Edges/ruler remain direct manipulation.
@MainActor struct MediaV2TimelineTouchSurface:UIViewRepresentable {
    enum Mode {case clip,ruler,edge,playhead}
    @Environment(\.isEnabled) private var enabled
    var mode:Mode
    var identifier:String
    var onTap:(CGFloat)->Void = {_ in}
    var onBegin:(CGFloat)->Void = {_ in}
    var onChange:(CGFloat)->Void = {_ in}
    var onEnd:(CGFloat)->Void = {_ in}
    var onCancel:()->Void = {}
    func makeUIView(context:Context)->Surface{
        let view=Surface();view.configuration=self;view.accessibilityIdentifier=identifier
        view.install();view.isUserInteractionEnabled=enabled;return view
    }
    func updateUIView(_ uiView:Surface,context:Context){uiView.configuration=self;uiView.accessibilityIdentifier=identifier;uiView.isUserInteractionEnabled=enabled}
    static func dismantleUIView(_ uiView:Surface,coordinator:()){uiView.cancelActive()}
    final class Surface:UIView,UIGestureRecognizerDelegate {
        var configuration:MediaV2TimelineTouchSurface?
        private var active:UIGestureRecognizer?
        private var origin:CGPoint = .zero
        private var attached=false
        private var controls:[UIGestureRecognizer]=[]
        func install(){
            backgroundColor = .clear
            let direct=UIPanGestureRecognizer(target:self,action:#selector(pan(_:)))
            direct.minimumNumberOfTouches=1;direct.maximumNumberOfTouches=1
            direct.allowedTouchTypes=(configuration?.mode == .clip ? [UITouch.TouchType.pencil.rawValue,UITouch.TouchType.indirectPointer.rawValue]:[UITouch.TouchType.direct.rawValue,UITouch.TouchType.pencil.rawValue,UITouch.TouchType.indirectPointer.rawValue]).map{NSNumber(value:$0)}
            direct.delegate=self;addGestureRecognizer(direct);controls.append(direct)
            if configuration?.mode == .clip{
                let hold=UILongPressGestureRecognizer(target:self,action:#selector(held(_:)))
                hold.minimumPressDuration=0.25;hold.allowableMovement=7;hold.numberOfTouchesRequired=1
                hold.allowedTouchTypes=[NSNumber(value:UITouch.TouchType.direct.rawValue)];hold.delegate=self
                addGestureRecognizer(hold);controls.append(hold)
            }
            let tap=UITapGestureRecognizer(target:self,action:#selector(tapped(_:)));tap.delegate=self
            for control in controls{tap.require(toFail:control)}
            addGestureRecognizer(tap)
        }
        override func didMoveToWindow(){super.didMoveToWindow();attachScrollPriority()}
        override func layoutSubviews(){super.layoutSubviews();attachScrollPriority()}
        private func attachScrollPriority(){
            guard !attached,window != nil else{return}
            var ancestor=superview
            while let view=ancestor{
                if let scroll=view as? UIScrollView{
                    for control in controls{scroll.panGestureRecognizer.require(toFail:control)}
                    attached=true;break
                }
                ancestor=view.superview
            }
        }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer:UIGestureRecognizer)->Bool{
            if gestureRecognizer is UILongPressGestureRecognizer && gestureRecognizer.numberOfTouches != 1{return false}
            if let pan=gestureRecognizer as? UIPanGestureRecognizer{let v=pan.translation(in:window);return abs(v.x)>=abs(v.y)}
            return true
        }
        @objc private func tapped(_ gesture:UITapGestureRecognizer){configuration?.onTap(gesture.location(in:self).x)}
        @objc private func pan(_ gesture:UIPanGestureRecognizer){
            let delta=gesture.translation(in:window).x
            switch gesture.state{
            case .began:guard active==nil else{return};active=gesture;configuration?.onBegin(gesture.location(in:self).x-delta);configuration?.onChange(delta)
            case .changed:if active===gesture{configuration?.onChange(delta)}
            case .ended:if active===gesture{active=nil;configuration?.onEnd(delta)}
            case .cancelled,.failed:if active===gesture{active=nil;configuration?.onCancel()}
            default:break
            }
        }
        @objc private func held(_ gesture:UILongPressGestureRecognizer){
            if gesture.numberOfTouches>1{cancelActive();gesture.isEnabled=false;gesture.isEnabled=true;return}
            let location=gesture.location(in:window)
            switch gesture.state{
            case .began:guard active==nil else{return};active=gesture;origin=location;configuration?.onBegin(gesture.location(in:self).x)
            case .changed:if active===gesture{configuration?.onChange(location.x-origin.x)}
            case .ended:if active===gesture{active=nil;configuration?.onEnd(location.x-origin.x)}
            case .cancelled,.failed:if active===gesture{active=nil;configuration?.onCancel()}
            default:break
            }
        }
        func cancelActive(){if active != nil{active=nil;configuration?.onCancel()}}
    }
}

/// Adds a native pinch to the existing horizontal scroll view. The time under
/// the fingers stays anchored rather than jumping to the leading edge.
@MainActor struct MediaV2TimelinePinchBridge:UIViewRepresentable {
    @Binding var zoom:Double
    func makeUIView(context:Context)->Anchor{let view=Anchor();view.setZoom={zoom=$0};view.getZoom={zoom};return view}
    func updateUIView(_ uiView:Anchor,context:Context){uiView.setZoom={zoom=$0};uiView.getZoom={zoom}}
    static func dismantleUIView(_ uiView:Anchor,coordinator:()){uiView.detach()}
    final class Anchor:UIView,UIGestureRecognizerDelegate{
        var setZoom:((Double)->Void)?
        var getZoom:(()->Double)?
        weak var scroll:UIScrollView?
        private var recognizer:UIPinchGestureRecognizer?
        private var originalZoom=1.0,anchorTime=0.0,anchorX=0.0
        private var generation=UUID()
        override func didMoveToWindow(){super.didMoveToWindow();attach()}
        override func layoutSubviews(){super.layoutSubviews();attach()}
        private func attach(){
            guard recognizer==nil,window != nil else{return};var ancestor=superview
            while let view=ancestor{if let candidate=view as? UIScrollView{scroll=candidate;let pinch=UIPinchGestureRecognizer(target:self,action:#selector(changed(_:)));pinch.delegate=self;candidate.addGestureRecognizer(pinch);recognizer=pinch;return};ancestor=view.superview}
        }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer:UIGestureRecognizer)->Bool{true}
        @objc private func changed(_ gesture:UIPinchGestureRecognizer){
            guard let scroll else{return}
            if gesture.state == .began{
                cancelEdits(in:scroll)
                generation=UUID();originalZoom=getZoom?() ?? 1;anchorX=Double(gesture.location(in:scroll).x-scroll.bounds.minX)
                anchorTime=(Double(scroll.contentOffset.x)+anchorX)/MediaTimelineViewportMath.scale(zoom:originalZoom)
                scroll.panGestureRecognizer.isEnabled=false
            }
            if gesture.state == .began || gesture.state == .changed{
                let value=min(6,max(0.5,originalZoom*Double(gesture.scale))),token=generation
                setZoom?(value)
                DispatchQueue.main.async{[weak self,weak scroll] in
                    guard let self,let scroll,self.generation==token else{return};scroll.layoutIfNeeded()
                    let x=MediaTimelineViewportMath.anchoredOffset(time:self.anchorTime,viewportX:self.anchorX,zoom:value,contentWidth:Double(scroll.contentSize.width),viewportWidth:Double(scroll.bounds.width))
                    scroll.setContentOffset(.init(x:x,y:scroll.contentOffset.y),animated:false)
                }
            }
            if [.ended,.cancelled,.failed].contains(gesture.state){scroll.panGestureRecognizer.isEnabled=true}
        }
        private func cancelEdits(in view:UIView){
            if let surface=view as? MediaV2TimelineTouchSurface.Surface{surface.cancelActive()}
            for child in view.subviews{cancelEdits(in:child)}
        }
        func detach(){generation=UUID();if let recognizer{scroll?.removeGestureRecognizer(recognizer)};scroll?.panGestureRecognizer.isEnabled=true;recognizer=nil}
    }
}
#endif
