import AVFoundation
import Combine
import MetalKit
import SwiftUI

final class CameraViewModel: NSObject, ObservableObject, CaptureManager.FrameConsumer {
    @Published var lutMode: LUTMode = .off
    @Published var isRecording: Bool = false
    @Published var isLogCompatible: Bool = false
    @Published var resolutionText: String = ""
    @Published var showInfo: Bool = false
    @Published var permissionMessage: String?
    @Published var usingFrontCamera: Bool = false
    @Published var orientation: AVCaptureVideoOrientation = .portrait

    let capture = CaptureManager()
    private let recorder = VideoRecorder()
    private let renderer: LUTRenderer
    private var cancellables = Set<AnyCancellable>()

    override init() {
        guard let renderer = LUTRenderer(previewView: nil) else { fatalError("Metal unavailable") }
        self.renderer = renderer
        super.init()
        capture.frameConsumer = self
        bind()
        capture.startSession()
    }

    private func bind() {
        capture.$isLogCompatible
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLogCompatible)
        capture.$activeResolutionDescription
            .receive(on: DispatchQueue.main)
            .assign(to: &$resolutionText)
        capture.$usingFrontCamera
            .receive(on: DispatchQueue.main)
            .assign(to: &$usingFrontCamera)

        recorder.onSavedToPhotos = { [weak self] success, _ in
            DispatchQueue.main.async {
                self?.isRecording = false
                if success == false {
                    self?.permissionMessage = "Could not save to Photos. Check permissions."
                }
            }
        }
    }

    func setPreviewView(_ view: MTKView) {
        renderer.setPreviewView(view)
    }

    // MARK: - Controls
    func toggleRecord() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard isLogCompatible else { return }
        do {
            try recorder.start(resolution: preferredRecordingSize(), orientation: orientation, isFrontCamera: usingFrontCamera)
            isRecording = true
        } catch {
            permissionMessage = "Unable to start recording: \(error.localizedDescription)"
            isRecording = false
        }
    }

    func stopRecording() {
        recorder.stopAndSaveToPhotos()
    }

    func toggleFrontBack() {
        capture.toggleFrontBack()
    }

    func setZoomStep(_ step: CGFloat) {
        capture.setBackCameraZoomStep(step)
    }

    func handleDeviceOrientation(_ deviceOrientation: UIDeviceOrientation) {
        guard let videoOrientation = deviceOrientation.videoOrientation else { return }
        orientation = videoOrientation
        capture.updateVideoOrientation(videoOrientation)
    }

    private func preferredRecordingSize() -> CGSize {
        if let dims = capture.currentVideoDimensions() {
            return CGSize(width: Int(dims.width), height: Int(dims.height))
        }
        let parts = resolutionText.split(separator: "x")
        let width = Int(parts.first ?? "3840") ?? 3840
        let height = Int(parts.last ?? "2160") ?? 2160
        return CGSize(width: width, height: height)
    }

    // MARK: - FrameConsumer
    func consumeVideo(sampleBuffer: CMSampleBuffer) {
        let mode = lutMode
        renderer.processAsync(sampleBuffer: sampleBuffer, mode: mode) { [weak self] pixelBuffer, timestamp in
            guard let self else { return }
            if self.isRecording {
                self.recorder.appendVideo(pixelBuffer: pixelBuffer, with: timestamp)
            }
        }
    }

    func consumeAudio(sampleBuffer: CMSampleBuffer) {
        if isRecording {
            recorder.appendAudio(sampleBuffer: sampleBuffer)
        }
    }
}
