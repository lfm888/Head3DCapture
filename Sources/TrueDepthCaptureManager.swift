import AVFoundation
import CoreImage
import ImageIO
import simd
import SwiftUI
import UIKit

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

/// 点云采样稠密度。TrueDepth 输出的是一张致密深度图（通常 640×480 = 30.7 万像素），
/// `stride` 就是每隔多少个像素取一个点：1 = 全部像素，2 = 1/4，4 = 1/16。
enum PointCloudDensity: Int, CaseIterable, Identifiable {
    case full = 1
    case medium = 2
    case low = 4

    var id: Int { rawValue }
    var stride: Int { rawValue }

    var title: String {
        switch self {
        case .full: return "满(逐像素)"
        case .medium: return "中(1/4)"
        case .low: return "低(1/16)"
        }
    }
}

/// 与可视化相关的常量（不参与保存的数据契约）。
enum PointCloudSettings {
    /// TrueDepth 深度图是横向(landscape)输出的，顺时针转 90° 与竖屏预览一致。
    static let rotationDegrees: Float = 90
    /// 只保留该距离范围内的像素（单位：米）。放得比 1.2m 宽可以看到更多背景点。
    static let minZ: Float = 0.10
    static let maxZ: Float = 1.50
    /// 点云重建频率上限（帧/秒），避免满密度时把 CPU 打满。
    static let maxRebuildHz: Double = 15
}

/// 深度回调所在的非主线程需要读到的配置副本（由 UI 的 @Published 值同步过来）。
final class PointCloudConfig {
    static let shared = PointCloudConfig()

    private let lock = NSLock()
    private var stride: Int = PointCloudDensity.full.stride
    private var useColor: Bool = true

    func update(stride newStride: Int, useColor newUseColor: Bool) {
        lock.lock()
        stride = max(1, newStride)
        useColor = newUseColor
        lock.unlock()
    }

    func current() -> (stride: Int, useColor: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stride, useColor)
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
    /// true = 彩色深度点云（用前置 RGB 给每个深度点上色）；false = 深度伪彩。
    @Published var showColorPointCloud = true {
        didSet { syncPointCloudConfig() }
    }
    /// 点云稠密度（逐像素 / 1/4 / 1/16）。
    @Published var pointCloudDensity: PointCloudDensity = .full {
        didSet { syncPointCloudConfig() }
    }
    /// 当前深度图分辨率，显示在 UI 上方便排查点数为何变少。
    @Published var depthFrameLabel = "--"

    private func syncPointCloudConfig() {
        PointCloudConfig.shared.update(stride: pointCloudDensity.stride, useColor: showColorPointCloud)
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

        if let depthFormat = device.activeFormat.supportedDepthDataFormats.first(where: {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        }) {
            try? device.lockForConfiguration()
            device.activeDepthDataFormat = depthFormat
            device.unlockForConfiguration()
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
    nonisolated static func makePointCloud(from depthData: AVDepthData, strideStep: Int, useColor: Bool) -> [PointVertex] {
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
        vertices.reserveCapacity((width / strideStep) * (height / strideStep))

        let minZ = PointCloudSettings.minZ
        let maxZ = PointCloudSettings.maxZ

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
        let root = docs.appendingPathComponent("Head3D", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
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
                "saved_folder": "Head3D/\(folderName)"
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

            Task { @MainActor in
                self.captureCount += 1
                self.lastSavedFolder = folderName
                self.lastCaptureURL = targetDir
                self.statusMessage = "已保存: Head3D/\(folderName) (\(depthWidth)x\(depthHeight))"
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
                                                         useColor: config.useColor)

        let width = CVPixelBufferGetWidth(depthData.depthDataMap)
        let height = CVPixelBufferGetHeight(depthData.depthDataMap)
        let label = "\(width)×\(height)"

        Task { @MainActor in
            self.pointCloudRenderer.updatePoints(pts)
            self.livePointCount = pts.count
            if self.depthFrameLabel != label { self.depthFrameLabel = label }
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
