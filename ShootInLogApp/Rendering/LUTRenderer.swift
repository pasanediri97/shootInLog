import AVFoundation
import CoreVideo
import Metal
import MetalKit
import simd

/// Performs real-time LUT processing using Metal and drives the preview.
final class LUTRenderer {
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

    init?(previewView: MTKView? = nil) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.commandQueue = q
        self.previewView = previewView
        self.previewView?.device = dev
        self.previewView?.framebufferOnly = false
        self.previewView?.isPaused = true
        self.previewView?.enableSetNeedsDisplay = true

        let lib = try? dev.makeDefaultLibrary(bundle: .main)
        do {
            let computeFunc = lib?.makeFunction(name: "applyLUT")
            computePSO = try dev.makeComputePipelineState(function: computeFunc!)

            let vtx = lib?.makeFunction(name: "vertexPassthrough")
            let frag = lib?.makeFunction(name: "fragmentTextured")
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtx
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = previewView?.colorPixelFormat ?? .bgra8Unorm
            blitRenderPSO = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &textureCache)
    }

    func setPreviewView(_ v: MTKView) {
        previewView = v
        previewView?.device = device
        previewView?.framebufferOnly = false
        previewView?.isPaused = true
        previewView?.enableSetNeedsDisplay = true
    }

    func loadLUTIfNeeded(for mode: LUTMode) {
        guard mode != .off else { self.lutTexture = nil; self.lutSize = 0; return }
        let name = mode == .subject ? "Subject" : "Scenery"
        if let tex = lutTexture, lutMode == mode { return }
        do {
            let (tex, size) = try LUT3DLoader.loadCubeTexture(device: device, resourceName: name)
            self.lutTexture = tex
            self.lutSize = size
        } catch {
            self.lutTexture = nil
            self.lutSize = 0
        }
        self.lutMode = mode
    }

    /// Process a frame into a BGRA pixel buffer (used for recording) and also draw to the preview.
    func process(sampleBuffer: CMSampleBuffer, mode: LUTMode) -> CVPixelBuffer? {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        self.loadLUTIfNeeded(for: mode)

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)

        var srcTexRef: CVMetalTexture?
        let srcFmt = MTLPixelFormat.bgra8Unorm
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, srcFmt, w, h, 0, &srcTexRef)
        guard let srcTex = srcTexRef.flatMap({ CVMetalTextureGetTexture($0) }) else { return nil }

        // Create destination pixel buffer for recording
        var dstPB: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &dstPB)
        guard let outPB = dstPB else { return nil }

        var dstTexRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, outPB, nil, .bgra8Unorm, w, h, 0, &dstTexRef)
        guard let dstTex = dstTexRef.flatMap({ CVMetalTextureGetTexture($0) }) else { return nil }

        guard let cmd = commandQueue.makeCommandBuffer() else { return nil }
        // Compute pass: apply LUT from srcTex to dstTex
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

        // Preview blit: draw dstTex into drawable if present
        if let view = previewView, let drawable = view.currentDrawable {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(blitRenderPSO)
                // Fullscreen tri-strip quad
                let verts: [Float] = [
                    -1, -1, 0, 1,
                    1, -1, 1, 1,
                    -1, 1, 0, 0,
                    1, 1, 1, 0
                ]
                enc.setVertexBytes(verts, length: MemoryLayout<Float>.size*verts.count, index: 0)
                enc.setFragmentTexture(dstTex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
            cmd.present(drawable)
        }

        cmd.commit()
        cmd.waitUntilCompleted() // ensure dstPB finished before returning for writer
        return outPB
    }
}
