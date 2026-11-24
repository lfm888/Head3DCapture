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
    @State private var showDiagnostics = false

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
                        Text("目录: \(AppPaths.filesAppPath(folder: folder))")
                            .font(.caption2.monospaced())
                            .foregroundColor(.green)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
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
                    Text("实时深度点云 · \(manager.livePointCount.formatted()) 点")
                        .font(.caption.bold().monospaced())
                        .foregroundColor(.cyan)
                    Text("深度图 \(manager.depthFrameLabel) · 上限 \(manager.maxPointCount.formatted()) 点 · 步长 \(manager.pointStride)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.white.opacity(0.75))
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

            // 显示模式：彩色深度点云 / 深度伪彩 + 点云稠密度
            HStack(spacing: 8) {
                Picker("显示", selection: $manager.showColorPointCloud) {
                    Text("彩色").tag(true)
                    Text("伪彩").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 130)

                Spacer(minLength: 0)

                Button {
                    showDiagnostics = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .foregroundColor(.white)
                        .background(Color.white.opacity(0.18))
                        .cornerRadius(7)
                }

                Button {
                    if let url = manager.lastCaptureURL { FileExporter.export([url]) }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(manager.lastCaptureURL == nil ? 0.25 : 0.9))
                        .foregroundColor(.white)
                        .cornerRadius(7)
                }
                .disabled(manager.lastCaptureURL == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // 实时可调：抽样步长 / 距离带
            VStack(spacing: 2) {
                sliderRow(title: "步长",
                          valueText: "\(manager.pointStride)×\(manager.pointStride) → 1/\(manager.pointStride * manager.pointStride)",
                          binding: strideBinding,
                          range: 1...8,
                          step: 1)
                sliderRow(title: "近端",
                          valueText: String(format: "%.2f m", manager.nearZ),
                          binding: $manager.nearZ,
                          range: 0.05...2.00,
                          step: 0.05)
                sliderRow(title: "远端",
                          valueText: String(format: "%.2f m", manager.farZ),
                          binding: $manager.farZ,
                          range: 0.20...4.00,
                          step: 0.05)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.black)

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

                Text(String(format: "%.2f~%.2fm", manager.nearZ, manager.farZ))
                    .font(.caption.monospaced())
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.black)

            VStack(spacing: 1) {
                Text("保存位置：\(AppPaths.filesAppRoot)")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                Text(manager.outputFolderName.map { "已同步到: \($0)（每次保存自动复制）" }
                     ?? "看不到就点 ⓘ 诊断 / 导出，或在诊断里设「同步目录」")
                    .font(.caption2)
                    .foregroundColor(.green.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .background(Color.black)
        }
        .navigationTitle("iPhone深度数据采集模块")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDiagnostics) {
            StorageDiagnosticsView(manager: manager)
        }
    }

    private var strideBinding: Binding<Double> {
        Binding(get: { Double(manager.pointStride) },
                set: { manager.pointStride = Int($0.rounded()) })
    }

    private func sliderRow(title: String,
                           valueText: String,
                           binding: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2.monospaced())
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 28, alignment: .leading)
            Slider(value: binding, in: range, step: step)
                .tint(.cyan)
            Text(valueText)
                .font(.caption2.monospaced())
                .foregroundColor(.cyan)
                .frame(width: 108, alignment: .trailing)
        }
    }
}

/// 用系统文件选择器把捕获目录导出/拷贝到 iCloud Drive 或「我的 iPhone」任意位置。
/// （iOS 没有给 App 写任意公共目录的权限，这是唯一稳定的公开做法。）
enum FileExporter {
    static func export(_ urls: [URL]) {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.shouldShowFileExtensions = true
        FilePresenter.present(picker)
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
