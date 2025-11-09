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

    let capture = CaptureManager()
    private let recorder = VideoRecorder()
    private let renderer: LUTRenderer
    private var cancellables = Set<AnyCancellable>()

    override init() {
        guard let r = LUTRenderer(previewView: nil) else { fatalError("Metal unavailable") }
        renderer = r
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
        recorder.onSavedToPhotos = { [weak self] success, error in
            DispatchQueue.main.async {
                self?.isRecording = false
                if success == false {
                    self?.permissionMessage = "Could not save to Photos. Check permissions."
                }
            }
        }
    }

    func setPreviewView(_ v: MTKView) { renderer.setPreviewView(v) }

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
        let parts = resolutionText.split(separator: "×")
        let w = Int(parts.first ?? "3840") ?? 3840
        let h = Int(parts.last ?? "2160") ?? 2160
        do {
            try recorder.start(resolution: CGSize(width: w, height: h))
            isRecording = true
        } catch {
            isRecording = false
        }
    }

    func stopRecording() {
        recorder.stopAndSaveToPhotos()
    }

    func toggleFrontBack() { capture.toggleFrontBack() }
    func setZoomStep(_ step: CGFloat) { capture.setBackCameraZoomStep(step) }

    // MARK: - FrameConsumer
    func consumeVideo(sampleBuffer: CMSampleBuffer) {
        let mode = lutMode
        renderer.processAsync(sampleBuffer: sampleBuffer, mode: mode) { [weak self] outPB, ts in
            guard let self else { return }
            if self.isRecording {
                self.recorder.appendVideo(pixelBuffer: outPB, with: ts)
            }
        }
    }

    func consumeAudio(sampleBuffer: CMSampleBuffer) {
        if isRecording { recorder.appendAudio(sampleBuffer: sampleBuffer) }
    }
}
