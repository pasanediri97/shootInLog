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
               preferredCodec: AVVideoCodecType = .hevc) throws {
        _ = isFrontCamera // reserved for future mirroring logic
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("log_record_\(UUID().uuidString).mov")
        fileURL = temp
        let writer = try AVAssetWriter(url: temp, fileType: .mov)

        // Video settings
        let width = Int(resolution.width)
        let height = Int(resolution.height)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: preferredCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        // Prefer wide color properties
        videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ]
        videoSettings[AVVideoCompressionPropertiesKey] = [
            AVVideoAverageBitRateKey: 60_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelHEVCMain10AutoLevel,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoMaxKeyFrameIntervalKey: 30
        ]

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        currentOrientation = orientation
        vIn.transform = transform(for: orientation)
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

    private func transform(for orientation: AVCaptureVideoOrientation) -> CGAffineTransform {
        let transform: CGAffineTransform
        switch orientation {
        case .portrait:
            transform = CGAffineTransform(rotationAngle: .pi / 2)
        case .portraitUpsideDown:
            transform = CGAffineTransform(rotationAngle: -.pi / 2)
        case .landscapeLeft:
            transform = CGAffineTransform(rotationAngle: .pi)
        case .landscapeRight:
            transform = .identity
        @unknown default:
            transform = .identity
        }
        return transform
    }

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
