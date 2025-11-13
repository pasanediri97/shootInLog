import SwiftUI
import MetalKit
import AVFoundation

struct CameraView: View {
    @StateObject private var model = CameraViewModel()
    @State private var selectedZoom: CGFloat = 1.0
    @State private var showInfo = false

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
                lutButtons
                recordBar
                    .padding(.bottom, 32)
            }
            .padding(.horizontal)

            overlay
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
        HStack {
            Button(action: { model.toggleFrontBack() }) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title2)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            Button(action: { showInfo = true }) {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.top, 8)
    }

    private var lutButtons: some View {
        HStack(spacing: 12) {
            ForEach([LUTMode.off, .subject, .scenery]) { mode in
                Button(action: { model.lutMode = mode }) {
                    Text(mode.rawValue)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(model.lutMode == mode ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(model.lutMode == mode ? Color.white : Color.white.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!model.isLogCompatible && mode != .off)
            }
        }
        .padding(.bottom, 12)
    }

    private var recordBar: some View {
        VStack(spacing: 16) {
            if !model.usingFrontCamera {
                HStack(spacing: 10) {
                    ForEach([0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { z in
                        Button(action: {
                            selectedZoom = z
                            model.setZoomStep(CGFloat(z))
                        }) {
                            Text("\(z, specifier: "%.1f")x")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(selectedZoom == z ? .black : .white)
                                .frame(width: 52, height: 34)
                                .background(selectedZoom == z ? Color.white : Color.white.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }

            Button(action: { model.toggleRecord() }) {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 5)
                        .frame(width: 86, height: 86)
                    Circle()
                        .fill(model.isLogCompatible ? (model.isRecording ? Color.red : Color.white) : Color.gray)
                        .frame(width: 66, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: model.isRecording ? 12 : 33, style: .continuous))
                        .animation(.easeInOut(duration: 0.2), value: model.isRecording)
                }
            }
            .disabled(!model.isLogCompatible)

            if !model.resolutionText.isEmpty {
                Text("Resolution \(model.resolutionText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var overlay: some View {
        VStack {
            if !model.isLogCompatible {
                Text("Your iPhone model is not compatible with this app because it is not capable of shooting Log video")
                    .font(.subheadline)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding()
            }
            Spacer()
        }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("How to Use")
                .font(.title2).bold()
            Text("\u{2022} App opens directly to Log video mode.\n\u{2022} Choose a LUT: Off, Subject, or Scenery.\n\u{2022} Tap record to capture 4K video. LUT is applied in real time to preview and recording.\n\u{2022} Use zoom steps for quick lens switching (0.5x, 1x, 2x, 4x, 8x).\n\u{2022} Video saves to your Photos after stopping.")
            Link(destination: URL(string: "https://youtu.be/your-tutorial-id")!) {
                Label("Watch Tutorial on YouTube", systemImage: "play.rectangle")
                    .font(.headline)
            }
            Spacer()
        }
        .padding()
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

