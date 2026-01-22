import Metal
import MetalKit
import libsumi

// Must match 'struct Uniforms' in Metal
struct Uniforms {
    var modelMatrix: sumi.mat4
    var viewMatrix: sumi.mat4
    var projectionMatrix: sumi.mat4
}

// Must match 'struct SumiVertex' in Metal
struct SwiftVertex {
    var position: sumi.vec3
    var color: sumi.vec3
}

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    
    let vertexBuffer: MTLBuffer
    let uniformBuffer: MTLBuffer
    
    var rotationAngle: Float = 0.0
    
    // Geometry: A Cube (36 vertices for 12 triangles)
    let vertices: [SwiftVertex] = [
        // Front Face
        SwiftVertex(position: sumi.vec3(-0.5, -0.5,  0.5), color: sumi.vec3(1, 0, 0)),
        SwiftVertex(position: sumi.vec3( 0.5, -0.5,  0.5), color: sumi.vec3(0, 1, 0)),
        SwiftVertex(position: sumi.vec3( 0.5,  0.5,  0.5), color: sumi.vec3(0, 0, 1)),
        SwiftVertex(position: sumi.vec3(-0.5, -0.5,  0.5), color: sumi.vec3(1, 0, 0)),
        SwiftVertex(position: sumi.vec3( 0.5,  0.5,  0.5), color: sumi.vec3(0, 0, 1)),
        SwiftVertex(position: sumi.vec3(-0.5,  0.5,  0.5), color: sumi.vec3(1, 1, 0)),

        // Back Face
        SwiftVertex(position: sumi.vec3(-0.5, -0.5, -0.5), color: sumi.vec3(1, 0, 1)),
        SwiftVertex(position: sumi.vec3(-0.5,  0.5, -0.5), color: sumi.vec3(0, 1, 1)),
        SwiftVertex(position: sumi.vec3( 0.5,  0.5, -0.5), color: sumi.vec3(1, 1, 1)),
        SwiftVertex(position: sumi.vec3(-0.5, -0.5, -0.5), color: sumi.vec3(1, 0, 1)),
        SwiftVertex(position: sumi.vec3( 0.5,  0.5, -0.5), color: sumi.vec3(1, 1, 1)),
        SwiftVertex(position: sumi.vec3( 0.5, -0.5, -0.5), color: sumi.vec3(0, 0, 0)),
        
        // Top Face
        SwiftVertex(position: sumi.vec3(-0.5,  0.5, -0.5), color: sumi.vec3(0, 1, 0)),
        SwiftVertex(position: sumi.vec3(-0.5,  0.5,  0.5), color: sumi.vec3(0, 1, 0)),
        SwiftVertex(position: sumi.vec3( 0.5,  0.5,  0.5), color: sumi.vec3(0, 1, 0)),
        SwiftVertex(position: sumi.vec3(-0.5,  0.5, -0.5), color: sumi.vec3(0, 1, 0)),
        SwiftVertex(position: sumi.vec3( 0.5,  0.5,  0.5), color: sumi.vec3(0, 1, 0)),
        SwiftVertex(position: sumi.vec3( 0.5,  0.5, -0.5), color: sumi.vec3(0, 1, 0)),

        // Bottom Face
        SwiftVertex(position: sumi.vec3(-0.5, -0.5, -0.5), color: sumi.vec3(1, 0.5, 0)),
        SwiftVertex(position: sumi.vec3( 0.5, -0.5, -0.5), color: sumi.vec3(1, 0.5, 0)),
        SwiftVertex(position: sumi.vec3( 0.5, -0.5,  0.5), color: sumi.vec3(1, 0.5, 0)),
        SwiftVertex(position: sumi.vec3(-0.5, -0.5, -0.5), color: sumi.vec3(1, 0.5, 0)),
        SwiftVertex(position: sumi.vec3( 0.5, -0.5,  0.5), color: sumi.vec3(1, 0.5, 0)),
        SwiftVertex(position: sumi.vec3(-0.5, -0.5,  0.5), color: sumi.vec3(1, 0.5, 0)),

        // Right Face
        SwiftVertex(position: sumi.vec3( 0.5, -0.5, -0.5), color: sumi.vec3(0, 0, 1)),
        SwiftVertex(position: sumi.vec3( 0.5,  0.5, -0.5), color: sumi.vec3(0, 0, 1)),
        SwiftVertex(position: sumi.vec3( 0.5,  0.5,  0.5), color: sumi.vec3(0, 0, 1)),
        SwiftVertex(position: sumi.vec3( 0.5, -0.5, -0.5), color: sumi.vec3(0, 0, 1)),
        SwiftVertex(position: sumi.vec3( 0.5,  0.5,  0.5), color: sumi.vec3(0, 0, 1)),
        SwiftVertex(position: sumi.vec3( 0.5, -0.5,  0.5), color: sumi.vec3(0, 0, 1)),

        // Left Face
        SwiftVertex(position: sumi.vec3(-0.5, -0.5, -0.5), color: sumi.vec3(1, 0, 0)),
        SwiftVertex(position: sumi.vec3(-0.5, -0.5,  0.5), color: sumi.vec3(1, 0, 0)),
        SwiftVertex(position: sumi.vec3(-0.5,  0.5,  0.5), color: sumi.vec3(1, 0, 0)),
        SwiftVertex(position: sumi.vec3(-0.5, -0.5, -0.5), color: sumi.vec3(1, 0, 0)),
        SwiftVertex(position: sumi.vec3(-0.5,  0.5,  0.5), color: sumi.vec3(1, 0, 0)),
        SwiftVertex(position: sumi.vec3(-0.5,  0.5, -0.5), color: sumi.vec3(1, 0, 0))
    ]
    
    init?(metalKitView: MTKView) {
        self.device = metalKitView.device!
        self.commandQueue = device.makeCommandQueue()!
        
        // 1. Configure the View for 3D
        metalKitView.depthStencilPixelFormat = .depth32Float
        metalKitView.clearDepth = 1.0
        
        // 2. Create Depth State
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)!
        
        // --- JIT Library Loader ---
        var library: MTLLibrary?
        if let libURL = Bundle.module.url(forResource: "default", withExtension: "metallib") {
            try? library = device.makeLibrary(URL: libURL)
        }
        
        // JIT Fallback
        if library == nil {
            let cwd = FileManager.default.currentDirectoryPath
            let sourcePath = cwd + "/Sources/Hayagaki/Shaders.metal"
            if let source = try? String(contentsOfFile: sourcePath, encoding: .utf8) {
                library = try? device.makeLibrary(source: source, options: nil)
            }
        }
        
        guard let validLib = library else { return nil }
        
        // --- Pipeline Setup ---
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = validLib.makeFunction(name: "sumi_vertex_shader")
        pipelineDescriptor.fragmentFunction = validLib.makeFunction(name: "sumi_fragment_shader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        
        // IMPORTANT: Tell pipeline about depth format
        pipelineDescriptor.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        
        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Pipeline failure: \(error)")
            return nil
        }
        
        // --- Buffers ---
        let vertexSize = vertices.count * MemoryLayout<SwiftVertex>.stride
        self.vertexBuffer = device.makeBuffer(bytes: vertices, length: vertexSize, options: [])!
        
        self.uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: [.storageModeShared])!
        
        super.init()
    }
    
    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        
        // --- Physics / Math Update ---
        rotationAngle += 0.02
        
        // 1. Projection (Perspective)
        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        let projection = sumi.perspective(sumi.radians(45.0), aspect, 0.1, 100.0)

        // 2. View (Camera)
        let viewMat = sumi.lookAt(sumi.vec3(0, 1.5, 3), sumi.vec3(0, 0, 0), sumi.vec3(0, 1, 0))

        // 3. Model (Spinning Cube)
        // Rotate around (1, 1, 0) axis to see it tumble
        let model = sumi.rotate(sumi.mat4(1.0), rotationAngle, sumi.vec3(1.0, 1.0, 0.0))

        // 4. Send to GPU
        let uniforms = Uniforms(modelMatrix: model, viewMatrix: viewMat, projectionMatrix: projection)
        
        let bufferPointer = uniformBuffer.contents().bindMemory(to: Uniforms.self, capacity: 1)
        bufferPointer.pointee = uniforms
        
        // --- Draw Call ---
        encoder.setDepthStencilState(depthStencilState) // Enable Depth Test
        encoder.setRenderPipelineState(pipelineState)
        
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        
        encoder.endEncoding()
        commandBuffer.present(view.currentDrawable!)
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
}
