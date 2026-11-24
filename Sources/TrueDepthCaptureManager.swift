import AVFoundation
import CoreImage
import SwiftUI
import UIKit

@MainActor
class TrueDepthCaptureManager: NSObject, ObservableObject {
    @Published var isSessionRunning = false
    @Published var statusMessage = "就绪"
    @Published var lastSavedFolder: String?
    @Published var captureCount = 0
    @Published var livePointCount = 0

    let session = AVCaptureSession()
    let pointCloudRenderer = PointCloudRenderer()

    private let sessionQueue = DispatchQueue(label: "com.head3d.capture.session")
    private let depthStreamQueue = DispatchQueue(label: "com.head3d.depth.stream")
    private let photoOutput = AVCapturePhotoOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    override init() {
        super.init()
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

        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = true
        } else {
            Task { @MainActor in self.statusMessage = "错误：当前模式不支持深度数据输出" }
            session.commitConfiguration()
            return
        }

        if photoOutput.isCameraCalibrationDataDeliverySupported {
            photoOutput.isCameraCalibrationDataDeliveryEnabled = true
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

    func captureFrame() {
        guard isSessionRunning else { return }
        statusMessage = "正在采集 RGB + 深度图..."

        let settings = AVCapturePhotoSettings()
        settings.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliveryEnabled
        settings.embedsDepthDataInPhoto = false
        settings.isDepthDataFiltered = false

        if photoOutput.isCameraCalibrationDataDeliveryEnabled {
            settings.isCameraCalibrationDataDeliveryEnabled = true
        }

        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func buildPointCloud(from depthData: AVDepthData, strideStep: Int = 3) -> [PointVertex] {
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

        var vertices: [PointVertex] = []
        vertices.reserveCapacity((width / strideStep) * (height / strideStep))

        let minZ: Float = 0.15
        let maxZ: Float = 1.20

        var v = 0
        while v < height {
            let rowPtr = baseAddress.advanced(by: v * bytesPerRow).assumingMemoryBound(to: Float32.self)
            var u = 0
            while u < width {
                let z = rowPtr[u]
                if z.isFinite && z >= minZ && z <= maxZ {
                    let x = (Float(u) - cx) * z / fx
                    let y = -((Float(v) - cy) * z / fy)
                    let norm = max(0.0, min(1.0, (z - minZ) / (maxZ - minZ)))
                    let color = depthPseudoColor(t: norm)
                    vertices.append(PointVertex(position: SIMD3<Float>(x, y, -z), color: color))
                }
                u += strideStep
            }
            v += strideStep
        }

        return vertices
    }

    private func depthPseudoColor(t: Float) -> SIMD4<Float> {
        let r = max(0.0, min(1.0, 1.5 - abs(4.0 * t - 3.0)))
        let g = max(0.0, min(1.0, 1.5 - abs(4.0 * t - 2.0)))
        let b = max(0.0, min(1.0, 1.5 - abs(4.0 * t - 1.0)))
        return SIMD4<Float>(r, g, b, 1.0)
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
        let folderName = "Head3D_\(formatter.string(from: Date()))"

        guard let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let targetDir = docsURL.appendingPathComponent(folderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

            let rgbURL = targetDir.appendingPathComponent("rgb.jpg")
            try rgbData.write(to: rgbURL)

            let depthURL = targetDir.appendingPathComponent("depth.tiff")
            try tiffData.write(to: depthURL)

            var intrinsicsDict: [String: Any] = [
                "depth_width": depthWidth,
                "depth_height": depthHeight,
                "depth_accuracy": convertedDepth.depthDataAccuracy == .absolute ? "absolute" : "relative",
                "depth_quality": convertedDepth.depthDataQuality == .high ? "high" : "low"
            ]

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
            }

            let jsonData = try JSONSerialization.data(withJSONObject: intrinsicsDict, options: .prettyPrinted)
            try jsonData.write(to: targetDir.appendingPathComponent("intrinsics.json"))

            Task { @MainActor in
                self.captureCount += 1
                self.lastSavedFolder = folderName
                self.statusMessage = "已保存: \(folderName) (\(depthWidth)x\(depthHeight))"
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
        Task { @MainActor in
            let pts = self.buildPointCloud(from: depthData, strideStep: 3)
            self.pointCloudRenderer.updatePoints(pts)
            self.livePointCount = pts.count
        }
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
