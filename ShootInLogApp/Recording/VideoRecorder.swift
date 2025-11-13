import AVFoundation
import Photos

/// Records processed video frames (and pass-through audio) into a single movie file then saves to Photos.
final class VideoRecorder {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?

    private var startTime: CMTime?
    private var fileURL: URL?
    private var currentOrientation: AVCaptureVideoOrientation = .portrait

    var onSavedToPhotos: ((Bool, Error?) -> Void)?

    func start(resolution: CGSize,
               orientation: AVCaptureVideoOrientation,
               isFrontCamera: Bool,
               preferredCodec: AVVideoCodecType = .proRes422HQ) throws {
        _ = isFrontCamera // reserved for future mirroring logic
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("log_record_\(UUID().uuidString).mov")
        fileURL = temp
        let writer = try AVAssetWriter(url: temp, fileType: .mov)

        // Video settings for Apple Log with ProRes
        let width = Int(resolution.width)
        let height = Int(resolution.height)
        
        // Use ProRes 422 HQ for Log recording
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: preferredCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        
        // Configure for Apple Log color space and transfer function
        // Using HLG (Hybrid Log-Gamma) which is the standard for Apple Log
        videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG, // Apple Log uses HLG
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ]
        
        // ProRes compression settings
        // Note: ProRes is an intra-frame codec, so many H.264 properties don't apply
        // Only set properties that ProRes actually supports
        if preferredCodec == .proRes422HQ || preferredCodec == .proRes4444 {
            // ProRes doesn't need compression properties - it's already optimized
            // Don't set MaxKeyFrameInterval, ProfileLevel, etc. as they're H.264-specific
        } else {
            // For other codecs like HEVC/H.264, set compression properties
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: 60_000_000,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        }

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        currentOrientation = orientation
        // Don't apply transform - save video in natural camera orientation
        // This prevents aspect ratio issues and "shrinked" appearance
        vIn.transform = .identity
        if writer.canAdd(vIn) { writer.add(vIn) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])

        // Audio
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        aIn.expectsMediaDataInRealTime = true
        if writer.canAdd(aIn) { writer.add(aIn) }

        self.assetWriter = writer
        self.videoInput = vIn
        self.pixelAdaptor = adaptor
        self.audioInput = aIn
        self.startTime = nil
    }

    func appendVideo(pixelBuffer: CVPixelBuffer, with time: CMTime) {
        guard let writer = assetWriter, let vIn = videoInput, let adaptor = pixelAdaptor else { return }
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: time)
        }
        if startTime == nil { startTime = time }
        if vIn.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        guard let writer = assetWriter else { return }
        
        // Only append audio after the session has started
        // Audio samples often arrive before video, so we need to check writer status
        guard writer.status == .writing else {
            // Session hasn't started yet (waiting for first video frame)
            return
        }
        
        guard let aIn = audioInput, aIn.isReadyForMoreMediaData else { return }
        aIn.append(sampleBuffer)
    }

    func stopAndSaveToPhotos() {
        guard let writer = assetWriter else { return }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            if let url = self.fileURL {
                self.saveToPhotos(url: url)
            } else {
                self.onSavedToPhotos?(false, nil)
            }
            self.assetWriter = nil
            self.videoInput = nil
            self.audioInput = nil
            self.pixelAdaptor = nil
        }
    }

    // Transform removed - videos are saved in their natural camera orientation
    // to prevent aspect ratio issues

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.onSavedToPhotos?(false, nil)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .video, fileURL: url, options: nil)
            }) { success, err in
                self.onSavedToPhotos?(success, err)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
