// SnailSight 12.27 Scan view renderer: the live coloured point cloud (SnailSightCore ScanCloud) drawn with Metal.
//  - AR: RealityKit's post-process callback (ARView.renderCallbacks.postProcess) copies the rendered frame to the target
//    and draws the points over it at the display rate (60 fps; the points are one draw call).
//  - Paused: ScanOrbitView (MTKView) draws the same buffer with an orbit camera.
// Two shared vertex buffers: the cloud queue writes the back one and swaps (≥ 150 ms apart, far beyond a GPU frame).
import Metal
import MetalKit
import RealityKit
import simd
import SnailSightCore

struct ScanCloudUniforms {
    var viewProj: simd_float4x4
    var view: simd_float4x4
    var pointScale: Float
    var minSize: Float
    var maxSize: Float
    var alpha: Float
}

final class ScanCloudRenderer {
    let device: MTLDevice?
    private var library: MTLLibrary?
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var depthState: MTLDepthStencilState?
    private var depthTex: MTLTexture?
    private let lock = NSLock()
    private var buffers: [MTLBuffer?] = [nil, nil]
    private var front = 0
    private var frontCount = 0
    private var capacity = [0, 0]
    // AR camera (main → render thread)
    private var view = matrix_identity_float4x4
    private(set) var renderFailed: String?
    /// Draw in AR (Scan view on, the orbit view not open).
    var drawInAR = false
    var arAlpha: Float = 1

    init() {
        device = MTLCreateSystemDefaultDevice()
        library = device?.makeDefaultLibrary()
        if let d = device {
            let ds = MTLDepthStencilDescriptor()
            ds.depthCompareFunction = .less
            ds.isDepthWriteEnabled = true
            depthState = d.makeDepthStencilState(descriptor: ds)
        }
    }

    /// Bytes held by the GPU copies (the `mb_scan_cloud` line adds this to the CPU estimate).
    var gpuBytes: Int { lock.lock(); defer { lock.unlock() }; return buffers.reduce(0) { $0 + ($1?.length ?? 0) } }
    var count: Int { lock.lock(); defer { lock.unlock() }; return frontCount }

    // MARK: upload (cloud queue)

    /// Writes the cloud into the back buffer (grown to fit, capped at `maxPoints`) and makes it the front one.
    func upload(_ cloud: ScanCloud, maxPoints: Int, faintAlpha: UInt8) {
        guard let d = device else { return }
        lock.lock()
        let back = 1 - front
        lock.unlock()
        let want = min(maxPoints, cloud.count)
        if want == 0 {
            lock.lock(); frontCount = 0; buffers = [nil, nil]; capacity = [0, 0]; lock.unlock()
            return
        }
        var buf = buffers[back]
        if buf == nil || capacity[back] < want || capacity[back] > max(want * 2, 65_536) {
            let cap = min(maxPoints, max(65_536, Int(Double(want) * 1.25)))
            buf = d.makeBuffer(length: cap * ScanCloud.vertexStride, options: .storageModeShared)
            capacity[back] = buf == nil ? 0 : cap
        }
        guard let b = buf else { return }
        let n = cloud.export(into: b.contents(), capacity: capacity[back], faintAlpha: faintAlpha)
        lock.lock()
        buffers[back] = b
        front = back
        frontCount = n
        lock.unlock()
    }

    func clear() {
        lock.lock(); buffers = [nil, nil]; capacity = [0, 0]; frontCount = 0; lock.unlock()
    }

    /// The AR camera's view matrix for the next rendered frame (main thread, per ARFrame).
    func setARView(_ cameraToWorld: simd_float4x4) {
        let v = cameraToWorld.inverse
        lock.lock(); view = v; lock.unlock()
    }

    // MARK: pipelines

    private func pipeline(color: MTLPixelFormat, depth: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = "\(color.rawValue)/\(depth.rawValue)"
        if let p = pipelines[key] { return p }
        guard let d = device, let lib = library,
              let vf = lib.makeFunction(name: "scanCloudVertex"), let ff = lib.makeFunction(name: "scanCloudFragment") else {
            renderFailed = "no shader"
            return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.colorAttachments[0].pixelFormat = color
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pd.depthAttachmentPixelFormat = depth
        do {
            let p = try d.makeRenderPipelineState(descriptor: pd)
            pipelines[key] = p
            return p
        } catch {
            renderFailed = "pipeline: \(error.localizedDescription)"
            return nil
        }
    }

    /// Encode the points (one draw call) into an open render encoder.
    func encode(_ enc: MTLRenderCommandEncoder, color: MTLPixelFormat, depth: MTLPixelFormat, uniforms: ScanCloudUniforms) {
        lock.lock()
        let buf = buffers[front], n = frontCount
        lock.unlock()
        guard n > 0, let buf, let p = pipeline(color: color, depth: depth) else { return }
        var u = uniforms
        enc.setRenderPipelineState(p)
        if let ds = depthState { enc.setDepthStencilState(ds) }
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<ScanCloudUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: n)
    }

    // MARK: AR post-process

    /// RealityKit post-process: copy the frame, then the points over it (own depth buffer: points occlude points).
    func postProcess(_ ctx: ARView.PostProcessContext) {
        let src = ctx.sourceColorTexture, dst = ctx.targetColorTexture
        if let blit = ctx.commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: src, to: dst)
            blit.endEncoding()
        }
        guard drawInAR, count > 0, renderFailed == nil else { return }
        guard dst.usage.contains(.renderTarget) else { renderFailed = "target not renderable"; return }
        if depthTex == nil || depthTex!.width != dst.width || depthTex!.height != dst.height {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: dst.width, height: dst.height,
                                                              mipmapped: false)
            td.usage = .renderTarget
            td.storageMode = .memoryless
            depthTex = ctx.device.makeTexture(descriptor: td)
        }
        guard let dt = depthTex else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = dst
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = dt
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.storeAction = .dontCare
        rp.depthAttachment.clearDepth = 1
        guard let enc = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        lock.lock()
        let v = view
        lock.unlock()
        let scale = Float(dst.height) / 900                              // ~4 px at 1 m on a phone-size target
        let u = ScanCloudUniforms(viewProj: ctx.projection * v, view: v, pointScale: 5 * scale,
                                  minSize: 1.5 * scale, maxSize: 9 * scale, alpha: arAlpha)
        encode(enc, color: dst.pixelFormat, depth: .depth32Float, uniforms: u)
        enc.endEncoding()
    }

    // MARK: matrices (orbit view)

    static func perspective(fovyRad: Float, aspect: Float, near n: Float, far f: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovyRad / 2), xs = ys / aspect, zs = f / (n - f)
        return simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * n, 0)))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
                                       SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
    }
}
