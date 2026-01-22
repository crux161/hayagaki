import Cocoa
import MetalKit

// 1. The Application Delegate
// Handles the lifecycle of the window
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var mtkView: MTKView!
    var renderer: Renderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the Window
        let rect = NSRect(x: 0, y: 0, width: 800, height: 600)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hayagaki (速描き) - Sumi Powered"
        window.center()
        
        // Create the Metal View
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }
        
        mtkView = MTKView(frame: rect, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        
        // Initialize our custom Renderer
        guard let newRenderer = Renderer(metalKitView: mtkView) else {
            fatalError("Renderer initialization failed")
        }
        
        self.renderer = newRenderer
        mtkView.delegate = renderer
        
        // Attach view to window
        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        
        // Activate app (brings it to front in Dock)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// 2. The Entry Point
// This mimics the minimal C-style main function
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
