import Metal
import MetalKit
import ModelIO
import libsumi
import CryptoKit

// Helper to silence ModelIO internal noise
func silenceStderr(_ block: () -> Void) {
    // Save the original stderr
    let originalStderr = dup(STDERR_FILENO)
    
    // Open /dev/null
    let null = open("/dev/null", O_WRONLY)
    
    // Redirect stderr to /dev/null
    dup2(null, STDERR_FILENO)
    
    // Run the noisy block
    block()
    
    // Restore stderr
    dup2(originalStderr, STDERR_FILENO)
    
    // Cleanup
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
    
    var rotationAngle: Float = 0.0
    var frameCounter: Int = 0 
    
    // SHA256 of the known good bunny.obj (Update this if you change mirrors!)
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
            print("📂 Found cached asset: \(meshURL.lastPathComponent)")
            if let data = try? Data(contentsOf: meshURL) {
                let hashed = SHA256.hash(data: data)
                let hashString = hashed.compactMap { String(format: "%02x", $0) }.joined()
                
                if !EXPECTED_BUNNY_SHA256.isEmpty && hashString != EXPECTED_BUNNY_SHA256 {
                    print("⚠️ HASH MISMATCH! Deleting corrupted/spoofed file.")
                    try? fileManager.removeItem(at: meshURL)
                    shouldDownload = true
                } else {
                    print("✅ Integrity Verified.")
                    shouldDownload = false
                }
            }
        }
        
        if shouldDownload {
            print("⬇️ Downloading Stanford Bunny...")
            if let url = URL(string: "https://raw.githubusercontent.com/alecjacobson/common-3d-test-models/master/data/bunny.obj"),
               let data = try? Data(contentsOf: url) {
                try? data.write(to: meshURL)
                print("✅ Download Complete & Saved.")
                
                let hashed = SHA256.hash(data: data)
                let hashString = hashed.compactMap { String(format: "%02x", $0) }.joined()
                print("ℹ️ NEW FILE HASH: \(hashString)")
            } else {
                print("❌ Download Failed.")
            }
        }
        
        // 3. Load Mesh
        let allocator = MTKMeshBufferAllocator(device: device)
        var mdlMesh: MDLMesh
        
        if fileManager.fileExists(atPath: meshURL.path) {
            let asset = MDLAsset(url: meshURL, vertexDescriptor: nil, bufferAllocator: allocator)
            mdlMesh = asset.childObjects(of: MDLMesh.self).first as! MDLMesh
            
            // Normalize Scale
            let boundingBox = mdlMesh.boundingBox
            let extent = boundingBox.maxBounds - boundingBox.minBounds
            let maxDimension = max(extent.x, max(extent.y, extent.z))
            if maxDimension > 0 {
                let scaleFactor = 3.0 / maxDimension 
                let center = (boundingBox.maxBounds + boundingBox.minBounds) / 2.0
                let transform = MDLTransform()
                transform.translation = -center
                transform.scale = SIMD3<Float>(scaleFactor, scaleFactor, scaleFactor)
                mdlMesh.transform = transform 
            }
            
            // SILENCE THE NOISE
            // We wrap the heavy ModelIO processing in our stderr redirector
            print("⚙️ Processing Mesh (Normals/UVs)...")
            silenceStderr {
                mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
                mdlMesh.addUnwrappedTextureCoordinates(forAttributeNamed: MDLVertexAttributeTextureCoordinate)
            }
            print("✨ Mesh Processing Complete.")
            
        } else {
            mdlMesh = MDLMesh(sphereWithExtent: [1.5, 1.5, 1.5], segments: [40, 40], inwardNormals: false, geometryType: .triangles, allocator: allocator)
        }
        
        // 4. Vertex Layout
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
        print("🗿 Mesh Ready. Vertices: \(mdlMesh.vertexCount)")
        
        // 5. Shaders
        var library: MTLLibrary?
        if let libURL = Bundle.module.url(forResource: "default", withExtension: "metallib") { try? library = device.makeLibrary(URL: libURL) }
        if library == nil {
            let source = try? String(contentsOfFile: FileManager.default.currentDirectoryPath + "/Sources/Hayagaki/Shaders.metal", encoding: .utf8)
            library = try? device.makeLibrary(source: source!, options: nil)
        }
        guard let validLib = library else { return nil }
        
        // Scene Pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = validLib.makeFunction(name: "sumi_vertex_shader")
        pipelineDescriptor.fragmentFunction = validLib.makeFunction(name: "sumi_fragment_shader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        pipelineDescriptor.vertexDescriptor = vDesc
        self.scenePipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        // Screen Pipeline
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
        
        // 6. Texture
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
        
        // 7. Argument Buffer
        self.uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: [.storageModeShared])!
        let argEncoder = pipelineDescriptor.vertexFunction!.makeArgumentEncoder(bufferIndex: 0)
        self.argumentBuffer = device.makeBuffer(length: argEncoder.encodedLength, options: [])!
        argEncoder.setArgumentBuffer(argumentBuffer, offset: 0)
        argEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
        argEncoder.setTexture(texture, index: 1)
        
        super.init()
        
        // 8. Recorder
        self.recorder = Recorder(device: device, size: renderSize)
        let videoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("hayagaki_scan_bunny.mp4")
        self.recorder?.start(outputURL: videoURL)
        metalKitView.colorPixelFormat = .bgra8Unorm
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
        
        // --- PASS 1: Render 3D Scene ---
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
        
        rotationAngle += 0.01
        frameCounter += 1
        
        // CINEMATIC ZOOM: Oscillate Z between 2.0 (close) and 4.0 (far)
        let zoomZ = 3.0 + sin(rotationAngle * 0.5) * 1.0 
        
        let viewMat = sumi.lookAt(sumi.vec3(0, 1.5, zoomZ), sumi.vec3(0, 0.5, 0), sumi.vec3(0, 1, 0))
        let model = sumi.rotate(sumi.mat4(1.0), rotationAngle, sumi.vec3(0, 1, 0))
        let aspect = Float(renderSize.width / renderSize.height)
        let projection = sumi.perspective(sumi.radians(45.0), aspect, 0.1, 100.0)
        
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
        
        // --- PASS 2: Render to Screen ---
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
