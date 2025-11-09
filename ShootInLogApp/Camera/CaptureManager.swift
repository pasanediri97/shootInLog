import AVFoundation
import Combine
import CoreMedia
import UIKit

/// Manages the AVFoundation capture session lifecycle and camera controls.
final class CaptureManager: NSObject, ObservableObject {
    // Public state
    @Published var isSessionRunning: Bool = false
    @Published var isRecording: Bool = false
    @Published var isLogCompatible: Bool = false
    @Published var activeResolutionDescription: String = ""
    @Published var errorMessage: String?

    // Capture
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // Consumers
    weak var frameConsumer: FrameConsumer?

    // Zoom / camera config
    @Published var usingFrontCamera: Bool = false
    private var currentVideoDevice: AVCaptureDevice? { videoDeviceInput?.device }

    override init() {
        super.init()
        configure()
    }

    /// Protocol to receive synchronized video frames (and audio if needed)
    protocol FrameConsumer: AnyObject {
        func consumeVideo(sampleBuffer: CMSampleBuffer)
        func consumeAudio(sampleBuffer: CMSampleBuffer)
    }

    private func configure() {
        sessionQueue.async { [weak self] in
            self?.setupSession()
        }
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        // Preferred: back camera by default
        guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ??
                AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) ??
                AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) else {
            publishError("No back camera available")
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: back)
            if session.canAddInput(input) { session.addInput(input) }
            videoDeviceInput = input
        } catch {
            publishError("Failed to create video input: \(error.localizedDescription)")
            session.commitConfiguration()
            return
        }

        // Audio input (optional but desirable for social content)
        if let mic = AVCaptureDevice.default(for: .audio) {
            do {
                let aIn = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(aIn) { session.addInput(aIn) }
            } catch {
                // Non-fatal
            }
        }

        // Configure 4K if possible; fall back to highest
        selectBestFormatAndFrameRate(device: back)

        // Video data output
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
        }

        // Audio data output
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }

        isLogCompatible = LogCapability.isDeviceLogCapable(activeDevice: back)
        session.commitConfiguration()
        updateActiveResolutionDescription()
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isSessionRunning = true }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    func toggleFrontBack() {
        sessionQueue.async { [weak self] in
            self?._toggleFrontBack()
        }
    }

    private func _toggleFrontBack() {
        guard let currentInput = videoDeviceInput else { return }
        let newPosition: AVCaptureDevice.Position = currentInput.device.position == .back ? .front : .back
        usingFrontCamera = (newPosition == .front)
        let preferredTypes: [AVCaptureDevice.DeviceType] = newPosition == .back ?
            [.builtInTripleCamera, .builtInDualCamera, .builtInWideAngleCamera] :
            [.builtInTrueDepthCamera, .builtInWideAngleCamera]

        guard let newDevice = AVCaptureDevice.DiscoverySession(deviceTypes: preferredTypes, mediaType: .video, position: newPosition).devices.first else {
            return
        }
        do {
            session.beginConfiguration()
            session.removeInput(currentInput)
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            if session.canAddInput(newInput) { session.addInput(newInput) }
            videoDeviceInput = newInput
            selectBestFormatAndFrameRate(device: newDevice)
            if let connection = videoOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
            }
            session.commitConfiguration()
            isLogCompatible = LogCapability.isDeviceLogCapable(activeDevice: newDevice)
            updateActiveResolutionDescription()
        } catch {
            publishError("Switch camera failed: \(error.localizedDescription)")
        }
    }

    /// Steps: 0.5, 1, 2, 4, 8 – mapped to available zoom range
    func setBackCameraZoomStep(_ step: CGFloat) {
        guard let device = currentVideoDevice, device.position == .back else { return }
        let minZ = device.minAvailableVideoZoomFactor
        let maxZ = device.maxAvailableVideoZoomFactor

        // Map nominal step to actual available range
        let clampedNominal = max(0.5, min(8.0, step))
        let mapped = max(minZ, min(maxZ, clampedNominal))

        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: mapped, withRate: 5.0)
            device.unlockForConfiguration()
        } catch {
            // ignore
        }
    }

    private func selectBestFormatAndFrameRate(device: AVCaptureDevice) {
        do { try device.lockForConfiguration() } catch { return }
        defer { device.unlockForConfiguration() }

        // Choose 4K (3840x2160) if available, else highest resolution 16:9
        var bestFormat: AVCaptureDevice.Format?
        var bestDimensions = CMVideoDimensions(width: 0, height: 0)
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            // Prefer 3840x2160 first
            if dims.width == 3840 && dims.height == 2160 {
                bestFormat = format
                bestDimensions = dims
                break
            }
            // Track highest area as fallback
            if dims.width * dims.height > bestDimensions.width * bestDimensions.height {
                bestFormat = format
                bestDimensions = dims
            }
        }

        if let chosen = bestFormat {
            device.activeFormat = chosen
            // Choose a common frame rate (30 fps) if supported
            if let range = chosen.videoSupportedFrameRateRanges.first, range.minFrameRate <= 30 && range.maxFrameRate >= 30 {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            // Prefer HDR if device supports
            if #available(iOS 17.0, *), chosen.isVideoHDRSupported {
                device.isVideoHDREnabled = true
            }
        }
    }

    private func updateActiveResolutionDescription() {
        guard let device = currentVideoDevice else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        DispatchQueue.main.async { [weak self] in
            self?.activeResolutionDescription = "\(dims.width)×\(dims.height)"
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = message
        }
    }
}

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            frameConsumer?.consumeVideo(sampleBuffer: sampleBuffer)
        } else if output == audioOutput {
            frameConsumer?.consumeAudio(sampleBuffer: sampleBuffer)
        }
    }
}

