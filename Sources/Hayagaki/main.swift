import Cocoa
import MetalKit

struct HayagakiConfig {
    var width: Int = 960
    var height: Int = 540
    var isLive: Bool = false
    var useGpu: Bool = false
    var outputName: String = "output.mp4"
    var demoName: String = "bunny"
    var allowMouse: Bool = false // New Flag: Off by default
}

var config = HayagakiConfig()

let args = CommandLine.arguments
let binName = URL(fileURLWithPath: args[0]).deletingPathExtension().lastPathComponent
if !binName.isEmpty { config.outputName = "\(binName).mp4" }

var i = 1
while i < args.count {
    let arg = args[i]
    if arg == "--live" {
        config.isLive = true
    } else if arg == "--gpu" {
        config.useGpu = true
    } else if arg == "--mouse" {
        config.allowMouse = true // Enable mouse input
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

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var mtkView: MTKView!
    var renderer: Renderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal not supported") }
        
        mtkView = MTKView(frame: rect, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        
        guard let newRenderer = Renderer(metalKitView: mtkView, config: config) else {
            fatalError("Renderer initialization failed")
        }
        
        self.renderer = newRenderer
        mtkView.delegate = renderer
        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { return true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
