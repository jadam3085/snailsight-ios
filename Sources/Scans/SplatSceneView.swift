// 9.6 Scans viewer, Splat mode: native Metal Gaussian splats with MetalSplatter (MIT, github.com/scier/MetalSplatter,
// pinned 1.0.1). Source = the server's phone splat (`splat_mobile.splat`, antimatter15 32-byte records, map frame Z-up,
// ordered most-important-first) cut to a device budget (SnailSightCore.SplatBudget: 1.5 M on 8 GB phones, less when
// os_proc_available_memory is short). Records are decoded straight into MetalSplatter's GPU buffer (no intermediate
// SplatPoint array). The camera is the shared ViewerCamera (Y-up); the splat's map frame is turned Y-up in the view
// matrix (ScanFrames.mapToYUpMatrix), so it lines up with the mesh.
import SwiftUI
import MetalKit
import MetalSplatter
import SplatIO
import SnailSightCore

final class SplatSceneRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let camera: ViewerCamera
    private var renderer: SplatRenderer?
    private var drawableSize: CGSize = .zero
    private let inFlight = DispatchSemaphore(value: 3)
    private(set) var splatCount = 0

    init?(camera: ViewerCamera) {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        device = d
        queue = q
        self.camera = camera
    }

    func configure(_ v: MTKView) {
        v.device = device
        v.colorPixelFormat = .bgra8Unorm_srgb
        v.depthStencilPixelFormat = .depth32Float
        v.sampleCount = 1
        v.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        v.preferredFramesPerSecond = 60
        v.delegate = self
    }

    /// Load `count` records of a .splat file into the GPU (call off the main thread).
    func load(url: URL, count: Int, colorFormat: MTLPixelFormat = .bgra8Unorm_srgb,
              depthFormat: MTLPixelFormat = .depth32Float) async throws {
        let r = try SplatRenderer(device: device, colorFormat: colorFormat, depthFormat: depthFormat, sampleCount: 1,
                                  maxViewCount: 1, maxSimultaneousRenders: 3,
                                  clearColor: MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1))
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let n = min(count, data.count / DotSplatRecord.byteWidth)
        guard n > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let buf = try MetalBuffer<EncodedSplatPoint>(device: device, capacity: n)
        buf.count = n
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            for i in 0..<n {
                let rec = DotSplatRecord.decode(base + i * DotSplatRecord.byteWidth)
                buf.values[i] = EncodedSplatPoint(position: rec.position, colorSH0: rec.sh0, opacity: rec.opacity,
                                                  scale: rec.scale, rotation: rec.rotation)
            }
        }
        await r.addChunk(SplatChunk(splats: buf))
        renderer = r
        splatCount = n
    }

    func unload() {
        renderer = nil
        splatCount = 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { drawableSize = size }

    func draw(in view: MTKView) {
        guard let r = renderer, r.isReadyToRender, drawableSize.width > 0, drawableSize.height > 0,
              let drawable = view.currentDrawable else { return }
        _ = inFlight.wait(timeout: .distantFuture)
        guard let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        let aspect = Float(drawableSize.width / drawableSize.height)
        let proj = CameraMath.perspective(fovyRadians: camera.fovy, aspect: aspect, near: 0.03, far: 300)
        let vp = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1),
            projectionMatrix: proj,
            viewMatrix: camera.viewMatrix * ScanFrames.mapToYUpMatrix,
            screenSize: SIMD2(Int(drawableSize.width), Int(drawableSize.height)))
        let ok = (try? r.render(viewports: [vp], colorTexture: view.multisampleColorTexture ?? drawable.texture,
                                colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
                                depthTexture: view.depthStencilTexture, rasterizationRateMap: nil,
                                renderTargetArrayLength: 0, to: cb)) ?? false
        if ok { cb.present(drawable) }
        cb.commit()
    }
}

struct SplatSceneView: UIViewRepresentable {
    let renderer: SplatSceneRenderer
    let camera: ViewerCamera

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero)
        renderer.configure(v)
        camera.attach(to: v)
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {}

    static func dismantleUIView(_ v: MTKView, coordinator: ()) {
        v.isPaused = true
        v.delegate = nil
    }
}
