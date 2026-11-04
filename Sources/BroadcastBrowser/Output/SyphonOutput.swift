import BBBridge
import CoreVideo
import Foundation
import Metal

enum SharedMetal {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
}

enum SyphonRuntime {
    static func ensureLoaded(customPath: String) throws {
        if BBSyphonServer.isAvailable() { return }
        do {
            try BBSyphonServer.loadFramework(withCustomPath: customPath.isEmpty ? nil : customPath)
        } catch {
            throw OutputStartError("\(error.localizedDescription) Place Syphon.framework in ThirdParty/ (it is bundled into the app at build time), /Library/Frameworks, or choose it in Preferences › Outputs.")
        }
    }

    static var isAvailable: Bool { BBSyphonServer.isAvailable() }
    static var loadedPath: String? { BBSyphonServer.loadedFrameworkPath() }
}

/// Publishes frames as a Syphon (Metal) server. Syphon shares GPU textures
/// between apps on this Mac, so there is no compression or bitrate.
final class SyphonOutput: OutputRuntime, @unchecked Sendable {
    private var server: BBSyphonServer?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var converter: PixelConverter?
    private var clock: OutputClock?
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "bb.syphon.poll", qos: .utility)
    var frameworkPath = ""

    override func start() throws {
        setStatus(.starting)
        try SyphonRuntime.ensureLoaded(customPath: frameworkPath)
        guard let device = SharedMetal.device, let queue = device.makeCommandQueue() else {
            throw OutputStartError("Metal is not available.")
        }
        let name = config.name.isEmpty ? "Broadcast Browser" : config.name
        guard let server = BBSyphonServer(name: name, device: device) else {
            throw OutputStartError("Could not create the Syphon server \"\(name)\".")
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache,
              let converter = PixelConverter(width: config.width, height: config.height,
                                             pixelFormat: kCVPixelFormatType_32BGRA, scaling: config.scaling, crop: config.cropRect)
        else {
            server.stop()
            throw OutputStartError("Could not prepare Syphon textures.")
        }
        self.server = server
        self.commandQueue = queue
        self.textureCache = cache
        self.converter = converter
        stats.update { $0.detail = "Syphon server: \(name)" }

        let clock = OutputClock(frameRate: config.frameRate, name: "syphon",
                                tick: { [weak self] _ in self?.publish() },
                                onDrop: { [weak self] count in self?.stats.recordDropped(count) })
        self.clock = clock
        clock.start()

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let server = self.server else { return }
            let clients = server.hasClients ? 1 : 0
            self.stats.update { $0.connections = clients }
        }
        timer.resume()
        pollTimer = timer
        setStatus(.live)
    }

    private func publish() {
        guard let server, let commandQueue, let textureCache, let converter,
              let frame = converter.frame(from: source) else { return }
        let buffer = frame.buffer
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        server.publishTexture(texture, commandBuffer: commandBuffer, flipped: config.syphonFlipped)
        commandBuffer.addCompletedHandler { _ in
            // Keep the pixel buffer and texture alive until the GPU is done.
            _ = buffer
            _ = cvTexture
        }
        commandBuffer.commit()
        stats.recordFrame(sourceCounter: frame.counter)
    }

    override func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        pollQueue.sync {}
        clock?.stop()
        clock = nil
        server?.stop()
        server = nil
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        textureCache = nil
        converter = nil
        setStatus(.idle)
    }
}
