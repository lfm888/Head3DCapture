import AVFoundation
import CoreImage
import ImageIO
import simd
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Thread-safe holder for the most recent RGB video frame, used to colour the live point cloud.
/// Retaining a single `CVPixelBuffer` is zero-copy and enough — older frames are dropped
/// (`alwaysDiscardsLateVideoFrames`).
final class LatestVideoFrame {
    static let shared = LatestVideoFrame()

    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var intrinsics: simd_float3x3?

    func update(_ pixelBuffer: CVPixelBuffer, intrinsics newIntrinsics: simd_float3x3?) {
        lock.lock()
        buffer = pixelBuffer
        if let newIntrinsics { intrinsics = newIntrinsics }
        lock.unlock()
    }

    func peek() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// 前置 RGB 相机内参（由 `kCMSampleAttachmentKey_CameraIntrinsicMatrix` 提供，单位为
    /// 当前视频帧像素，即 `color_sampling_width x color_sampling_height`）。
    func peekIntrinsics() -> simd_float3x3? {
        lock.lock()
        defer { lock.unlock() }
        return intrinsics
    }

    func clear() {
        lock.lock()
        buffer = nil
        intrinsics = nil
        lock.unlock()
    }
}

/// 与可视化相关的常量（不参与保存的数据契约）。
enum PointCloudSettings {
    /// TrueDepth 深度图是横向(landscape)输出的，顺时针转 90° 与竖屏预览一致。
    static let rotationDegrees: Float = 90
    /// 距离带 / 步长默认值与可调范围（UI 可在运行时拖动）。
    static let defaultMinZ: Double = 0.10
    static let defaultMaxZ: Double = 1.50
    static let strideRange: ClosedRange<Int> = 1...8
    /// 点云重建频率上限（帧/秒），避免满密度时把 CPU 打满。
    static let maxRebuildHz: Double = 15
}

/// 深度回调所在的非主线程需要读到的配置副本（由 UI 的 @Published 值同步过来）。
final class PointCloudConfig {
    static let shared = PointCloudConfig()

    struct Values {
        var stride: Int = 1
        var useColor: Bool = true
        var minZ: Float = Float(PointCloudSettings.defaultMinZ)
        var maxZ: Float = Float(PointCloudSettings.defaultMaxZ)
    }

    private let lock = NSLock()
    private var values = Values()

    func update(stride newStride: Int, useColor newUseColor: Bool, minZ: Float, maxZ: Float) {
        lock.lock()
        values.stride = max(PointCloudSettings.strideRange.lowerBound,
                            min(PointCloudSettings.strideRange.upperBound, newStride))
        values.useColor = newUseColor
        values.minZ = max(0, minZ)
        values.maxZ = max(minZ + 0.05, maxZ)
        lock.unlock()
    }

    func current() -> Values {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// 界面里所有「路径」文案的唯一来源，避免同一目录出现三种写法。
/// 真实位置：App 沙盒 `Documents/Head3D/<时间戳>/`，因为 `UIFileSharingEnabled`，
/// 在「文件」App 里的等价路径就是 `我的 iPhone/<App 显示名>/Head3D/<时间戳>/`。
enum AppPaths {
    static let capturesFolderName = "Head3D"

    /// 从 Info.plist 读取，改 `CFBundleDisplayName` 时文案会跟着变。
    static var appDisplayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Head3D采集"
    }

    /// 「文件」App 中保存根目录的完整人话路径。
    static var filesAppRoot: String {
        "「文件」App › 我的 iPhone › \(appDisplayName) › \(capturesFolderName)"
    }

    /// 单次采集目录在「文件」App 中的路径。
    static func filesAppPath(folder: String) -> String {
        "我的 iPhone › \(appDisplayName) › \(capturesFolderName) › \(folder)"
    }

    /// 沙盒内相对路径（写进 intrinsics.json，给后端用）。
    static func relativePath(folder: String) -> String {
        "\(capturesFolderName)/\(folder)"
    }
}

/** 一次采集写盘后的单个文件（用于界面校验与诊断）。 */
struct StoredFile: Identifiable, Hashable {
    let name: String
    let bytes: Int64
    var id: String { name }

