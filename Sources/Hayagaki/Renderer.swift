import Metal
import MetalKit
import ModelIO
import libsumi // Ensure this is imported
import CryptoKit

// --- FIX: C++ INTEROP ALIASING ---
// Create local aliases to resolve "sumi" ambiguity
typealias vec2 = libsumi.sumi.vec2
typealias vec3 = libsumi.sumi.vec3
typealias vec4 = libsumi.sumi.vec4
typealias mat4 = libsumi.sumi.mat4

// Helper to silence ModelIO
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

// ALIGNED STRUCT (Matches Metal Layout)
struct DemoUniforms {
    var iResolution: vec4 // Was vec3, now vec4 for alignment
    var iTimeVec: vec4    // Was float, now vec4 (time is .x)
    var iMouse: vec4
}

class Renderer: NSObject, MTKViewDelegate {
    // ... (Keep standard properties: device, commandQueue, etc.) ...
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var scenePipelineState: MTLRenderPipelineState?
    var screenPipelineState: MTLRenderPipelineState?
    var demoPipelineState: MTLRenderPipelineState?
    let depthStencilState: MTLDepthStencilState
    var mesh: MTKMesh?
    let texture: MTLTexture
    let uniformBuffer: MTLBuffer
    let demoUniformBuffer: MTLBuffer
    let argumentBuffer: MTLBuffer
    var recorder: Recorder?
    let renderSize: CGSize
    let config: HayagakiConfig
    
    // Interaction
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
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: depthDesc)!
        
        // --- SHADER LOADING (With Source Stitching) ---
        var library: MTLLibrary?
        
        // 1. Try to load pre-compiled default.metallib (likely won't exist now, which is good)
        if let libURL = Bundle.module.url(forResource: "default", withExtension: "metallib") { 
            try? library = device.makeLibrary(URL: libURL) 
        }
        
        // 2. Fallback: Runtime Stitching (The Robust Way)
        if library == nil {
            do {
                // Helper to read from Bundle
                func loadShader(_ name: String, _ ext: String) throws -> String {
                    guard let path = Bundle.module.path(forResource: name, ofType: ext) else {
                        throw NSError(domain: "Hayagaki", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing \(name).\(ext)"])
                    }
                    return try String(contentsOfFile: path, encoding: .utf8)
                }

                // Read Core Files
                let sumiCore = try loadShader("SumiCore", "h")
                var coreShaders = try loadShader("Shaders", "metal")
                
                // Read Demo File
                var demoSource = ""
                if config.demoName != "bunny" {
                    // "bubbles" -> "Demo_Bubbles"
                    let name = "Demo_" + config.demoName.prefix(1).capitalized + config.demoName.dropFirst()
                    
                    if let path = Bundle.module.path(forResource: name, ofType: "metal") {
                        demoSource = try String(contentsOfFile: path, encoding: .utf8)
                    } else {
                        print("⚠️ Demo shader not found in bundle: \(name). Using error shader.")
                    }
                }
                
                // Stitch & Clean
                coreShaders = coreShaders.replacingOccurrences(of: "#include \"SumiCore.h\"", with: "")
                demoSource = demoSource.replacingOccurrences(of: "#include \"SumiCore.h\"", with: "")
                
                let fullSource = sumiCore + "\n" + coreShaders + "\n" + demoSource
                library = try device.makeLibrary(source: fullSource, options: nil)
                
            } catch {
                print("\n💥 SHADER COMPILATION ERROR:\n\(error)\n")
            }
        }
        guard let validLib = library else { return nil }
        
        // --- ASSETS (Bunny) ---
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
        self.screenPipelineState = try! device.makeRenderPipelineState(descriptor: spDesc)

        super.init()
        
        if !config.isLive {
            self.recorder = Recorder(device: device, size: renderSize)
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(config.outputName)
            self.recorder?.start(outputURL: url)
        }
        
        // Input Handling
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
        
        // Texture setup (Recorder or Temp)
        var targetTex: MTLTexture?
        var pixBuf: CVPixelBuffer?
        if let rec = self.recorder, rec.isRecording {
            if let (t, p) = rec.getNextTexture() { targetTex = t; pixBuf = p }
        } else {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(renderSize.width), height: Int(renderSize.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; targetTex = device.makeTexture(descriptor: d)
        }
        guard let vidTex = targetTex else { return }
        
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = vidTex
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store
        
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        frameCounter += 1
        let time = Float(frameCounter) / 60.0
        
        if config.demoName == "bunny", let mesh = self.mesh, let pipe = self.scenePipelineState {
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
            // --- UPDATE: Populate Aligned Struct ---
            var uniforms = DemoUniforms(
                iResolution: vec4(Float(renderSize.width), Float(renderSize.height), 0, 0),
                iTimeVec: vec4(time, 0, 0, 0), // Time is .x
                iMouse: vec4(mousePos.x, mousePos.y, mouseClick.x, mouseClick.y)
            )
            memcpy(demoUniformBuffer.contents(), &uniforms, MemoryLayout<DemoUniforms>.size)
            
            enc.setRenderPipelineState(pipe)
            enc.setFragmentBuffer(demoUniformBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(texture, index: 1) 
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        
        enc.endEncoding()
        
        // Screen Blit
        let screenPass = view.currentRenderPassDescriptor!
        let sEnc = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass)!
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
