import AVFoundation
import SwiftUI

@main
struct Head3DCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
            }
        }
    }
}

struct HomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "faceid")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Head3D 数据采集工具")
                .font(.title2.bold())

            NavigationLink(destination: TrueDepthCaptureView()) {
                Label("iPhone深度数据采集模块", systemImage: "camera.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)
        }
        .navigationTitle("Head3D")
    }
}

struct TrueDepthCaptureView: View {
    @StateObject private var manager = TrueDepthCaptureManager()

    var body: some View {
        VStack(spacing: 0) {
            // 上半屏：前置 RGB 预览 + 状态提示
            ZStack(alignment: .top) {
                CameraPreviewView(session: manager.session)

                VStack(spacing: 4) {
                    Text(manager.statusMessage)
                        .font(.caption.monospaced())
                        .foregroundColor(.white)
                    if let folder = manager.lastSavedFolder {
                        Text("目录: Documents/\(folder)")
                            .font(.caption2.monospaced())
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.65))
                .cornerRadius(8)
                .padding(.top, 8)
            }
            .frame(maxHeight: .infinity)

            // 下半屏：实时深度点云可视化（Metal）
            ZStack(alignment: .topLeading) {
                PointCloudMetalView(renderer: manager.pointCloudRenderer)

                VStack(alignment: .leading, spacing: 2) {
                    Text("实时深度点云 · \(manager.livePointCount) 点")
                        .font(.caption.bold().monospaced())
                        .foregroundColor(.cyan)
                    Text("单指旋转 · 双指缩放 · 双击复位")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.75))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55))
                .cornerRadius(8)
                .padding(8)
            }
            .frame(maxHeight: .infinity)

            // 底部快门与计数栏
            HStack {
                Text("已存帧数: \(manager.captureCount)")
                    .font(.footnote.bold().monospaced())
                    .foregroundColor(.white)

                Spacer()

                Button(action: {
                    manager.captureFrame()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 62, height: 62)
                        Circle()
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 72, height: 72)
                    }
                }
                .disabled(!manager.isSessionRunning)

                Spacer()

                Text("0.15m~1.2m")
                    .font(.caption.monospaced())
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.black)
        }
        .navigationTitle("iPhone深度数据采集模块")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
