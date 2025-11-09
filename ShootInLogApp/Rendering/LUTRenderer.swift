import AVFoundation
import CoreVideo
import Metal
import MetalKit
import simd

/// Performs real-time LUT processing using Metal and drives the preview.
final class LUTRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var computePSO: MTLComputePipelineState!
    private var blitRenderPSO: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!

    // Current LUT
    private var lutTexture: MTLTexture?
    private var lutSize: Int = 0
    var lutMode: LUTMode = .off
    var lutIntensity: Float = 1.0

    // Preview target
    weak var previewView: MTKView?
    private var previewTexture: MTLTexture?

    init?(previewView: MTKView? = nil) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.commandQueue = q
        super.init()
        self.previewView = previewView
        if let v = self.previewView {
            v.device = dev
            v.framebufferOnly = false
            v.isPaused = false
            v.enableSetNeedsDisplay = false
            v.preferredFramesPerSecond = 30
            v.delegate = self
        }

        guard let lib = try? dev.makeDefaultLibrary(bundle: .main),
              let computeFunc = lib.makeFunction(name: "applyLUT"),
              let vtx = lib.makeFunction(name: "vertexPassthrough"),
              let frag = lib.makeFunction(name: "fragmentTextured") else { return nil }
        do {
            computePSO = try dev.makeComputePipelineState(function: computeFunc)

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtx
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = self.previewView?.colorPixelFormat ?? .bgra8Unorm
            blitRenderPSO = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &textureCache)
    }

    func setPreviewView(_ v: MTKView) {
        previewView = v
        v.device = device
        v.framebufferOnly = false
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.preferredFramesPerSecond = 30
        v.delegate = self
    }

    func loadLUTIfNeeded(for mode: LUTMode) {
        guard mode != .off else { self.lutTexture = nil; self.lutSize = 0; self.lutMode = .off; return }
        if let _ = lutTexture, lutMode == mode { return }
        let primaryName = (mode == .subject) ? "Subject" : "Scenery"
        let fallbackNames = (mode == .subject) ? ["subject"] : ["Scenery", "Sceneray", "scenery", "sceneray"]

        func attemptLoad(_ name: String) -> Bool {
            do {
                let (tex, size) = try LUT3DLoader.loadCubeTexture(device: device, resourceName: name)
                self.lutTexture = tex
                self.lutSize = size
                return true
            } catch { return false }
        }

        var loaded = attemptLoad(primaryName)
        if !loaded {
            for alt in fallbackNames where !loaded { loaded = attemptLoad(alt) }
        }
        if !loaded { self.lutTexture = nil; self.lutSize = 0 }
        self.lutMode = mode
    }

    /// Process a frame asynchronously; calls completion when GPU work finished.
    func processAsync(sampleBuffer: CMSampleBuffer, mode: LUTMode, completion: @escaping (CVPixelBuffer, CMTime) -> Void) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        self.loadLUTIfNeeded(for: mode)

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)

        var srcTexRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &srcTexRef)
        guard let srcTex = srcTexRef.flatMap({ CVMetalTextureGetTexture($0) }) else { return }

        // Destination PB for recording
        var dstPB: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &dstPB)
        guard let outPB = dstPB else { return }

        var dstTexRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, outPB, nil, .bgra8Unorm, w, h, 0, &dstTexRef)
        guard let dstTex = dstTexRef.flatMap({ CVMetalTextureGetTexture($0) }) else { return }

        ensurePreviewTexture(width: w, height: h)

        guard let cmd = commandQueue.makeCommandBuffer() else { return }
        // Compute LUT onto dstTex
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(computePSO)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(dstTex, index: 1)
            enc.setTexture(lutTexture, index: 2)
            var lutMeta = vector_float2(Float(lutSize), lutIntensity)
            enc.setBytes(&lutMeta, length: MemoryLayout<vector_float2>.size, index: 0)
            let wtg = MTLSize(width: 16, height: 16, depth: 1)
            let ntg = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
            enc.dispatchThreadgroups(ntg, threadsPerThreadgroup: wtg)
            enc.endEncoding()
        }

        // Copy processed frame to preview texture for MTKView delegate to draw
        if let previewTex = previewTexture, let blit = cmd.makeBlitCommandEncoder() {
            let size = MTLSize(width: w, height: h, depth: 1)
            blit.copy(from: dstTex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: size, to: previewTex, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }

        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        cmd.addCompletedHandler { [weak self] _ in
            guard self != nil else { return }
            completion(outPB, ts)
        }
        cmd.commit()
    }

    private func ensurePreviewTexture(width: Int, height: Int) {
        if let tex = previewTexture, tex.width == width && tex.height == height { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        previewTexture = device.makeTexture(descriptor: desc)
    }

    // MARK: - MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        guard let previewTex = previewTexture,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(blitRenderPSO)
        // Fullscreen quad
        let verts: [Float] = [
            -1, -1, 0, 1,
            1, -1, 1, 1,
            -1, 1, 0, 0,
            1, 1, 1, 0
        ]
        enc.setVertexBytes(verts, length: MemoryLayout<Float>.size * verts.count, index: 0)
        enc.setFragmentTexture(previewTex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.commit() // MTKView presents automatically
    }
}