    var displaySize: String { StoredFile.format(bytes) }

    static func format(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", kb / 1024.0)
    }

    static func describe(_ directory: URL, names: [String]) -> [StoredFile] {
        names.map { name in
            let url = directory.appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return StoredFile(name: name, bytes: size)
        }
    }
}

/// 让用户挑一个「同步输出目录」（iCloud Drive / 我的 iPhone 任意位置），记下安全作用域书签，
/// 之后每次保存都自动在同一位置复制一份——完全不依赖「文件」App 是否展示 App 沙盒。
final class FolderPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let onPick: (URL) -> Void

    init(onPick: @escaping (URL) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { onPick(url) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
}

/// 弹出系统 UI（文档选择器等）的辅助工具。
enum FilePresenter {
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    static func present(_ viewController: UIViewController) {
        topViewController()?.present(viewController, animated: true)
    }
}

/// 限制点云重建频率。
final class PointCloudThrottle {
    static let shared = PointCloudThrottle()

    private let lock = NSLock()
    private var lastTime: CFTimeInterval = 0

    func allow(hz: Double) -> Bool {
        let interval = hz > 0 ? 1.0 / hz : 0
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        if now - lastTime >= interval {
            lastTime = now
            return true
        }
        return false
    }
}

@MainActor
class TrueDepthCaptureManager: NSObject, ObservableObject {
    @Published var isSessionRunning = false
    @Published var statusMessage = "就绪"
    @Published var lastSavedFolder: String?
    @Published var lastCaptureURL: URL?
    @Published var captureCount = 0
    @Published var livePointCount = 0
    /// 最近一次保存写盘后实际看到的文件与大小（界面用来验证「真的写进去了」）。
    @Published var lastStoredFiles: [StoredFile] = []
    /// 用户通过文档选择器指定的额外同步目录（书签持久化）。
    @Published var outputFolderName: String?
    /// true = 彩色深度点云（用前置 RGB 给每个深度点上色）；false = 深度伪彩。
    @Published var showColorPointCloud = true {
        didSet { syncPointCloudConfig() }
    }
    /// 抽样步长：每隔多少个像素取一个点（1 = 全部像素，2 = 1/4，3 = 1/9 …）。
    @Published var pointStride: Int = 1 {
        didSet { syncPointCloudConfig() }
    }
    /// 距离带（米），只保留该区间内的深度点。
    @Published var nearZ: Double = PointCloudSettings.defaultMinZ {
        didSet {
            if nearZ > farZ - 0.15 { farZ = nearZ + 0.15 }
            syncPointCloudConfig()
        }
    }
    @Published var farZ: Double = PointCloudSettings.defaultMaxZ {
        didSet {
            if farZ < nearZ + 0.15 { nearZ = farZ - 0.15 }
            syncPointCloudConfig()
        }
    }
    /// 当前深度图分辨率 / 像素总数（用于显示上限，排查点数为何变少）。
    @Published var depthFrameLabel = "--"
    @Published var depthPixelTotal = 0

    /// 当前步长下的理论上限点数。
    var maxPointCount: Int {
        guard depthPixelTotal > 0 else { return 0 }
        let step = max(1, pointStride)
        return depthPixelTotal / (step * step)
    }

    private func syncPointCloudConfig() {
        PointCloudConfig.shared.update(stride: pointStride,
                                       useColor: showColorPointCloud,
                                       minZ: Float(nearZ),
                                       maxZ: Float(farZ))
    }

    let session = AVCaptureSession()
    let pointCloudRenderer = PointCloudRenderer()

    /// 点云可视化相对传感器原始朝向的旋转。TrueDepth 深度图是横向(landscape)输出的，
    /// 顺时针转 90° 后与竖屏预览画面一致。数据文件不做旋转（保持传感器原始朝向）。
    static let pointCloudRotationDegrees: Float = PointCloudSettings.rotationDegrees

    private let sessionQueue = DispatchQueue(label: "com.head3d.capture.session")
    private let depthStreamQueue = DispatchQueue(label: "com.head3d.depth.stream")
    private let videoStreamQueue = DispatchQueue(label: "com.head3d.video.stream")
    private let photoOutput = AVCapturePhotoOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    override init() {
        super.init()
        outputFolderName = UserDefaults.standard.string(forKey: Self.outputFolderNameKey)
        syncPointCloudConfig()
        checkPermissionsAndConfigure()
    }

    private func checkPermissionsAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.configureSession() }
                } else {
                    Task { @MainActor in self.statusMessage = "错误：未授予相机权限" }
                }
            }
        default:
            statusMessage = "错误：请在系统设置中开启相机权限"
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            Task { @MainActor in self.statusMessage = "错误：此设备不支持前置 TrueDepth 深度相机" }
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            Task { @MainActor in self.statusMessage = "错误：无法添加 PhotoOutput" }
            session.commitConfiguration()
            return
        }
        session.addOutput(photoOutput)

        if session.canAddOutput(depthDataOutput) {
            depthDataOutput.isFilteringEnabled = false
            depthDataOutput.setDelegate(self, callbackQueue: depthStreamQueue)
            session.addOutput(depthDataOutput)

            if let conn = depthDataOutput.connection(with: .depthData) {
                conn.isEnabled = true
            }
        }

        // Live RGB frames: only used to colour the point cloud. They need no rotation because
        // the video stream and the depth stream are both delivered in the sensor's own
        // orientation (iOS already registers TrueDepth depth to this RGB camera).
        if session.canAddOutput(videoDataOutput) {
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            videoDataOutput.setSampleBufferDelegate(self, queue: videoStreamQueue)
            session.addOutput(videoDataOutput)

            // 只有打开这个开关，视频帧才会带上前置 RGB 相机的内参（iOS 11+）。
            if let conn = videoDataOutput.connection(with: .video) {
                if conn.isCameraIntrinsicMatrixDeliverySupported {
                    conn.isCameraIntrinsicMatrixDeliveryEnabled = true
                }
            }
        }

        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = true
        } else {
            Task { @MainActor in self.statusMessage = "错误：当前模式不支持深度数据输出" }
            session.commitConfiguration()
            return
        }

        // 选取分辨率最高的 Float32 深度格式（默认格式可能是 160×120）。
        let floatDepthFormats = device.activeFormat.supportedDepthDataFormats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }
        let bestDepthFormat = floatDepthFormats.max { lhs, rhs in
            let a = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }
        if let bestDepthFormat {
            try? device.lockForConfiguration()
            device.activeDepthDataFormat = bestDepthFormat
            device.unlockForConfiguration()

            let dims = CMVideoFormatDescriptionGetDimensions(bestDepthFormat.formatDescription)
            let label = "\(dims.width)×\(dims.height)"
            let total = Int(dims.width) * Int(dims.height)
            Task { @MainActor in
                self.depthFrameLabel = label
                self.depthPixelTotal = total
            }
        }

        session.commitConfiguration()
        session.startRunning()

        Task { @MainActor in
            self.isSessionRunning = self.session.isRunning
            self.statusMessage = "TrueDepth 相机已就绪"
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func captureFrame() {
        guard isSessionRunning else { return }
        statusMessage = "正在采集 RGB + 深度图..."

        let settings = AVCapturePhotoSettings()
        settings.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliveryEnabled
        settings.embedsDepthDataInPhoto = false
        settings.isDepthDataFiltered = false

        // Calibration delivery is a per-capture setting; the output only exposes the capability flag.
        if photoOutput.isCameraCalibrationDataDeliverySupported {
            settings.isCameraCalibrationDataDeliveryEnabled = true
        }

        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Point cloud

    /// 在深度回调线程上直接构建，避免主线程卡顿。
    nonisolated static func makePointCloud(from depthData: AVDepthData,
                                          strideStep: Int,
                                          useColor: Bool,
                                          minZ: Float,
                                          maxZ: Float) -> [PointVertex] {
        let floatDepthData = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)

        let pixelBuffer = floatDepthData.depthDataMap
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }

        var fx: Float = Float(width) * 0.8
        var fy: Float = Float(width) * 0.8
        var cx: Float = Float(width) * 0.5
        var cy: Float = Float(height) * 0.5

        if let calib = floatDepthData.cameraCalibrationData {
            let K = calib.intrinsicMatrix
            let refDim = calib.intrinsicMatrixReferenceDimensions
            let scaleX = Float(width) / Float(refDim.width)
            let scaleY = Float(height) / Float(refDim.height)
            fx = K.columns.0.x * scaleX
            fy = K.columns.1.y * scaleY
            cx = K.columns.2.x * scaleX
            cy = K.columns.2.y * scaleY
        }

        // Optional RGB lookup table for colouring.
        var rgbBuffer: CVPixelBuffer?
        if useColor { rgbBuffer = LatestVideoFrame.shared.peek() }
        if let rgb = rgbBuffer { CVPixelBufferLockBaseAddress(rgb, .readOnly) }
        defer { if let rgb = rgbBuffer { CVPixelBufferUnlockBaseAddress(rgb, .readOnly) } }

        let rgbBase = rgbBuffer.flatMap { CVPixelBufferGetBaseAddress($0) }
        let rgbW = rgbBuffer.map { CVPixelBufferGetWidth($0) } ?? 0
        let rgbH = rgbBuffer.map { CVPixelBufferGetHeight($0) } ?? 0
        let rgbBPR = rgbBuffer.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        // Depth and RGB share the same optical axis and horizontal FOV; RGB may be a wider
        // aspect (16:9) crop of the same sensor, so map by width ratio and centre it vertically.
        let colorScale = rgbW > 0 ? Float(rgbW) / Float(width) : 0
        let halfHeight = Float(height) * 0.5
        let halfRgbHeight = Float(rgbH) * 0.5
        let canSampleColor = rgbBase != nil && rgbW > 0 && rgbH > 0

        // Clockwise rotation of the visualization (see PointCloudSettings.rotationDegrees).
        let theta = PointCloudSettings.rotationDegrees * Float.pi / 180.0
        let cosT = cos(theta)
        let sinT = sin(theta)
        // Screen coords: x right, y up. Clockwise by θ: (x, y) -> (x·cosθ + y·sinθ, -x·sinθ + y·cosθ).
        let rotA = cosT, rotB = sinT, rotC = -sinT, rotD = cosT

        var vertices: [PointVertex] = []
        vertices.reserveCapacity((width / max(1, strideStep)) * (height / max(1, strideStep)))

        var v = 0
        while v < height {
            let rowPtr = baseAddress.advanced(by: v * bytesPerRow).assumingMemoryBound(to: Float32.self)
            var u = 0
            while u < width {
                let z = rowPtr[u]
                if z.isFinite && z >= minZ && z <= maxZ {
                    let x = (Float(u) - cx) * z / fx
                    let y = -((Float(v) - cy) * z / fy)

                    let px = x * rotA + y * rotB
                    let py = x * rotC + y * rotD

                    var color = Self.depthPseudoColor(t: max(0.0, min(1.0, (z - minZ) / (maxZ - minZ))))
                    if canSampleColor, let rgbBase {
                        let ru = Int(Float(u) * colorScale)
                        let rv = Int((Float(v) - halfHeight) * colorScale + halfRgbHeight)
                        if ru >= 0, ru < rgbW, rv >= 0, rv < rgbH {
                            let p = rgbBase
                                .advanced(by: rv * rgbBPR + ru * 4)
                                .assumingMemoryBound(to: UInt8.self)
                            // kCVPixelFormatType_32BGRA
                            color = SIMD4<Float>(Float(p[2]) / 255.0,
                                                 Float(p[1]) / 255.0,
                                                 Float(p[0]) / 255.0,
                                                 1.0)
                        }
                    }

                    vertices.append(PointVertex(position: SIMD3<Float>(px, py, -z), color: color))
                }
                u += strideStep
            }
            v += strideStep
        }

        return vertices
    }

    nonisolated static func depthPseudoColor(t: Float) -> SIMD4<Float> {
        let r = max(0.0, min(1.0, 1.5 - abs(4.0 * t - 3.0)))
        let g = max(0.0, min(1.0, 1.5 - abs(4.0 * t - 2.0)))
        let b = max(0.0, min(1.0, 1.5 - abs(4.0 * t - 1.0)))
        return SIMD4<Float>(r, g, b, 1.0)
    }

    // MARK: - Saving

    /// 保存根目录：`Documents/Head3D/<时间戳>/`。
    /// `Documents` 已通过 `UIFileSharingEnabled` 暴露给「文件」App（我的 iPhone › Head3D采集）。
    static func capturesRootDirectory() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let root = docs.appendingPathComponent(AppPaths.capturesFolderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    // MARK: - 额外同步目录（书签）

    static let outputBookmarkKey = "com.head3d.outputFolderBookmark"
    static let outputFolderNameKey = "com.head3d.outputFolderName"

    private var folderPicker: FolderPickerDelegate?

    /// 让用户挑一个普通文件夹（iCloud Drive / 我的 iPhone 任意位置），以后每次保存自动同步一份。
    func chooseOutputFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentProviders: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        let delegate = FolderPickerDelegate { [weak self] url in
            Task { @MainActor in self?.storeOutputFolder(url) }
        }
        folderPicker = delegate
        picker.delegate = delegate
        FilePresenter.present(picker)
    }

    func clearOutputFolder() {
        UserDefaults.standard.removeObject(forKey: Self.outputBookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.outputFolderNameKey)
        outputFolderName = nil
        statusMessage = "已取消同步目录"
    }

    private func storeOutputFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.outputBookmarkKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: Self.outputFolderNameKey)
            outputFolderName = url.lastPathComponent
            statusMessage = "已设置同步目录: \(url.lastPathComponent)"
        } catch {
            statusMessage = "设置同步目录失败: \(error.localizedDescription)"
        }
    }

    /// 把刚保存的目录复制到用户指定的文件夹，返回目标描述（用于状态栏）。
    private func mirrorToOutputFolder(_ directory: URL, files: [StoredFile]) -> String? {
        guard let data = UserDefaults.standard.data(forKey: Self.outputBookmarkKey) else { return nil }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: data,
                                   options: [],
                                   relativeTo: nil,
                                   bookmarkDataIsStale: &stale) else { return nil }

        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let dest = folder.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for file in files where file.bytes > 0 {
                let src = directory.appendingPathComponent(file.name)
                let dst = dest.appendingPathComponent(file.name)
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
            }
            return " \(folder.lastPathComponent)/\(dest.lastPathComponent)"
        } catch {
            return nil
        }
    }

    private func saveCaptureData(rgbData: Data, depthData: AVDepthData) {
        let convertedDepth: AVDepthData
        if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
            convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        } else {
            convertedDepth = depthData
        }

        let depthPixelBuffer = convertedDepth.depthDataMap
        let depthWidth = CVPixelBufferGetWidth(depthPixelBuffer)
        let depthHeight = CVPixelBufferGetHeight(depthPixelBuffer)

        let ciImage = CIImage(cvPixelBuffer: depthPixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let tiffData = ciContext.tiffRepresentation(
                of: ciImage,
                format: .Lf,
                colorSpace: colorSpace,
                options: [:]
              ) else {
            Task { @MainActor in self.statusMessage = "错误：深度 TIFF 编码失败" }
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let folderName = formatter.string(from: Date())

        guard let root = TrueDepthCaptureManager.capturesRootDirectory() else { return }
        let targetDir = root.appendingPathComponent(folderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

            let rgbURL = targetDir.appendingPathComponent("rgb.jpg")
            try rgbData.write(to: rgbURL)

            let depthURL = targetDir.appendingPathComponent("depth.tiff")
            try tiffData.write(to: depthURL)

            let savedRGBDimensions: (Int, Int)? = {
                guard let source = CGImageSourceCreateWithData(rgbData as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int,
                      let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
                return (w, h)
            }()

            let rgbFrame = LatestVideoFrame.shared.peek()
            var intrinsicsDict: [String: Any] = [
                "depth_width": depthWidth,
                "depth_height": depthHeight,
                "depth_accuracy": convertedDepth.depthDataAccuracy == .absolute ? "absolute" : "relative",
                "depth_quality": convertedDepth.depthDataQuality == .high ? "high" : "low",
                "saved_folder": AppPaths.relativePath(folder: folderName)
            ]

            if let dims = savedRGBDimensions {
                intrinsicsDict["rgb_width"] = dims.0
                intrinsicsDict["rgb_height"] = dims.1
            }
            if let frame = rgbFrame {
                // Resolution of the live RGB stream used for colour sampling (not rgb.jpg).
                intrinsicsDict["color_sampling_width"] = CVPixelBufferGetWidth(frame)
                intrinsicsDict["color_sampling_height"] = CVPixelBufferGetHeight(frame)
            }
            // 前置 RGB 相机内参（iOS 通过视频帧 attachment 提供，无对应外参 API）。
            if let rgbK = LatestVideoFrame.shared.peekIntrinsics() {
                intrinsicsDict["rgb_fx"] = rgbK.columns.0.x
                intrinsicsDict["rgb_fy"] = rgbK.columns.1.y
                intrinsicsDict["rgb_cx"] = rgbK.columns.2.x
                intrinsicsDict["rgb_cy"] = rgbK.columns.2.y
                intrinsicsDict["rgb_intrinsics_3x3"] = [
                    [rgbK.columns.0.x, rgbK.columns.1.x, rgbK.columns.2.x],
                    [rgbK.columns.0.y, rgbK.columns.1.y, rgbK.columns.2.y],
                    [rgbK.columns.0.z, rgbK.columns.1.z, rgbK.columns.2.z]
                ]
            }
            intrinsicsDict["point_cloud_rotation_deg"] = Double(TrueDepthCaptureManager.pointCloudRotationDegrees)

            if let calib = convertedDepth.cameraCalibrationData {
                let K = calib.intrinsicMatrix
                let refDim = calib.intrinsicMatrixReferenceDimensions
                let scaleX = Float(depthWidth) / Float(refDim.width)
                let scaleY = Float(depthHeight) / Float(refDim.height)

                let fx = K.columns.0.x * scaleX
                let fy = K.columns.1.y * scaleY
                let cx = K.columns.2.x * scaleX
                let cy = K.columns.2.y * scaleY

                intrinsicsDict["fx"] = fx
                intrinsicsDict["fy"] = fy
                intrinsicsDict["cx"] = cx
                intrinsicsDict["cy"] = cy
                intrinsicsDict["reference_width"] = refDim.width
                intrinsicsDict["reference_height"] = refDim.height
                intrinsicsDict["pixel_size_mm"] = calib.pixelSize

                // iOS 唯一公开的 RGB↔深度外参：AVCameraCalibrationData.extrinsicMatrix，
                // 语义是「深度相机 → 参考相机(RGB)」的 3x4 刚体变换 [R|t]（行主序导出）。
                // TrueDepth 的深度图已由系统配准到 RGB，实测为单位矩阵(即忽略也无损)。
                let E = calib.extrinsicMatrix
                intrinsicsDict["extrinsic_depth_to_rgb_3x4"] = [
                    [E.columns.0.x, E.columns.1.x, E.columns.2.x, E.columns.3.x],
                    [E.columns.0.y, E.columns.1.y, E.columns.2.y, E.columns.3.y],
                    [E.columns.0.z, E.columns.1.z, E.columns.2.z, E.columns.3.z]
                ]
            }

            let jsonData = try JSONSerialization.data(withJSONObject: intrinsicsDict, options: .prettyPrinted)
            try jsonData.write(to: targetDir.appendingPathComponent("intrinsics.json"))

            // 回读校验：确认文件真的落在磁盘上且非空。
            let stored = StoredFile.describe(targetDir, names: ["rgb.jpg", "depth.tiff", "intrinsics.json"])
            let totalBytes = stored.reduce(Int64(0)) { $0 + $1.bytes }
            let verified = stored.allSatisfy { $0.bytes > 0 }
            let mirrored = mirrorToOutputFolder(targetDir, files: stored)

            Task { @MainActor in
                self.captureCount += 1
                self.lastSavedFolder = folderName
                self.lastCaptureURL = targetDir
                self.lastStoredFiles = stored
                if verified {
                    var msg = "已保存 · \(depthWidth)×\(depthHeight) · \(StoredFile.format(totalBytes))"
                    if let mirrored { msg += " · 已同步\(mirrored)" }
                    self.statusMessage = msg
                } else {
                    self.statusMessage = "保存校验失败：有文件缺失或为空"
                }
            }
        } catch {
            Task { @MainActor in
                self.statusMessage = "保存失败: \(error.localizedDescription)"
            }
        }
    }
}

extension TrueDepthCaptureManager: AVCaptureDepthDataOutputDelegate {
    nonisolated func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                                     didOutput depthData: AVDepthData,
                                     timestamp: CMTime,
                                     connection: AVCaptureConnection) {
        guard PointCloudThrottle.shared.allow(hz: PointCloudSettings.maxRebuildHz) else { return }

        let config = PointCloudConfig.shared.current()
        let pts = TrueDepthCaptureManager.makePointCloud(from: depthData,
                                                        strideStep: config.stride,
                                                        useColor: config.useColor,
                                                        minZ: config.minZ,
                                                        maxZ: config.maxZ)

        let width = CVPixelBufferGetWidth(depthData.depthDataMap)
        let height = CVPixelBufferGetHeight(depthData.depthDataMap)
        let label = "\(width)×\(height)"
        let total = width * height

        Task { @MainActor in
            self.pointCloudRenderer.updatePoints(pts)
            self.livePointCount = pts.count
            if self.depthFrameLabel != label { self.depthFrameLabel = label }
            if self.depthPixelTotal != total { self.depthPixelTotal = total }
        }
    }
}

