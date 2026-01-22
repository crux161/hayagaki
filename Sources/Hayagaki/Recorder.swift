import AVFoundation
import CoreVideo
import Metal

class Recorder {
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var textureCache: CVMetalTextureCache?
    
    private let device: MTLDevice
    let size: CGSize
    
    var isRecording = false
    private var frameCount: Int64 = 0
    
    init(device: MTLDevice, size: CGSize) {
        self.device = device
        self.size = size
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }
    
    func start(outputURL: URL) {
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            
            let outputSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 10_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true
            
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput!,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
            
            assetWriter?.add(assetWriterInput!)
            assetWriter?.startWriting()
            assetWriter?.startSession(atSourceTime: .zero)
            
            isRecording = true
            frameCount = 0
            print("🎥 Recording to: \(outputURL.lastPathComponent)")
            
        } catch {
            print("❌ Failed to start recording: \(error)")
        }
    }
    
    func stop() {
        guard isRecording, let writer = assetWriter, let input = assetWriterInput else { return }
        
        isRecording = false
        input.markAsFinished()
        
        // CRITICAL FIX: The app must wait for this closure before exiting!
        writer.finishWriting {
            print("💾 Video Finalized. You may now open the file.")
            exit(0) // <--- We kill the app ONLY after the file is safe.
        }
    }
    
    func getNextTexture() -> (MTLTexture, CVPixelBuffer)? {
        guard let pool = pixelBufferAdaptor?.pixelBufferPool else { return nil }
        
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut)
        
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else { return nil }
        
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            Int(size.width),
            Int(size.height),
            0,
            &cvTextureOut
        )
        
        guard let cvTexture = cvTextureOut,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        
        return (texture, pixelBuffer)
    }
    
    func commitFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRecording, let input = assetWriterInput, input.isReadyForMoreMediaData else { return }
        
        let time = CMTime(value: frameCount, timescale: 60)
        pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: time)
        frameCount += 1
    }
}
