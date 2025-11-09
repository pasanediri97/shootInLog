import SwiftUI
import MetalKit

struct CameraView: View {
    @StateObject private var model = CameraViewModel()
    @State private var selectedZoom: CGFloat = 1.0
    @State private var showInfo = false

    var body: some View {
        ZStack {
            MetalPreviewContainer(onReady: { mtk in
                model.setPreviewView(mtk)
            })
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                lutButtons
                recordBar
                    .padding(.bottom, 30)
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
                        .foregroundStyle(model.lutMode == mode ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(model.lutMode == mode ? Color.accentColor : Color(white: 0.2, opacity: 0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!model.isLogCompatible && mode != .off)
            }
        }
        .padding(.bottom, 12)
    }

    private var recordBar: some View {
        VStack(spacing: 16) {
            // Zoom steps
            HStack(spacing: 10) {
                ForEach([0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { z in
                    Button(action: {
                        selectedZoom = z
                        model.setZoomStep(CGFloat(z))
                    }) {
                        Text("\(z, specifier: "%.1f")x")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(selectedZoom == z ? .white : .primary)
                            .frame(width: 52, height: 34)
                            .background(selectedZoom == z ? Color.accentColor : Color(white: 0.2, opacity: 0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            // Record button
            Button(action: { model.toggleRecord() }) {
                Circle()
                    .fill(model.isLogCompatible ? (model.isRecording ? Color.red : Color.white) : Color.gray)
                    .frame(width: 78, height: 78)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.8), lineWidth: 3)
                    )
            }
            .disabled(!model.isLogCompatible)

            Text(model.resolutionText.isEmpty ? "" : "Recording resolution: \(model.resolutionText)")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = false
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
            Text("\u2022 App opens directly to Log video mode.\n\u2022 Choose a LUT: Off, Subject, or Scenery.\n\u2022 Tap record to capture 4K video. LUT is applied in real time to preview and recording.\n\u2022 Use zoom steps for quick lens switching (0.5x, 1x, 2x, 4x, 8x).\n\u2022 Video saves to your Photos after stopping.")
            Link(destination: URL(string: "https://youtu.be/your-tutorial-id")!) {
                Label("Watch Tutorial on YouTube", systemImage: "play.rectangle")
                    .font(.headline)
            }
            Spacer()
        }
        .padding()
    }
}