extension TrueDepthCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        LatestVideoFrame.shared.update(pixelBuffer, intrinsics: Self.videoFrameIntrinsics(from: sampleBuffer))
    }

    /// iOS 11+ 会把前置 RGB 相机的 `matrix_float3x3` 内参附在视频帧的 sample buffer attachment 上
    /// (`kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`，需先打开
    /// `AVCaptureConnection.isCameraIntrinsicMatrixDeliveryEnabled`)。单位是当前视频帧像素。
    nonisolated static func videoFrameIntrinsics(from sampleBuffer: CMSampleBuffer) -> simd_float3x3? {
        var data: Data?
        if let attachment = CMGetAttachment(sampleBuffer,
                                           key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                           attachmentModeOut: nil) {
            data = attachment as? Data
        }
        if data == nil,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let value = attachments.first?[kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix] {
            data = value as? Data
        }
        guard let matrixData = data, matrixData.count >= MemoryLayout<simd_float3x3>.size else { return nil }
        return matrixData.withUnsafeBytes { $0.loadUnaligned(as: simd_float3x3.self) }
    }
}

extension TrueDepthCaptureManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        if let error = error {
            Task { @MainActor in self.statusMessage = "拍照失败: \(error.localizedDescription)" }
            return
        }

        guard let rgbData = photo.fileDataRepresentation(),
              let depthData = photo.depthData else {
            Task { @MainActor in self.statusMessage = "错误：未能提取 RGB 或深度数据" }
            return
        }

        Task { @MainActor in
            self.saveCaptureData(rgbData: rgbData, depthData: depthData)
        }
    }
}
