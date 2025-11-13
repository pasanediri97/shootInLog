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

        // Select best format FIRST, then check compatibility
        selectBestFormatAndFrameRate(device: videoDevice)
        
        // Configure autofocus for better responsiveness
        do {
            try videoDevice.lockForConfiguration()
            if videoDevice.isFocusModeSupported(.continuousAutoFocus) {
                videoDevice.focusMode = .continuousAutoFocus
            }
            if videoDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoDevice.exposureMode = .continuousAutoExposure
            }
            videoDevice.unlockForConfiguration()
        } catch {
            print("❌ Unable to configure focus: \(error)")
        }
        
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

        // Commit configuration FIRST
        session.commitConfiguration()
        
        // Update resolution description
        updateActiveResolutionDescription()
        
        // Check Log compatibility after a brief delay to ensure settings are applied
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.updateLogCompatibility(for: videoDevice)
        }
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
            DispatchQueue.main.async { [weak self] in self?.usingFrontCamera = (newPosition == .front) }
            updateActiveResolutionDescription()
            
            // Check compatibility after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.updateLogCompatibility(for: newDevice)
            }
        } catch {
            session.commitConfiguration()
            publishError("Switch camera failed: \(error.localizedDescription)")
        }
    }

    func setBackCameraZoomStep(_ step: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self = self,
                  let device = self.currentVideoDevice,
                  device.position == .back else { return }
            
            let minZoom = device.minAvailableVideoZoomFactor
            let maxZoom = device.maxAvailableVideoZoomFactor
            
            print("📹 Zoom request: \(step)x, device range: \(minZoom)-\(maxZoom)")
            
            // Clamp to device capabilities
            let clamped = max(minZoom, min(maxZoom, step))
            
            if clamped != step {
                print("⚠️ Zoom clamped from \(step)x to \(clamped)x")
            }
            
            do {
                try device.lockForConfiguration()
                // Use videoZoomFactor for instant zoom (no ramping for better UX)
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                print("✅ Zoom set to \(clamped)x")
            } catch {
                print("❌ Zoom failed: \(error)")
            }
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
        if connection.isVideoStabilizationSupported {
            if #available(iOS 13.0, *) {
                connection.preferredVideoStabilizationMode = .cinematicExtended
            } else {
                connection.preferredVideoStabilizationMode = .cinematic
            }
        }
    }

    // MARK: - Formats & metadata
    private func selectBestFormatAndFrameRate(device: AVCaptureDevice) {
        do { try device.lockForConfiguration() } catch {
            print("❌ Failed to lock device for configuration")
            return
        }
        defer { device.unlockForConfiguration() }

        // Find format with Apple Log support (iOS 18+) or best HDR format
        var bestFormat: AVCaptureDevice.Format?
        var bestDimensions = CMVideoDimensions(width: 0, height: 0)
        
        // First: Look for format with AppleLog color space (iOS 18+)
        if #available(iOS 18.0, *) {
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if format.supportedColorSpaces.contains(.AppleLog) {
                    if dims.width == 3840 && dims.height == 2160 {
                        bestFormat = format
                        bestDimensions = dims
                        print("✅ Found 4K Apple Log format")
                        break
                    } else if dims.width * dims.height > bestDimensions.width * bestDimensions.height {
                        bestFormat = format
                        bestDimensions = dims
                        print("✅ Found Apple Log format: \(dims.width)x\(dims.height)")
                    }
                }
            }
        }
        
        // Second: Look for 4K HDR format with HLG_BT2020
        if bestFormat == nil {
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if dims.width == 3840 && dims.height == 2160 &&
                   format.isVideoHDRSupported &&
                   format.supportedColorSpaces.contains(.HLG_BT2020) {
                    bestFormat = format
                    bestDimensions = dims
                    print("✅ Found 4K HDR format with HLG_BT2020")
                    break
                }
            }
        }
        
        // Third: Any HDR format with HLG_BT2020
        if bestFormat == nil {
            for format in device.formats where format.isVideoHDRSupported {
                if format.supportedColorSpaces.contains(.HLG_BT2020) {
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    if dims.width * dims.height > bestDimensions.width * bestDimensions.height {
                        bestFormat = format
                        bestDimensions = dims
                    }
                }
            }
            if bestFormat != nil {
                print("✅ Found HDR format with HLG_BT2020")
            }
        }
        
        // Fourth: Fallback to highest resolution
        if bestFormat == nil {
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                if dims.width * dims.height > bestDimensions.width * bestDimensions.height {
                    bestFormat = format
                    bestDimensions = dims
                }
            }
        }

        guard let chosen = bestFormat else {
            print("❌ No suitable format found")
            return
        }
        
        // Set the format
        device.activeFormat = chosen
        print("✅ Set format: \(bestDimensions.width)x\(bestDimensions.height), HDR: \(chosen.isVideoHDRSupported)")
        
        // Set frame rate to 30fps
        if let range = chosen.videoSupportedFrameRateRanges.first,
           range.minFrameRate <= 30, range.maxFrameRate >= 30 {
            let duration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        
        // Configure for Apple Log
        if #available(iOS 18.0, *) {
            // Try to use Apple Log color space if available
            if chosen.supportedColorSpaces.contains(.AppleLog) {
                device.activeColorSpace = .AppleLog
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = true
                print("✅ Apple Log enabled with AppleLog color space")
                return
            }
        }
        
        // Fallback to HLG for Log-like capture (iOS 17+)
        if #available(iOS 17.0, *) {
            if chosen.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = true
                
                // Use HLG_BT2020 which provides Log-like encoding
                if chosen.supportedColorSpaces.contains(.HLG_BT2020) {
                    device.activeColorSpace = .HLG_BT2020
                    print("✅ HDR enabled with HLG_BT2020 (Log-like)")
                } else if chosen.supportedColorSpaces.contains(.P3_D65) {
                    device.activeColorSpace = .P3_D65
                    print("✅ HDR enabled with P3_D65")
                }
            }
        }
    }

    private func updateLogCompatibility(for device: AVCaptureDevice) {
        // Ensure we check after device configuration is complete
        let format = device.activeFormat
        
        // Debug info
        print("🎥 === LOG CAPABILITY CHECK ===")
        print("🎥 Device: \(device.deviceType.rawValue)")
        print("🎥 Format HDR Supported: \(format.isVideoHDRSupported)")
        
        // Print color spaces properly
        let colorSpaceNames = format.supportedColorSpaces.map { space -> String in
            switch space {
            case .sRGB: return "sRGB"
            case .P3_D65: return "P3_D65"
            case .HLG_BT2020: return "HLG_BT2020"
            case .appleLog: return "AppleLog"
            @unknown default: return "Unknown(\(space.rawValue))"
            }
        }
        print("🎥 Supported Color Spaces: \(colorSpaceNames.joined(separator: ", "))")
        
        if #available(iOS 17.0, *) {
            print("🎥 HDR Enabled: \(device.isVideoHDREnabled)")
            let activeColorName: String
            switch device.activeColorSpace {
            case .sRGB: activeColorName = "sRGB"
            case .P3_D65: activeColorName = "P3_D65"
            case .HLG_BT2020: activeColorName = "HLG_BT2020"
            case .appleLog: activeColorName = "AppleLog"
            @unknown default: activeColorName = "Unknown(\(device.activeColorSpace.rawValue))"
            }
            print("🎥 Active Color Space: \(activeColorName)")
        }
        
        let compatible = LogCapability.isDeviceLogCapable(activeDevice: device)
        print("🎥 Final Log Compatible: \(compatible)")
        print("🎥 =============================")
        
        DispatchQueue.main.async { [weak self] in
            self?.isLogCompatible = compatible
        }
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


