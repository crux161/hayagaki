import Metal
import MetalKit
import ModelIO
import libsumi
import CryptoKit

// Helper to silence ModelIO noise
func silenceStderr(_ block: () -> Void) {
    let originalStderr = dup(STDERR_FILENO)
    let null = open("/dev/null", O_WRONLY)
    dup2(null, STDERR_FILENO)
    block()
    dup2(originalStderr, STDERR_FILENO)
    close(null)
    close(originalStderr)
}

struct Uniforms {
    var modelMatrix: sumi.mat4
    var viewMatrix: sumi.mat4
    var projectionMatrix: sumi.mat4
}

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let scenePipelineState: MTLRenderPipelineState
    let screenPipelineState: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    
    var mesh: MTKMesh?
    
    let uniformBuffer: MTLBuffer
    let argumentBuffer: MTLBuffer
    let texture: MTLTexture
    
    var recorder: Recorder?
    let renderSize = CGSize(width: 1920, height: 1080)
    
    // --- INTERACTION STATE ---
    var rotationX: Float = 0.0
    var rotationY: Float = 0.0
    var zoomLevel: Float = 1.0 
    var meshScale: Float = 1.0
    var isDragging = false
    
    var frameCounter: Int = 0
    let EXPECTED_BUNNY_SHA256 = "" 
    
    init?(metalKitView: MTKView) {
        self.device = metalKitView.device!
        self.commandQueue = device.makeCommandQueue()!
        
        // 1. Setup View
        metalKitView.depthStencilPixelFormat = .depth32Float
        metalKitView.clearDepth = 1.0
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)!
        
        // 2. Asset Management
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let meshURL = docs.appendingPathComponent("bunny.obj")
        
        var shouldDownload = true
        if fileManager.fileExists(atPath: meshURL.path) {
            print("📂 Found cached asset.")
            if let data = try? Data(contentsOf: meshURL) {
                let hashed = SHA256.hash(data: data)
                let hashString = hashed.compactMap { String(format: "%02x", $0) }.joined()
                if !EXPECTED_BUNNY_SHA256.isEmpty && hashString != EXPECTED_BUNNY_SHA256 {
                    try? fileManager.removeItem(at: meshURL)
                    shouldDownload = true
                } else {
                    shouldDownload = false
                }
            }
        }
        
        if shouldDownload {
            print("⬇️ Downloading Bunny...")
            if let url = URL(string: "https://raw.githubusercontent.com/alecjacobson/common-3d-test-models/master/data/bunny.obj"),
               let data = try? Data(contentsOf: url) {
                try? data.write(to: meshURL)
                print("✅ Download Complete.")
            }
        }
        
        // 3. Load Mesh
        let allocator = MTKMeshBufferAllocator(device: device)
        var mdlMesh: MDLMesh
        
        if fileManager.fileExists(atPath: meshURL.path) {
            let asset = MDLAsset(url: meshURL, vertexDescriptor: nil, bufferAllocator: allocator)
            mdlMesh = asset.childObjects(of: MDLMesh.self).first as! MDLMesh
            
            let boundingBox = mdlMesh.boundingBox
            let extent = boundingBox.maxBounds - boundingBox.minBounds
            let maxDim = max(extent.x, max(extent.y, extent.z))
            
            if maxDim > 0 {
                self.meshScale = 2.0 / maxDim 
                print("📏 Mesh Size: \(maxDim). Scale: \(self.meshScale)")
            }
            
            let center = (boundingBox.maxBounds + boundingBox.minBounds) / 2.0
            let centering = MDLTransform()
            centering.translation = -center
            mdlMesh.transform = centering 
            
            silenceStderr {
                mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
                mdlMesh.addUnwrappedTextureCoordinates(forAttributeNamed: MDLVertexAttributeTextureCoordinate)
            }
        } else {
            mdlMesh = MDLMesh(sphereWithExtent: [1.0, 1.0, 1.0], segments: [40, 40], inwardNormals: false, geometryType: .triangles, allocator: allocator)
            self.meshScale = 1.0
        }
        
        let vDesc = MTLVertexDescriptor()
        vDesc.attributes[0].format = .float3; vDesc.attributes[0].offset = 0; vDesc.attributes[0].bufferIndex = 1
        vDesc.attributes[1].format = .float3; vDesc.attributes[1].offset = 12; vDesc.attributes[1].bufferIndex = 1
        vDesc.attributes[2].format = .float2; vDesc.attributes[2].offset = 24; vDesc.attributes[2].bufferIndex = 1
        vDesc.layouts[1].stride = 32
        vDesc.layouts[1].stepRate = 1
        vDesc.layouts[1].stepFunction = .perVertex
        
        let mdlLayout = MTKModelIOVertexDescriptorFromMetal(vDesc)
        (mdlLayout.attributes[0] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (mdlLayout.attributes[1] as! MDLVertexAttribute).name = MDLVertexAttributeNormal
        (mdlLayout.attributes[2] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate
        mdlMesh.vertexDescriptor = mdlLayout
        
        self.mesh = try? MTKMesh(mesh: mdlMesh, device: device)
        
        // 4. Shaders & Pipelines
        var library: MTLLibrary?
        if let libURL = Bundle.module.url(forResource: "default", withExtension: "metallib") { try? library = device.makeLibrary(URL: libURL) }
        if library == nil {
            let source = try? String(contentsOfFile: FileManager.default.currentDirectoryPath + "/Sources/Hayagaki/Shaders.metal", encoding: .utf8)
            library = try? device.makeLibrary(source: source!, options: nil)
        }
        guard let validLib = library else { return nil }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = validLib.makeFunction(name: "sumi_vertex_shader")
        pipelineDescriptor.fragmentFunction = validLib.makeFunction(name: "sumi_fragment_shader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        pipelineDescriptor.vertexDescriptor = vDesc
        self.scenePipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        let screenShaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct VertOut { float4 pos [[position]]; float2 uv; };
        vertex VertOut screen_vert(uint vid [[vertex_id]]) {
            const float2 verts[] = { {-1, -1}, {1, -1}, {-1, 1}, {1, 1} };
            VertOut out;
            out.pos = float4(verts[vid], 0, 1);
            out.uv = verts[vid] * 0.5 + 0.5;
            out.uv.y = 1.0 - out.uv.y;
            return out;
        }
        fragment float4 screen_frag(VertOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear);
            return tex.sample(s, in.uv);
        }
        """
        let screenLib = try! device.makeLibrary(source: screenShaderSource, options: nil)
        let screenPipelineDesc = MTLRenderPipelineDescriptor()
        screenPipelineDesc.vertexFunction = screenLib.makeFunction(name: "screen_vert")
        screenPipelineDesc.fragmentFunction = screenLib.makeFunction(name: "screen_frag")
        screenPipelineDesc.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        self.screenPipelineState = try! device.makeRenderPipelineState(descriptor: screenPipelineDesc)
        
        // 5. Texture
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 512, height: 512, mipmapped: true)
        texDesc.usage = [.shaderRead]
        self.texture = device.makeTexture(descriptor: texDesc)!
        var pixels = [UInt8](repeating: 0, count: 512*512*4)
        for i in 0..<(512*512) {
            let x = i % 512; let y = i / 512
            let check = ((x/32)%2) ^ ((y/32)%2)
            let v: UInt8 = (check == 0) ? 240 : 50
            let off = i*4
            pixels[off] = v; pixels[off+1] = v; pixels[off+2] = v; pixels[off+3] = 255
        }
        self.texture.replace(region: MTLRegionMake2D(0,0,512,512), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 512*4)
        
        // 6. Buffers
        self.uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: [.storageModeShared])!
        let argEncoder = pipelineDescriptor.vertexFunction!.makeArgumentEncoder(bufferIndex: 0)
        self.argumentBuffer = device.makeBuffer(length: argEncoder.encodedLength, options: [])!
        argEncoder.setArgumentBuffer(argumentBuffer, offset: 0)
        argEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
        argEncoder.setTexture(texture, index: 1)
        
        super.init()
        
        // 7. Recorder
        self.recorder = Recorder(device: device, size: renderSize)
        let videoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("hayagaki_interactive.mp4")
        self.recorder?.start(outputURL: videoURL)
        metalKitView.colorPixelFormat = .bgra8Unorm
        
        // 8. ROBUST INPUT HANDLING (Global Monitor)
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .scrollWheel]) { [weak self] event in
            guard let self = self else { return event }
            
            if event.type == .scrollWheel {
                self.zoomLevel += Float(event.deltaY) * 0.01
                self.zoomLevel = max(0.2, min(self.zoomLevel, 5.0))
            } else if event.type == .leftMouseDragged {
                self.isDragging = true
                self.rotationY += Float(event.deltaX) * 0.01
                self.rotationX += Float(event.deltaY) * 0.01
            }
            
            return event
        }
    }
    
    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = view.currentDrawable,
              let mesh = self.mesh,
              let recorder = self.recorder else { return }
        
        if frameCounter >= 600 {
            if recorder.isRecording {
                print("🛑 Limit reached. Finalizing...")
                recorder.stop()
            }
            return
        }

        guard recorder.isRecording, let (videoTexture, pixelBuffer) = recorder.getNextTexture() else { return }
        
        // Pass 1: Render 3D Scene
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = videoTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        passDescriptor.colorAttachments[0].storeAction = .store
        
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: Int(renderSize.width), height: Int(renderSize.height), mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        let depthTex = device.makeTexture(descriptor: depthDesc)
        passDescriptor.depthAttachment.texture = depthTex
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .dontCare
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        
        frameCounter += 1
        
        // CAMERA LOGIC
        // Default fit distance set to 4.0 for a more "zoomed out" default
        let fitDistance: Float = 4.0 
        let currentDist = fitDistance / zoomLevel
        
        // Auto-spin only if not dragging
        let autoSpin = isDragging ? 0.0 : Float(frameCounter) * 0.005
        
        let aspect = Float(renderSize.width / renderSize.height)
        let projection = sumi.perspective(sumi.radians(45.0), aspect, 0.1, 100.0)
        let viewMat = sumi.lookAt(sumi.vec3(0, 0, currentDist), sumi.vec3(0, 0, 0), sumi.vec3(0, 1, 0))
        
        var model = sumi.mat4(1.0)
        model = sumi.rotate(model, rotationX, sumi.vec3(1, 0, 0))
        model = sumi.rotate(model, rotationY + autoSpin, sumi.vec3(0, 1, 0))
        model = sumi.scale(model, sumi.vec3(meshScale, meshScale, meshScale))
        
        var uniforms = Uniforms(modelMatrix: model, viewMatrix: viewMat, projectionMatrix: projection)
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.size)
        
        encoder.setDepthStencilState(depthStencilState)
        encoder.setRenderPipelineState(scenePipelineState)
        encoder.setCullMode(.back)
        
        encoder.setVertexBuffer(argumentBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(argumentBuffer, offset: 0, index: 0)
        encoder.useResource(uniformBuffer, usage: .read, stages: [.vertex, .fragment])
        encoder.useResource(texture, usage: .read, stages: .fragment)
        
        for (i, b) in mesh.vertexBuffers.enumerated() { encoder.setVertexBuffer(b.buffer, offset: b.offset, index: 1+i) }
        for s in mesh.submeshes { encoder.drawIndexedPrimitives(type: s.primitiveType, indexCount: s.indexCount, indexType: s.indexType, indexBuffer: s.indexBuffer.buffer, indexBufferOffset: s.indexBuffer.offset) }
        
        encoder.endEncoding()
        
        // Pass 2: Render to Screen
        let screenPass = view.currentRenderPassDescriptor!
        guard let screenEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass) else { return }
        screenEncoder.setRenderPipelineState(screenPipelineState)
        screenEncoder.setFragmentTexture(videoTexture, index: 0)
        screenEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        screenEncoder.endEncoding()
        
        commandBuffer.addCompletedHandler { _ in recorder.commitFrame(pixelBuffer) }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
