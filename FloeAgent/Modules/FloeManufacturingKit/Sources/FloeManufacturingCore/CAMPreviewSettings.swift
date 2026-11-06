// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum CAMCameraPreset:String,Codable,CaseIterable,Sendable { case isometric,top,front,right }
public enum CAMPathVisibility:String,Codable,CaseIterable,Sendable { case all,selected,hidden }
public enum CAMObjectVisibility:String,Codable,CaseIterable,Sendable { case solid,translucent,hidden }
public enum CAMDisplayScope:String,Codable,CaseIterable,Sendable { case machining,machine }

/// Display preferences only. Hiding/transparency never changes query geometry,
/// toolpaths, stock occupancy or the underlying source/result identity.
public struct CAMPreviewSettings:Codable,Equatable,Sendable {
    public var position = 0.0
    public var speed = 1.0
    public var selectedChapterID:String?
    public var selectedOnly = false
    public var paths = CAMPathVisibility.selected
    public var showStock = true
    public var showTools = true
    public var showSpindles = true
    public var showFixtures = true
    public var showHead = true
    public var translucentStock = false
    public var smooth = true
    public var camera = CAMCameraPreset.isometric
    public var displayScope = CAMDisplayScope.machining
    public var spindleDisplay = CAMObjectVisibility.translucent
    public var holderDisplay = CAMObjectVisibility.solid
    public var workholdingDisplay = CAMObjectVisibility.translucent
    public var structureDisplay = CAMObjectVisibility.hidden
    public var transparency = 0.65
    public init() {}
    public mutating func applyScope(_ scope:CAMDisplayScope) {
        displayScope = scope;showSpindles = true;showHead = true
        structureDisplay = scope == .machining ? .hidden : .translucent
        spindleDisplay = scope == .machining ? .translucent : .solid
        workholdingDisplay = scope == .machining ? .translucent : .solid
        holderDisplay = .solid
    }
    public func opacity(_ display:CAMObjectVisibility)->Double {
        switch display { case .solid:1;case .translucent:1-max(0,min(1,transparency));case .hidden:0 }
    }
    private enum CodingKeys:String,CodingKey {
        case position,speed,selectedChapterID,selectedOnly,paths,showStock,showTools,showSpindles,showFixtures,showHead,translucentStock,smooth,camera
        case displayScope,spindleDisplay,holderDisplay,workholdingDisplay,structureDisplay,transparency
    }
    public init(from decoder:Decoder) throws {
        self.init();let c = try decoder.container(keyedBy:CodingKeys.self)
        position = try c.decodeIfPresent(Double.self,forKey:.position) ?? position
        speed = try c.decodeIfPresent(Double.self,forKey:.speed) ?? speed
        selectedChapterID = try c.decodeIfPresent(String.self,forKey:.selectedChapterID)
        selectedOnly = try c.decodeIfPresent(Bool.self,forKey:.selectedOnly) ?? selectedOnly
        paths = try c.decodeIfPresent(CAMPathVisibility.self,forKey:.paths) ?? paths
        showStock = try c.decodeIfPresent(Bool.self,forKey:.showStock) ?? showStock
        showTools = try c.decodeIfPresent(Bool.self,forKey:.showTools) ?? showTools
        showSpindles = try c.decodeIfPresent(Bool.self,forKey:.showSpindles) ?? showSpindles
        showFixtures = try c.decodeIfPresent(Bool.self,forKey:.showFixtures) ?? showFixtures
        showHead = try c.decodeIfPresent(Bool.self,forKey:.showHead) ?? showHead
        translucentStock = try c.decodeIfPresent(Bool.self,forKey:.translucentStock) ?? translucentStock
        smooth = try c.decodeIfPresent(Bool.self,forKey:.smooth) ?? smooth
        camera = try c.decodeIfPresent(CAMCameraPreset.self,forKey:.camera) ?? camera
        displayScope = try c.decodeIfPresent(CAMDisplayScope.self,forKey:.displayScope) ?? .machining
        spindleDisplay = try c.decodeIfPresent(CAMObjectVisibility.self,forKey:.spindleDisplay) ?? (showHead ? .translucent:.hidden)
        holderDisplay = try c.decodeIfPresent(CAMObjectVisibility.self,forKey:.holderDisplay) ?? (showHead ? .solid:.hidden)
        workholdingDisplay = try c.decodeIfPresent(CAMObjectVisibility.self,forKey:.workholdingDisplay) ?? (showSpindles ? .translucent:.hidden)
        structureDisplay = try c.decodeIfPresent(CAMObjectVisibility.self,forKey:.structureDisplay) ?? .hidden
        transparency = try c.decodeIfPresent(Double.self,forKey:.transparency) ?? transparency
        guard position.isFinite,speed.isFinite,transparency.isFinite,(0...0.95).contains(transparency) else { throw ManufacturingError.archive("preview display settings") }
    }
}
