import MetalKit
import simd
import SwiftUI

struct PointVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

class PointCloudRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var depthStencilState: MTLDepthStencilState?

    private var vertexBuffer: MTLBuffer?
    private var vertexCount: Int = 0
    private let bufferLock = NSLock()

    // 相机与交互状态（默认视角面向前方深度区域）
    var yaw: Float = 0.0
    var pitch: Float = 0.0
    var distance: Float = 0.65

    private let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float3 position [[attribute(0)]];
        float4 color [[attribute(1)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
        float pointSize [[point_size]];
    };

    struct Uniforms {
        float4x4 mvp;
        float basePointSize;
    };

    vertex VertexOut point_vertex(VertexIn in [[stage_in]],
                                  constant Uniforms &uniforms [[buffer(1)]]) {
        VertexOut out;
        out.position = uniforms.mvp * float4(in.position, 1.0);
        out.color = in.color;
        float w = max(out.position.w, 0.1);
        out.pointSize = clamp(uniforms.basePointSize / w, 2.0, 9.0);
        return out;
    }

    fragment float4 point_fragment(VertexOut in [[stage_in]]) {
        return in.color;
    }
    """

    override init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            fatalError("无法初始化 Metal 设备")
        }
        self.device = dev
        self.commandQueue = queue
        super.init()
        buildPipeline()
    }

    private func buildPipeline() {
        do {
            let library = try device.makeLibrary(source: metalShaderSource, options: nil)
            let vertexFunc = library.makeFunction(name: "point_vertex")
            let fragmentFunc = library.makeFunction(name: "point_fragment")

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunc
            desc.fragmentFunction = fragmentFunc
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.depthAttachmentPixelFormat = .depth32Float

            let vertexDesc = MTLVertexDescriptor()
            vertexDesc.attributes[0].format = .float3
            vertexDesc.attributes[0].offset = 0
            vertexDesc.attributes[0].bufferIndex = 0

            vertexDesc.attributes[1].format = .float4
            vertexDesc.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
            vertexDesc.attributes[1].bufferIndex = 0

            vertexDesc.layouts[0].stride = MemoryLayout<PointVertex>.stride
            vertexDesc.layouts[0].stepRate = 1
            vertexDesc.layouts[0].stepFunction = .perVertex

            desc.vertexDescriptor = vertexDesc
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)

            let dsDesc = MTLDepthStencilDescriptor()
            dsDesc.depthCompareFunction = .less
            dsDesc.isDepthWriteEnabled = true
            depthStencilState = device.makeDepthStencilState(descriptor: dsDesc)
        } catch {
            print("Metal 管线构建失败: \(error)")
        }
    }

    func updatePoints(_ points: [PointVertex]) {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        guard !points.isEmpty else {
            vertexCount = 0
            return
        }

        let byteLength = points.count * MemoryLayout<PointVertex>.stride
        if vertexBuffer == nil || vertexBuffer!.length < byteLength {
            vertexBuffer = device.makeBuffer(length: max(byteLength, 1024 * MemoryLayout<PointVertex>.stride),
                                             options: .storageModeShared)
        }

        if let buf = vertexBuffer {
            memcpy(buf.contents(), points, byteLength)
            vertexCount = points.count
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let pso = pipelineState else { return }

        bufferLock.lock()
        let count = vertexCount
        let buf = vertexBuffer
        bufferLock.unlock()

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        encoder.setRenderPipelineState(pso)
        if let ds = depthStencilState {
            encoder.setDepthStencilState(ds)
        }

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1.0))
        let proj = perspectiveMatrix(fovY: Float.pi / 3.0, aspect: aspect, near: 0.05, far: 5.0)

        let centerZ: Float = 0.45
        let rotY = rotationYMatrix(yaw)
        let rotX = rotationXMatrix(pitch)
        let toOrigin = translationMatrix(0, 0, -centerZ)
        let fromOrigin = translationMatrix(0, 0, centerZ)
        let cameraOffset = translationMatrix(0, 0, -distance)

        let modelView = cameraOffset * fromOrigin * rotY * rotX * toOrigin
        let mvp = proj * modelView

        struct Uniforms {
            var mvp: simd_float4x4
            var basePointSize: Float
        }
        var uniforms = Uniforms(mvp: mvp, basePointSize: 5.5)

        if count > 0, let vbuf = buf {
            encoder.setVertexBuffer(vbuf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        }

        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    private func perspectiveMatrix(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1.0 / tan(fovY * 0.5)
        let nf = 1.0 / (near - far)
        return simd_float4x4(
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, (far + near) * nf, -1),
            SIMD4<Float>(0, 0, 2.0 * far * near * nf, 0)
        )
    }

    private func translationMatrix(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    private func rotationYMatrix(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private func rotationXMatrix(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}

struct PointCloudMetalView: UIViewRepresentable {
    let renderer: PointCloudRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1.0)
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        tap.numberOfTapsRequired = 2

        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    class Coordinator: NSObject {
        let renderer: PointCloudRenderer
        private var lastPanLocation: CGPoint = .zero

        init(renderer: PointCloudRenderer) {
            self.renderer = renderer
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let loc = gesture.location(in: gesture.view)
            if gesture.state == .began {
                lastPanLocation = loc
            } else if gesture.state == .changed {
                let dx = Float(loc.x - lastPanLocation.x) * 0.008
                let dy = Float(loc.y - lastPanLocation.y) * 0.008
                renderer.yaw += dx
                renderer.pitch = max(-1.2, min(1.2, renderer.pitch + dy))
                lastPanLocation = loc
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .changed {
                renderer.distance = max(0.15, min(2.0, renderer.distance / Float(gesture.scale)))
                gesture.scale = 1.0
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            renderer.yaw = 0.0
            renderer.pitch = 0.0
            renderer.distance = 0.65
        }
    }
}
