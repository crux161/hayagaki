import Metal
import MetalKit
import ModelIO
import libsumi
import CryptoKit

// Fix C++ Interop Aliasing
typealias vec2 = libsumi.sumi.vec2
typealias vec3 = libsumi.sumi.vec3
typealias vec4 = libsumi.sumi.vec4
typealias mat4 = libsumi.sumi.mat4

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
    var modelMatrix: mat4
    var viewMatrix: mat4
    var projectionMatrix: mat4
}

struct DemoUniforms {
    var iResolution: vec4
    var iTimeVec: vec4
    var iMouse: vec4
}

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    var scenePipelineState: MTLRenderPipelineState?
    var screenPipelineState: MTLRenderPipelineState?
    var demoPipelineState: MTLRenderPipelineState?
    
    let depthStencilState: MTLDepthStencilState // For 3D Bunny (Less, Write)
    let noDepthState: MTLDepthStencilState      // For 2D Screens (Always, No Write) <--- NEW
    
    var mesh: MTKMesh?
    let texture: MTLTexture
    let uniformBuffer: MTLBuffer
    let demoUniformBuffer: MTLBuffer
    let argumentBuffer: MTLBuffer
    var recorder: Recorder?
    let renderSize: CGSize
    let config: HayagakiConfig
    
    var rotationX: Float = 0.0
    var rotationY: Float = 0.0
    var zoomLevel: Float = 1.0
    var meshScale: Float = 1.0
    var isDragging = false
    var frameCounter: Int = 0
    let TARGET_FRAMES = 240
    
    var mousePos: vec2 = vec2(0,0)
    var mouseClick: vec2 = vec2(0,0)

    init?(metalKitView: MTKView, config: HayagakiConfig) {
        self.config = config
        self.device = metalKitView.device!
        self.commandQueue = device.makeCommandQueue()!
        self.renderSize = CGSize(width: config.width, height: config.height)
        
        print("Initializing Engine...")
        print("Mode: \(config.isLive ? "Live" : "File") [\(config.width)x\(config.height)] Demo: \(config.demoName)")
        
        metalKitView.depthStencilPixelFormat = .depth32Float
        metalKitView.clearDepth = 1.0
        
        // 1. Standard Depth State (For 3D)
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: depthDesc)!
        
        // 2. No Depth State (For 2D Quads) <--- NEW
        let noDepthDesc = MTLDepthStencilDescriptor()
        noDepthDesc.depthCompareFunction = .always
        noDepthDesc.isDepthWriteEnabled = false
        self.noDepthState = device.makeDepthStencilState(descriptor: noDepthDesc)!
        
        // --- SHADER LOADING ---
        var library: MTLLibrary?
        if let libURL = Bundle.module.url(forResource: "default", withExtension: "metallib") {
            try? library = device.makeLibrary(URL: libURL)
        }
        
        if library == nil {
            do {
                func loadShader(_ name: String, _ ext: String) throws -> String {
                    guard let path = Bundle.module.path(forResource: name, ofType: ext) else {
                        throw NSError(domain: "Hayagaki", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing \(name).\(ext)"])
                    }
                    return try String(contentsOfFile: path, encoding: .utf8)
                }

                let sumiCore = try loadShader("SumiCore", "h")
                var coreShaders = try loadShader("Shaders", "metal")
                
                var demoSource = ""
                if config.demoName != "bunny" {
                    let name = "Demo_" + config.demoName.prefix(1).capitalized + config.demoName.dropFirst()
                    if let path = Bundle.module.path(forResource: name, ofType: "metal") {
                        demoSource = try String(contentsOfFile: path, encoding: .utf8)
                    } else {
                        print("⚠️ Demo shader not found in bundle: \(name). Using error shader.")
                    }
                }
                
                coreShaders = coreShaders.replacingOccurrences(of: "#include \"SumiCore.h\"", with: "")
                demoSource = demoSource.replacingOccurrences(of: "#include \"SumiCore.h\"", with: "")
                
                let fullSource = sumiCore + "\n" + coreShaders + "\n" + demoSource
                library = try device.makeLibrary(source: fullSource, options: nil)
            } catch {
                print("\n💥 SHADER COMPILATION ERROR:\n\(error)\n")
            }
        }
        guard let validLib = library else { return nil }
        
        // --- ASSETS ---
        let allocator = MTKMeshBufferAllocator(device: device)
        let mdlMesh = MDLMesh(sphereWithExtent: [1,1,1], segments: [10,10], inwardNormals: false, geometryType: .triangles, allocator: allocator)
        let vDesc = MTLVertexDescriptor()
        vDesc.attributes[0].format = .float3; vDesc.attributes[0].offset = 0; vDesc.attributes[0].bufferIndex = 1
        vDesc.attributes[1].format = .float3; vDesc.attributes[1].offset = 12; vDesc.attributes[1].bufferIndex = 1
        vDesc.attributes[2].format = .float2; vDesc.attributes[2].offset = 24; vDesc.attributes[2].bufferIndex = 1
        vDesc.layouts[1].stride = 32
        let mdlLayout = MTKModelIOVertexDescriptorFromMetal(vDesc)
        (mdlLayout.attributes[0] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (mdlLayout.attributes[1] as! MDLVertexAttribute).name = MDLVertexAttributeNormal
        (mdlLayout.attributes[2] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate
        mdlMesh.vertexDescriptor = mdlLayout
        self.mesh = try? MTKMesh(mesh: mdlMesh, device: device)

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 512, height: 512, mipmapped: true)
        self.texture = device.makeTexture(descriptor: texDesc)!
        
        // --- PIPELINES ---
        if config.demoName == "bunny" {
            let pipeDesc = MTLRenderPipelineDescriptor()
            pipeDesc.vertexFunction = validLib.makeFunction(name: "sumi_vertex_shader")
            pipeDesc.fragmentFunction = validLib.makeFunction(name: "sumi_fragment_shader")
            pipeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeDesc.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
            pipeDesc.vertexDescriptor = vDesc
            self.scenePipelineState = try! device.makeRenderPipelineState(descriptor: pipeDesc)
            
            self.uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: [.storageModeShared])!
            let argEncoder = pipeDesc.vertexFunction!.makeArgumentEncoder(bufferIndex: 0)
            self.argumentBuffer = device.makeBuffer(length: argEncoder.encodedLength, options: [])!
            argEncoder.setArgumentBuffer(argumentBuffer, offset: 0)
            argEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
            argEncoder.setTexture(texture, index: 1)
            self.demoUniformBuffer = device.makeBuffer(length: 16, options: [])!
        } else {
            let demoFunc = validLib.makeFunction(name: "demo_\(config.demoName)") ?? validLib.makeFunction(name: "demo_error")!
            let screenVert = validLib.makeFunction(name: "screen_vert")
            
            let pipeDesc = MTLRenderPipelineDescriptor()
            pipeDesc.vertexFunction = screenVert
            pipeDesc.fragmentFunction = demoFunc
            pipeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeDesc.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
            self.demoPipelineState = try! device.makeRenderPipelineState(descriptor: pipeDesc)
            
            self.demoUniformBuffer = device.makeBuffer(length: MemoryLayout<DemoUniforms>.stride, options: [.storageModeShared])!
            self.uniformBuffer = device.makeBuffer(length: 16, options: [])!
            self.argumentBuffer = device.makeBuffer(length: 16, options: [])!
        }
        
        // Screen Blit
        let screenLibSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct VertOut { float4 pos [[position]]; float2 uv; };
        vertex VertOut screen_vert_blit(uint vid [[vertex_id]]) {
            const float2 verts[] = { {-1, -1}, {1, -1}, {-1, 1}, {1, 1} };
            VertOut out; out.pos = float4(verts[vid], 0, 1); out.uv = verts[vid] * 0.5 + 0.5; out.uv.y = 1.0 - out.uv.y; return out;
        }
        fragment float4 screen_frag_blit(VertOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear); return tex.sample(s, in.uv);
        }
        """
        let screenLib = try! device.makeLibrary(source: screenLibSource, options: nil)
        let spDesc = MTLRenderPipelineDescriptor()
        spDesc.vertexFunction = screenLib.makeFunction(name: "screen_vert_blit")
        spDesc.fragmentFunction = screenLib.makeFunction(name: "screen_frag_blit")
        spDesc.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        // Important: Match the view's depth format, or it won't render
        spDesc.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        self.screenPipelineState = try! device.makeRenderPipelineState(descriptor: spDesc)

        super.init()
        
        if !config.isLive {
            self.recorder = Recorder(device: device, size: renderSize)
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(config.outputName)
            self.recorder?.start(outputURL: url)
        }
        
        if config.allowMouse {
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .scrollWheel, .leftMouseDown]) { [weak self] event in
                guard let self = self else { return event }
                if event.type == .scrollWheel {
                    self.zoomLevel += Float(event.deltaY) * 0.01
                    self.zoomLevel = max(0.2, min(self.zoomLevel, 5.0))
                } else if event.type == .leftMouseDragged {
                    self.isDragging = true
                    self.rotationY += Float(event.deltaX) * 0.01
                    self.rotationX += Float(event.deltaY) * 0.01
                    let loc = event.locationInWindow
                    self.mousePos = vec2(Float(loc.x), Float(self.renderSize.height - loc.y))
                } else if event.type == .leftMouseDown {
                     let loc = event.locationInWindow
                     self.mouseClick = vec2(Float(loc.x), Float(self.renderSize.height - loc.y))
                }
                return event
            }
        }
    }
    
    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = view.currentDrawable else { return }
        
        if !config.isLive && frameCounter >= TARGET_FRAMES {
            if let rec = self.recorder, rec.isRecording { rec.stop() }
            return
        }
        
        var targetTex: MTLTexture?
        var pixBuf: CVPixelBuffer?
        if let rec = self.recorder, rec.isRecording {
            if let (t, p) = rec.getNextTexture() { targetTex = t; pixBuf = p }
        } else {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(renderSize.width), height: Int(renderSize.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; targetTex = device.makeTexture(descriptor: d)
        }
        guard let vidTex = targetTex else { return }
        
        // --- PASS 1: OFFSCREEN RENDER ---
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = vidTex
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        passDescriptor.colorAttachments[0].storeAction = .store
        
        // Always creating depth texture to satisfy pipeline validation, but we might ignore it
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: Int(renderSize.width), height: Int(renderSize.height), mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        let depthTex = device.makeTexture(descriptor: depthDesc)
        passDescriptor.depthAttachment.texture = depthTex
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .dontCare
        
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        frameCounter += 1
        let time = Float(frameCounter) / 60.0
        
        // Explicitly set Viewport (Safeguard)
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(renderSize.width), height: Double(renderSize.height), znear: 0, zfar: 1))
        
        if config.demoName == "bunny", let mesh = self.mesh, let pipe = self.scenePipelineState {
            // Bunny Mode: Use Standard Depth (Less)
            enc.setDepthStencilState(depthStencilState) // <--- Standard Depth
            
            let fitDistance: Float = 4.0
            let currentDist = fitDistance / zoomLevel
            let autoSpin = isDragging ? 0.0 : Float(frameCounter) * 0.005
            
            let aspect = Float(renderSize.width / renderSize.height)
            let projection = libsumi.sumi.perspective(libsumi.sumi.radians(45.0), aspect, 0.1, 100.0)
            let viewMat = libsumi.sumi.lookAt(vec3(0, 0, currentDist), vec3(0, 0, 0), vec3(0, 1, 0))
            
            var model = mat4(1.0)
            model = libsumi.sumi.rotate(model, rotationX, vec3(1, 0, 0))
            model = libsumi.sumi.rotate(model, rotationY + autoSpin, vec3(0, 1, 0))
            model = libsumi.sumi.scale(model, vec3(meshScale, meshScale, meshScale))
            
            var uniforms = Uniforms(modelMatrix: model, viewMatrix: viewMat, projectionMatrix: projection)
            memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.size)
            
            enc.setRenderPipelineState(pipe)
            enc.setVertexBuffer(argumentBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(argumentBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(texture, index: 1)
            
            for (i, b) in mesh.vertexBuffers.enumerated() { enc.setVertexBuffer(b.buffer, offset: b.offset, index: 1+i) }
            for s in mesh.submeshes { enc.drawIndexedPrimitives(type: s.primitiveType, indexCount: s.indexCount, indexType: s.indexType, indexBuffer: s.indexBuffer.buffer, indexBufferOffset: s.indexBuffer.offset) }
            
        } else if let pipe = self.demoPipelineState {
            // Demo Mode: Use No Depth (Always Pass)
            enc.setDepthStencilState(noDepthState) // <--- FIX HERE
            
            var uniforms = DemoUniforms(
                iResolution: vec4(Float(renderSize.width), Float(renderSize.height), 0, 0),
                iTimeVec: vec4(time, 0, 0, 0),
                iMouse: vec4(mousePos.x, mousePos.y, mouseClick.x, mouseClick.y)
            )
            memcpy(demoUniformBuffer.contents(), &uniforms, MemoryLayout<DemoUniforms>.size)
            
            enc.setRenderPipelineState(pipe)
            enc.setFragmentBuffer(demoUniformBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(texture, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        
        enc.endEncoding()
        
        // --- PASS 2: BLIT TO SCREEN ---
        let screenPass = view.currentRenderPassDescriptor!
        guard let sEnc = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass) else { return }
        
        // Blit Mode: Also uses No Depth (Always Pass)
        sEnc.setDepthStencilState(noDepthState) // <--- FIX HERE
        
        sEnc.setRenderPipelineState(screenPipelineState!)
        sEnc.setFragmentTexture(vidTex, index: 0)
        sEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        sEnc.endEncoding()
        
        commandBuffer.addCompletedHandler { _ in if let r = self.recorder, let p = pixBuf { r.commitFrame(p) } }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
