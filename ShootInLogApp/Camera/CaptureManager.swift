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
    @Published var errorMessage: String?
    @Published var usingFrontCamera: Bool = false

    // Capture graph
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var currentOrientation: AVCaptureVideoOrientation = .portrait

    weak var frameConsumer: FrameConsumer?

    // MARK: - Life cycle
    override init() {
        super.init()
        configure()
    }

    /// Protocol to receive synchronized video/audio frames
    protocol FrameConsumer: AnyObject {
        func consumeVideo(sampleBuffer: CMSampleBuffer)
        func consumeAudio(sampleBuffer: CMSampleBuffer)
    }

    private func configure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.publishError("Camera access denied. Enable it in Settings > Privacy > Camera.")
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { _ in
                self.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    self.configureAudioSession()
                    self.setupSession()
                    if !self.session.isRunning {
                        self.session.startRunning()
                        DispatchQueue.main.async { self.isSessionRunning = true }
                    }
                }
            }
        }
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            // Non-fatal. Still allow capture to proceed.
        }
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        guard let videoDevice = defaultVideoDevice(position: .back) else {
            publishError("No compatible back camera available")
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(input) { session.addInput(input) }
            videoDeviceInput = input
            DispatchQueue.main.async { [weak self] in
                self?.usingFrontCamera = (videoDevice.position == .front)
            }
        } catch {
            publishError("Unable to create video input: \(error.localizedDescription)")
            session.commitConfiguration()
            return
        }

        if let mic = AVCaptureDevice.default(for: .audio) {
            do {
                let audioInput = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(audioInput) { session.addInput(audioInput) }
            } catch {
                // microphone optional
            }
        }

        selectBestFormatAndFrameRate(device: videoDevice)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        configureConnection(videoOutput.connection(with: .video))

        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }

        updateLogCompatibility(for: videoDevice)
        session.commitConfiguration()
        updateActiveResolutionDescription()
    }

    private func defaultVideoDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            let preferred: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            return AVCaptureDevice.DiscoverySession(deviceTypes: preferred, mediaType: .video, position: .back).devices.first
        } else {
            let preferred: [AVCaptureDevice.DeviceType] = [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            return AVCaptureDevice.DiscoverySession(deviceTypes: preferred, mediaType: .video, position: .front).devices.first
        }
    }

    // MARK: - Session control
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
        guard let newDevice = defaultVideoDevice(position: newPosition) else { return }

        do {
            session.beginConfiguration()
            session.removeInput(currentInput)
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            if session.canAddInput(newInput) { session.addInput(newInput) }
            videoDeviceInput = newInput
            selectBestFormatAndFrameRate(device: newDevice)
            configureConnection(videoOutput.connection(with: .video))
            session.commitConfiguration()
            updateLogCompatibility(for: newDevice)
            DispatchQueue.main.async { [weak self] in self?.usingFrontCamera = (newPosition == .front) }
            updateActiveResolutionDescription()
        } catch {
            session.commitConfiguration()
            publishError("Switch camera failed: \(error.localizedDescription)")
        }
    }

    func setBackCameraZoomStep(_ step: CGFloat) {
        guard let device = currentVideoDevice, device.position == .back else { return }
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = device.maxAvailableVideoZoomFactor
        let clamped = max(minZoom, min(maxZoom, step))
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: clamped, withRate: 5.0)
            device.unlockForConfiguration()
        } catch {
            // ignore
        }
    }

    // MARK: - Orientation
    func updateVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.currentOrientation = orientation
            self.configureConnection(self.videoOutput.connection(with: .video))
        }
    }

    private func configureConnection(_ connection: AVCaptureConnection?) {
        guard let connection else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = currentOrientation
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = usingFrontCamera
        }
        let targetFrameDuration = CMTime(value: 1, timescale: 30)
        connection.videoMinFrameDuration = targetFrameDuration
        connection.videoMaxFrameDuration = targetFrameDuration
        if connection.isVideoStabilizationSupported {
            let modes = connection.availableVideoStabilizationModes
            if #available(iOS 13.0, *), modes.contains(.cinematicExtended) {
                connection.preferredVideoStabilizationMode = .cinematicExtended
            } else if modes.contains(.cinematic) {
                connection.preferredVideoStabilizationMode = .cinematic
            } else if modes.contains(.standard) {
                connection.preferredVideoStabilizationMode = .standard
            } else {
                connection.preferredVideoStabilizationMode = .off
            }
        }
    }

    // MARK: - Formats & metadata
    private func selectBestFormatAndFrameRate(device: AVCaptureDevice) {
        do { try device.lockForConfiguration() } catch { return }
        defer { device.unlockForConfiguration() }

        var bestFormat: AVCaptureDevice.Format?
        var bestDimensions = CMVideoDimensions(width: 0, height: 0)
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if dims.width == 3840 && dims.height == 2160 {
                bestFormat = format
                bestDimensions = dims
                break
            }
            if dims.width * dims.height > bestDimensions.width * bestDimensions.height {
                bestFormat = format
                bestDimensions = dims
            }
        }

        if let chosen = bestFormat {
            device.activeFormat = chosen
            if let range = chosen.videoSupportedFrameRateRanges.first,
               range.minFrameRate <= 30, range.maxFrameRate >= 30 {
                let duration = CMTime(value: 1, timescale: 30)
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            if #available(iOS 17.0, *) {
                if chosen.isVideoHDRSupported {
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = true
                    if chosen.supportedColorSpaces.contains(.HLG_BT2020) {
                        device.activeColorSpace = .HLG_BT2020
                    }
                } else {
                    device.automaticallyAdjustsVideoHDREnabled = true
                    device.isVideoHDREnabled = false
                }
            }
        }
    }

    private func updateLogCompatibility(for device: AVCaptureDevice) {
        let compatible = LogCapability.isDeviceLogCapable(activeDevice: device)
        DispatchQueue.main.async { [weak self] in self?.isLogCompatible = compatible }
    }

    private func updateActiveResolutionDescription() {
        guard let dims = currentVideoDimensions() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.activeResolutionDescription = "\(dims.width)x\(dims.height)"
        }
    }

    func currentVideoDimensions() -> CMVideoDimensions? {
        guard let device = currentVideoDevice else { return nil }
        return CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    }

    private var currentVideoDevice: AVCaptureDevice? { videoDeviceInput?.device }

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


