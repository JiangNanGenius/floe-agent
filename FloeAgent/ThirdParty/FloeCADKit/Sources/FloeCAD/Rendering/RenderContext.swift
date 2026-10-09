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
    /// bundle. FloeCAD is delivered as a Swift package library: the host app
    /// ALSO ships its own `default.metallib` with unrelated functions, so
    /// `device.makeDefaultLibrary()` must never be preferred — selecting it
    /// produced a pipeline-less viewport (CUA crash 2026-10-10, SIGTRAP in
    /// `ViewportCoordinator.attach`). The package source is compiled once per
    /// process; a default library is only accepted when it validates against
    /// the exact function set this package needs.
    private static let compiledLibraryLock = NSLock()
    private static var compiledLibrary: MTLLibrary?

    /// Every shader function `PipelineStore` builds a pipeline from. A library
    /// missing any of these cannot render the viewport and must be rejected
    /// before pipelines are created (so the caller can surface a recoverable
    /// error instead of crashing).
    static let requiredFunctionNames = [
        "vertex_fullscreen", "fragment_backgroundGradient",
        "vertex_lit", "fragment_lit",
        "vertex_litTextured", "fragment_litTextured",
        "vertex_unlit", "fragment_flatColor",
        "vertex_edge", "fragment_flatColorClipped",
        "vertex_thickLine", "fragment_flatColorClipped",
        "vertex_grid", "fragment_grid",
        "vertex_texturedQuad", "fragment_texturedQuad",
        "vertex_texturedQuad", "fragment_blobShadow",
    ]

    static func libraryValidates(_ library: MTLLibrary) -> Bool {
        for name in Set(requiredFunctionNames) where library.makeFunction(name: name) == nil {
            return false
        }
        return true
    }

    private static func makeLibrary(device: MTLDevice) -> MTLLibrary? {
        compiledLibraryLock.lock()
        defer { compiledLibraryLock.unlock() }
        if let compiledLibrary, compiledLibrary.device === device {
            return compiledLibrary
        }
        let library = packageLibrary(device: device)
        compiledLibrary = library
        return library
    }

    private static func packageLibrary(device: MTLDevice) -> MTLLibrary? {
        // 1. The package's own shader source (the only library guaranteed to
        //    carry this package's function set). The shared header is inlined
        //    because `makeLibrary(source:)` has no include search paths.
        if let metalURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal",
                                            subdirectory: "Shaders"),
           var source = try? String(contentsOf: metalURL, encoding: .utf8) {
            if let headerURL = Bundle.module.url(forResource: "ShaderTypes", withExtension: "h",
                                                 subdirectory: "Shaders"),
               let header = try? String(contentsOf: headerURL, encoding: .utf8) {
                source = source.replacingOccurrences(of: "#include \"ShaderTypes.h\"",
                                                     with: header)
            }
            do {
                let library = try device.makeLibrary(source: source, options: nil)
                if libraryValidates(library) {
                    lastLibraryError = nil
                    return library
                }
                lastLibraryError = "compiled shader library is missing required functions"
            } catch {
                lastLibraryError = error.localizedDescription
            }
        } else {
            lastLibraryError = "package Shaders.metal resource not found"
        }
        // 2. A host-compiled default library is acceptable ONLY when it really
        //    contains the functions (some embedding builds compile package
        //    resources into the app metallib).
        if let defaultLibrary = device.makeDefaultLibrary(), libraryValidates(defaultLibrary) {
            lastLibraryError = nil
            return defaultLibrary
        }
        if lastLibraryError == nil {
            lastLibraryError = "default metallib does not contain the CAD shader functions"
        }
        return nil
    }

    /// Last shader-library failure detail (shown in the recoverable viewport
    /// error and asserted by the render tests). Never a crash path.
    nonisolated(unsafe) private(set) static var lastLibraryError: String?
}
