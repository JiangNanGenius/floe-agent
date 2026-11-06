// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
@preconcurrency import SceneKit
import FloeManufacturingCore

@MainActor enum CAMSceneDisplay {
    enum Component:String { case cutting,holder,spindle,workholding,structure }
    private static let components = NSMapTable<SCNNode,NSString>(keyOptions:.weakMemory,valueOptions:.strongMemory)
    @discardableResult static func tag(_ node:SCNNode,_ component:Component)->SCNNode {
        components.setObject(component.rawValue as NSString,forKey:node);return node
    }
    static func visibility(_ component:Component,_ settings:CAMPreviewSettings)->CAMObjectVisibility {
        switch component { case .cutting:.solid;case .holder:settings.holderDisplay;case .spindle:settings.spindleDisplay;case .workholding:settings.workholdingDisplay;case .structure:settings.structureDisplay }
    }
    static func apply(_ root:SCNNode,default component:Component,settings:CAMPreviewSettings) {
        func visit(_ node:SCNNode,_ inherited:Component) {
            let selected = components.object(forKey:node).flatMap { Component(rawValue:$0 as String) } ?? inherited
            if node.geometry != nil { let display = visibility(selected,settings);node.isHidden = display == .hidden;node.opacity = settings.opacity(display) }
            for child in node.childNodes { visit(child,selected) }
        }
        visit(root,component)
    }
    /// Bounds of visible geometry only. Hidden beds/columns must not force the
    /// machining area to shrink; display opacity never affects query bodies.
    static func fittingPoints(_ root:SCNNode)->[SCNVector3] {
        var points = [SCNVector3]()
        func visit(_ node:SCNNode) {
            guard !node.isHidden,node.opacity>0.01 else { return }
            if let geometry = node.geometry {
                let (lo,hi) = geometry.boundingBox
                for x in [lo.x,hi.x] { for y in [lo.y,hi.y] { for z in [lo.z,hi.z] { points.append(node.convertPosition(.init(x,y,z),to:root)) } } }
            }
            for child in node.childNodes { visit(child) }
        }
        visit(root);return points
    }
}
#endif
