import Cocoa
import MetalKit

// Configuration holder
struct HayagakiConfig {
    var width: Int = 1280
    var height: Int = 720
    var isLive: Bool = true
    var useGpu: Bool = false // Always true for Metal, but tracked for flag parity
    var outputName: String = "output.mp4"
    var demoName: String = "neon" // CHANGED: Default to 'neon' instead of 'bunny'
    var allowMouse: Bool = false
}

// Global config instance
var config = HayagakiConfig()

// Argument Parsing
let args = CommandLine.arguments
let binName = URL(fileURLWithPath: args[0]).deletingPathExtension().lastPathComponent
if !binName.isEmpty { config.outputName = "\(binName).mp4" }

var i = 1
while i < args.count {
    let arg = args[i]
    if arg == "--file" {
        config.isLive = false
    }
    else if arg == "--gpu" {
        config.useGpu = true // No-op in Metal, but accepted
    } else if arg == "--mouse" {
        config.allowMouse = true
    } else if arg == "--res" {
        if i + 1 < args.count {
            let resStr = args[i+1]
            let parts = resStr.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                config.width = w
                config.height = h
            }
            i += 1
        }
    } else if arg == "--demo" {
        if i + 1 < args.count {
            config.demoName = args[i+1]
            i += 1
        }
    }
    i += 1
}

// 1. The Application Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var mtkView: MTKView!
    var renderer: Renderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the Window based on Config
        let rect = NSRect(x: 0, y: 0, width: Double(config.width), height: Double(config.height))
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        let modeStr = config.isLive ? "Live" : "Render"
        window.title = "Hayagaki \(modeStr) - \(config.demoName)"
        window.center()
        
        // Create the Metal View
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }
        
        mtkView = MTKView(frame: rect, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        
        // Initialize our custom Renderer with Config
        guard let newRenderer = Renderer(metalKitView: mtkView, config: config) else {
            fatalError("Renderer initialization failed")
        }
        
        self.renderer = newRenderer
        mtkView.delegate = renderer
        
        // Attach view to window
        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        
        // Activate app
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// 2. The Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
