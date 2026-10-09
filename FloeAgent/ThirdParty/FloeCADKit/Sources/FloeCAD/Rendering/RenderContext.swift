//
//  RenderContext.swift
//  openshape3d
//

import Foundation
import Metal
import MetalKit

/// Long-lived Metal objects shared by all render passes.
final class RenderContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    let pipelines: PipelineStore

    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    static let depthPixelFormat: MTLPixelFormat = .depth32Float
    /// MSAA samples, from Settings (1/2/4). Read once at launch — pipelines
    /// bake the sample count, so changing the setting applies next launch.
    static let sampleCount = CADPreferences.launchSampleCount()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = Self.makeLibrary(device: device)
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.library = library
        guard let pipelines = PipelineStore(device: device, library: library) else { return nil }
        self.pipelines = pipelines
    }

    func configure(view: MTKView) {
        view.device = device
        view.colorPixelFormat = Self.colorPixelFormat
        view.depthStencilPixelFormat = Self.depthPixelFormat
        view.sampleCount = Self.sampleCount
        view.clearColor = MTLClearColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        view.clearDepth = 1.0
        view.enableSetNeedsDisplay = true
        view.isPaused = true
    }

    /// Compile the Metal shader source shipped in the package resource
    /// bundle. FloeCAD is delivered as a Swift package library, so there is
    /// no app `default.metallib` to fall back to when built outside the Floe
    /// app; compile once per process and cache.
    private static let compiledLibraryLock = NSLock()
    private static var compiledLibrary: MTLLibrary?

    private static func makeLibrary(device: MTLDevice) -> MTLLibrary? {
        if let defaultLibrary = device.makeDefaultLibrary() {
            return defaultLibrary
        }
        compiledLibraryLock.lock()
        defer { compiledLibraryLock.unlock() }
        if let compiledLibrary, compiledLibrary.device === device {
            return compiledLibrary
        }
        guard let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal",
                                          subdirectory: "Shaders"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let library = try? device.makeLibrary(source: source, options: nil)
        compiledLibrary = library
        return library
    }
}
