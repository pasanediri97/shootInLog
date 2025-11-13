import SwiftUI
import MetalKit
import AVFoundation

struct CameraView: View {
    @StateObject private var model = CameraViewModel()
    @State private var selectedZoom: CGFloat = 1.0
    @State private var showInfo = false
    @State private var recordingTime: TimeInterval = 0
    @State private var recordingTimer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                cameraPreview
                Spacer()
            }

            VStack {
                topBar
                Spacer()
                bottomControls
            }

            overlay
            
            if model.isRecording {
                recordingIndicators
            }
        }
        .sheet(isPresented: $showInfo) {
            InfoSheet()
                .presentationDetents([.fraction(0.6)])
        }
        .alert(item: Binding(get: {
            model.permissionMessage.map { IdentMessage(id: UUID(), message: $0) }
        }, set: { _ in })) { item in
            Alert(title: Text("Notice"), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            model.handleDeviceOrientation(UIDevice.current.orientation)
        }
        .onChange(of: model.isRecording) { isRecording in
            if isRecording {
                startRecordingTimer()
            } else {
                stopRecordingTimer()
            }
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            model.handleDeviceOrientation(UIDevice.current.orientation)
        }
        .onChange(of: model.usingFrontCamera) { isFront in
            if isFront { selectedZoom = 1.0 }
        }
    }

    private var cameraPreview: some View {
        MetalPreviewContainer(onReady: { mtk in
            model.setPreviewView(mtk)
        })
        .aspectRatio(9 / 16, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            // Left side - LOG indicator badge
            VStack(alignment: .leading, spacing: 8) {
                if model.isLogCompatible {
                    HStack(spacing: 6) {
                        Image(systemName: "video.fill")
                            .font(.caption2.weight(.semibold))
                        Text("LOG")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(.white)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                }
                
                // LUT Mode indicator
                if model.lutMode != .off {
                    Text(model.lutMode.rawValue.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.25))
                        )
                }
            }
            
            Spacer()
            
            // Right side controls
            VStack(spacing: 12) {
                Button(action: { model.toggleFrontBack() }) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                
                Button(action: { showInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            // LUT mode selector - compact design
            if model.isLogCompatible {
                HStack(spacing: 8) {
                    ForEach([LUTMode.off, .subject, .scenery]) { mode in
                        Button(action: { model.lutMode = mode }) {
                            Text(mode.rawValue.uppercased())
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(model.lutMode == mode ? .black : .white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(model.lutMode == mode ? Color.white : Color.white.opacity(0.2))
                                )
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            
            // Zoom controls
            if !model.usingFrontCamera && model.isLogCompatible {
                HStack(spacing: 8) {
                    ForEach([0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { z in
                        Button(action: {
                            selectedZoom = z
                            model.setZoomStep(CGFloat(z))
                        }) {
                            Text(z == 0.5 ? ".5" : (z == 1.0 ? "1" : "\(Int(z))"))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(selectedZoom == z ? .yellow : .white)
                                .frame(width: 36, height: 36)
                                .background(
                                    Circle()
                                        .fill(selectedZoom == z ? Color.white.opacity(0.25) : Color.clear)
                                )
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            
            // Record button and resolution
            VStack(spacing: 12) {
                // Record button
                Button(action: { model.toggleRecord() }) {
                    ZStack {
                        // Outer ring
                        Circle()
                            .strokeBorder(model.isLogCompatible ? Color.white : Color.gray, lineWidth: 4)
                            .frame(width: 76, height: 76)
                        
                        // Inner button
                        if model.isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                                .frame(width: 32, height: 32)
                        } else {
                            Circle()
                                .fill(model.isLogCompatible ? Color.red : Color.gray)
                                .frame(width: 64, height: 64)
                        }
                    }
                }
                .disabled(!model.isLogCompatible)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.isRecording)
                
                // Resolution text
                if !model.resolutionText.isEmpty && model.isLogCompatible {
                    Text(model.resolutionText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.bottom, 40)
        }
    }
    
    private var recordingIndicators: some View {
        VStack {
            HStack(spacing: 8) {
                // Recording red dot
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(recordingTime.truncatingRemainder(dividingBy: 1.0) < 0.5 ? 1.0 : 0.3)
                
                // Recording timer
                Text(formatRecordingTime(recordingTime))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.6))
            )
            .padding(.top, 80)
            
            Spacer()
        }
    }

    private var overlay: some View {
        VStack {
            if !model.isLogCompatible {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundColor(.yellow)
                    
                    Text("Log Video Not Supported")
                        .font(.headline)
                    
                    Text("Your device doesn't support Log video recording. This feature requires iPhone 15 Pro or newer.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.black.opacity(0.85))
                )
                .padding(.horizontal, 32)
                .padding(.top, 120)
            }
            Spacer()
        }
    }
    
    private func startRecordingTimer() {
        recordingTime = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            recordingTime += 0.1
        }
    }
    
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingTime = 0
    }
    
    private func formatRecordingTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct IdentMessage: Identifiable { let id: UUID; let message: String }

// MARK: - MTKView in SwiftUI
struct MetalPreviewContainer: UIViewRepresentable {
    let onReady: (MTKView) -> Void

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 30
        DispatchQueue.main.async { onReady(view) }
        return view
    }
    func updateUIView(_ uiView: MTKView, context: Context) { }
}

// MARK: - Info Sheet
struct InfoSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "video.badge.waveform.fill")
                    .font(.title)
                    .foregroundColor(.yellow)
                
                Text("Log Video Recorder")
                    .font(.title2.bold())
            }
            
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(icon: "camera.fill", text: "Records in Apple Log format for maximum dynamic range")
                InfoRow(icon: "square.3.layers.3d", text: "Apply LUTs in real-time: Subject or Scenery")
                InfoRow(icon: "4k.tv.fill", text: "Records at highest available resolution (up to 4K)")
                InfoRow(icon: "magnifyingglass.circle.fill", text: "Quick zoom: .5x, 1x, 2x, 4x, 8x")
                InfoRow(icon: "arrow.clockwise.circle.fill", text: "Toggle between front and back cameras")
            }
            
            Divider()
            
            Text("Videos are automatically saved to your Photos library")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(24)
    }
}

struct InfoRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.blue)
                .frame(width: 24)
            
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension UIDeviceOrientation {
    var videoOrientation: AVCaptureVideoOrientation? {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight // device left = camera right
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }
}

