import AppKit
import AVFoundation
import BBBridge
import CoreImage
import WebKit

/// Automated smoke test, enabled with BB_SELFTEST=1 (output dir in
/// BB_SELFTEST_OUT). Uses snapshot capture so no permissions are needed,
/// exercises customization, NDI and recording, writes PNGs + report.json, then quits.
@MainActor
enum SelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["BB_SELFTEST"] != nil }

    static var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["BB_SELFTEST_OUT"] ?? NSTemporaryDirectory() + "bb-selftest"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var report: [String: Any] = [:]

    static func run(delegate: AppDelegate) {
        Task { @MainActor in
            await perform(delegate: delegate)
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: outputDirectory.appendingPathComponent("report.json"))
            NSLog("[SelfTest] done: \(outputDirectory.path)")
            exit(0)
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func evaluate(_ webView: WKWebView, _ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                continuation.resume(returning: result ?? error.map { "error: \($0.localizedDescription)" })
            }
        }
    }

    private static let testPage = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Self Test Scoreboard</title>
    <style>
      body { margin: 0; font-family: Helvetica, Arial, sans-serif; background: linear-gradient(135deg, #123 0%, #345 100%); color: #eee; height: 100vh; overflow: hidden; }
      #title { font-size: 64px; padding: 40px 60px 10px; }
      .board { display: flex; gap: 40px; padding: 20px 60px; }
      .team { background: rgba(0,0,0,0.35); padding: 30px 50px; border-radius: 16px; }
      .team .name { font-size: 36px; }
      .team .score { font-size: 140px; font-weight: 700; }
      #ticker { position: absolute; bottom: 0; left: 0; right: 0; background: #c00; font-size: 40px; padding: 18px 60px; }
      #clock { position: absolute; top: 40px; right: 60px; font-size: 48px; }
      .corner { position: absolute; width: 40px; height: 40px; background: #0f0; }
    </style></head>
    <body>
      <div class="corner" style="left:0;top:0"></div><div class="corner" style="right:0;top:0"></div>
      <div class="corner" style="left:0;bottom:0;background:#00f"></div><div class="corner" style="right:0;bottom:0;background:#ff0"></div>
      <div id="title">Championship Final</div>
      <div id="clock">00:00</div>
      <div class="board">
        <div class="team"><div class="name">Home</div><div class="score" id="home">3</div></div>
        <div class="team"><div class="name">Away</div><div class="score">2</div></div>
      </div>
      <div id="ticker">Breaking: Broadcast Browser self test running</div>
      <input id="name" type="text" style="position:absolute; left:1100px; top:400px; width:400px; height:50px; font-size:30px">
      <select id="pick" style="position:absolute; left:1100px; top:480px; width:300px; height:50px; font-size:24px"><option>One</option><option>Two</option><option>Three</option></select>
      <a id="lnk" href="https://example.com/" style="position:absolute; left:1100px; top:560px; font-size:30px; color:#9cf">Example link</a>
      <div id="scroller" style="position:absolute; left:1100px; top:620px; width:400px; height:150px; overflow:auto; background:#222"><div style="height:1000px">scroll me</div></div>
      <script>
        var t = 0; setInterval(function(){ t++; document.getElementById('clock').textContent = '00:' + String(t % 60).padStart(2,'0'); }, 1000);
      </script>
    </body></html>
    """

    private static func perform(delegate: AppDelegate) async {
        let app = AppModel.shared
        var prefs = app.preferences
        prefs.captureEngine = .snapshot
        prefs.confirmCloseWhileLive = false
        prefs.autosaveRecovery = false
        prefs.audioSource = .testTone
        prefs.oscEnabled = true
        prefs.oscInputPort = 39300
        prefs.oscFeedbackEnabled = true
        prefs.oscFeedbackHost = "127.0.0.1"
        prefs.oscFeedbackPort = 39301
        prefs.oscFeedbackIntervalMs = 500
        prefs.oscBooleanStyle = .oscBool

        // Collect OSC feedback on the feedback port.
        let feedbackLock = NSLock()
        var feedback: [OSCMessage] = []
        let feedbackReceiver = OSCUDPReceiver()
        feedbackReceiver.onPacket = { messages, _, _ in feedbackLock.sync { feedback.append(contentsOf: messages) } }
        try? feedbackReceiver.start(port: 39301)
        app.preferences = prefs

        let out = outputDirectory
        let pageURL = out.appendingPathComponent("testpage.html")
        try? testPage.write(to: pageURL, atomically: true, encoding: .utf8)

        // Start page snapshot
        delegate.showStartWindow()
        await sleep(0.8)
        snapshot(delegate.startWindow, named: "start.png")

        // Session with two tabs
        let session = SessionController(name: "Self Test")
        let tab = session.newTab(url: pageURL.absoluteString)
        session.newTab(url: "about:blank", select: false)
        delegate.present(session)
        session.select(tab)
        await sleep(3.0)

        let viewport = await evaluate(tab.webView, "window.__bb ? window.__bb.viewport() : null")
        report["viewport"] = viewport
        report["pageZoom"] = tab.webView.pageZoom
        report["renderWindowFrame"] = NSStringFromRect(tab.host.window.frame)
        report["renderWindowBacking"] = tab.host.window.backingScaleFactor
        let primary = NSScreen.screens.first?.frame ?? .zero
        report["canvasWindowVisibleArea"] = NSStringFromRect(tab.host.window.frame.intersection(primary))
        report["canvasWindowOnScreen"] = tab.host.window.screen != nil
        report["mainWindowFrame"] = NSStringFromRect(delegate.mainController?.window?.frame ?? .zero)
        let otherTab = session.tabs.first { $0 !== tab }
        report["otherCanvasVisibleArea"] = NSStringFromRect(otherTab?.host.window.frame.intersection(primary) ?? .zero)

        // Customization: style + Google-free font + hide
        tab.setStyle(selector: "#title", property: "color", value: "rgb(255, 0, 0)")
        tab.setStyle(selector: "#title", property: "font-size", value: "96px")
        tab.setStyle(selector: "#ticker", property: "background-color", value: "#004488")
        await sleep(0.6)
        report["titleColor"] = await evaluate(tab.webView, "getComputedStyle(document.getElementById('title')).color")
        report["titleSize"] = await evaluate(tab.webView, "getComputedStyle(document.getElementById('title')).fontSize")
        report["compiledCSS"] = StyleCompiler.css(for: tab.customization, transparent: false)

        // Picker selection path
        tab.selectElement(selector: "#home")
        await sleep(0.5)
        report["pickedSelector"] = tab.picked?.selector
        report["pickedClassSelector"] = tab.picked?.classSelector
        report["pickedMatchCount"] = tab.picked?.matchCount
        report["pickedFontSize"] = tab.picked?.computed["font-size"]
        tab.webView.evaluateJavaScript("window.__bb.selectAtPoint(1500, 1040)", completionHandler: nil)
        await sleep(0.4)
        report["pickedAtPoint"] = tab.picked?.selector

        // Reload keeps customizations
        tab.reload()
        await sleep(2.0)
        report["titleColorAfterReload"] = await evaluate(tab.webView, "getComputedStyle(document.getElementById('title')).color")

        // Input pass-through from the main window's canvas view.
        _ = await evaluate(tab.webView, "window.__entered = 0; document.getElementById('lnk').addEventListener('mouseenter', function(){ __entered++ }); true")
        let savedSelectHandler = tab.onSelectMenu
        let savedCursorHandler = tab.onCursorChange
        var selectMenuID: String?
        var selectOptionCount = 0
        var cursors: [String] = []
        tab.onSelectMenu = { id, options, _, _ in
            selectMenuID = id
            selectOptionCount = options.count
        }
        tab.onCursorChange = { cursors.append($0) }
        tab.forwardMouse(.leftMouseDown, canvasPoint: CGPoint(x: 1300, y: 425))
        tab.forwardMouse(.leftMouseUp, canvasPoint: CGPoint(x: 1300, y: 425))
        await sleep(0.4)
        for character in "Hello" {
            let text = String(character)
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: tab.host.window.windowNumber, context: nil, characters: text,
                                            charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0) {
                tab.host.window.sendEvent(event)
            }
        }
        await sleep(0.4)
        let typed = await evaluate(tab.webView, "document.getElementById('name').value")
        let focused = await evaluate(tab.webView, "document.activeElement && document.activeElement.id")
        tab.forwardMouse(.leftMouseDown, canvasPoint: CGPoint(x: 1250, y: 505))
        tab.forwardMouse(.leftMouseUp, canvasPoint: CGPoint(x: 1250, y: 505))
        await sleep(0.4)
        if let selectMenuID { tab.chooseSelectOption(id: selectMenuID, index: 2) }
        await sleep(0.3)
        let selectValue = await evaluate(tab.webView, "document.getElementById('pick').value")
        tab.forwardScroll(canvasPoint: CGPoint(x: 1300, y: 700), deltaX: 0, deltaY: 200)
        await sleep(0.3)
        let scrollTop = await evaluate(tab.webView, "document.getElementById('scroller').scrollTop")
        tab.forwardMouse(.mouseMoved, canvasPoint: CGPoint(x: 1150, y: 578))
        await sleep(0.3)
        var linkUnderPointer = ""
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            tab.contextInfo(atCanvas: CGPoint(x: 1150, y: 578)) { info in
                linkUnderPointer = info.link
                continuation.resume()
            }
        }
        let hoverEntered = await evaluate(tab.webView, "__entered")
        report["inputForwarding"] = [
            "appActive": NSApp.isActive,
            "hoverMouseEnter": hoverEntered ?? "nil",
            "typedText": typed ?? "nil",
            "focusedElement": focused ?? "nil",
            "canvasWindowWasKey": tab.host.window.isKeyWindow,
            "selectMenuShown": selectMenuID != nil,
            "selectOptions": selectOptionCount,
            "selectValueAfterChoice": selectValue ?? "nil",
            "nestedScrollTop": scrollTop ?? "nil",
            "linkUnderPointer": linkUnderPointer,
            "cursorsSeen": cursors,
        ]
        tab.onSelectMenu = savedSelectHandler
        tab.onCursorChange = savedCursorHandler
        delegate.mainController?.window?.makeKey()

        // Outputs: NDI + Record
        var ndi = tab.addOutput(kind: .ndi)
        ndi.name = "BB SelfTest"
        ndi.size = PixelSize(1280, 720)
        ndi.frameRate = .fps29_97
        ndi.audioEnabled = true
        var record = tab.addOutput(kind: .record)
        record.recordFolder = out.path
        record.size = PixelSize(1280, 720)
        record.frameRate = .fps29_97
        record.codec = .h264
        record.audioEnabled = true
        record.cropEnabled = true
        record.cropX = 0
        record.cropY = 0
        record.cropWidth = 960
        record.cropHeight = 540
        var syphon = tab.addOutput(kind: .syphon)
        syphon.name = "BB SelfTest Syphon"
        syphon.size = PixelSize(1280, 720)
        syphon.frameRate = .fps29_97
        tab.outputs = tab.outputs.map { config in
            if config.id == ndi.id { return ndi }
            if config.id == record.id { return record }
            if config.id == syphon.id { return syphon }
            return config
        }
        tab.goLive()
        await sleep(1.0)
        session.sidebarPanel = .outputs
        await sleep(3.0)

        var outputsReport: [[String: Any]] = []
        for config in tab.outputs {
            let stats = tab.runtime(for: config.id)?.stats.snapshot()
            outputsReport.append([
                "kind": config.kind.rawValue,
                "status": stats.map { "\($0.status)" } ?? "none",
                "framesSent": stats?.framesSent ?? 0,
                "fps": stats?.measuredFPS ?? 0,
                "dropped": stats?.framesDropped ?? 0,
                "unique": stats?.uniqueSourceFrames ?? 0,
                "detail": stats?.detail ?? "",
            ])
        }
        report["outputs"] = outputsReport
        report["captureFPS"] = tab.frameSource.measuredFPS
        report["captureEngine"] = tab.captureEngineName
        report["ndiSourcesSeen"] = NDIRuntime.isLoaded ? NDIRuntime.findSources(waitMs: 2500) : ["ndi not loaded"]
        report["ndiLibrary"] = NDIRuntime.libraryPath
        report["ndiVersion"] = NDIRuntime.version
        report["syphonServersVisible"] = BBSyphonServer.visibleServerNames()
        let audioStatus = AudioHub.shared.status()
        report["audio"] = ["running": audioStatus.running, "source": audioStatus.source.rawValue, "peakL": audioStatus.peakLdB,
                           "peakR": audioStatus.peakRdB, "consumers": audioStatus.consumers, "status": audioStatus.text]

        // Crop path through the converter (top-left quarter of the canvas -> 640x360 2vuy)
        if let latest = tab.frameSource.latest()?.buffer,
           let cropper = PixelConverter(width: 640, height: 360, pixelFormat: kCVPixelFormatType_32BGRA, scaling: .fit,
                                        crop: CGRect(x: 0, y: 0, width: 960, height: 540)),
           let cropped = cropper.convert(latest) {
            writePNG(CIImage(cvPixelBuffer: cropped), to: out.appendingPathComponent("crop.png"))
            report["cropFrameSize"] = "\(CVPixelBufferGetWidth(cropped))x\(CVPixelBufferGetHeight(cropped))"
        }
        if let latest = tab.frameSource.latest()?.buffer,
           let yuvCropper = PixelConverter(width: 1280, height: 720, pixelFormat: kCVPixelFormatType_422YpCbCr8, scaling: .fit,
                                           crop: CGRect(x: 100, y: 100, width: 800, height: 450)) {
            report["cropYUVWorks"] = yuvCropper.convert(latest) != nil
        }

        // Edit Mode while live: outputs must hold the last frame.
        let ndiRuntime = tab.runtime(for: ndi.id)
        tab.enterEditMode()
        let heldAt = ndiRuntime?.stats.snapshot().uniqueSourceFrames ?? 0
        await sleep(1.5)
        let heldAfter = ndiRuntime?.stats.snapshot().uniqueSourceFrames ?? 0
        report["editModeHold"] = ["isEditing": tab.isEditing, "isHolding": tab.isHoldingOutput,
                                  "frameSourceHeld": tab.frameSource.isHeld,
                                  "newFramesWhileHolding": Int(heldAfter) - Int(heldAt)]
        snapshotMainWindow(delegate: delegate, named: "main-editmode.png", canvasTab: tab)
        tab.exitEditMode()
        await sleep(1.0)
        let resumed = ndiRuntime?.stats.snapshot().uniqueSourceFrames ?? 0
        report["editModeResumed"] = ["isEditing": tab.isEditing, "newFramesAfterExit": Int(resumed) - Int(heldAfter)]

        // OSC: commands in, feedback out.
        let osc = OSCController.shared
        report["oscStatus"] = osc.status
        report["oscPortCheck"] = ["own": "\(osc.check(port: 39300))", "taken": "\(osc.check(port: 39301))",
                                  "free": "\(osc.check(port: 39305))"]
        let commander = OSCUDPSender()
        func command(_ address: String, _ args: [OSCValue] = []) {
            commander.send([OSCCodec.encode(OSCMessage(address, args))], host: "127.0.0.1", port: 39300)
        }
        command("/bb/ping")
        command("/bb/tab/1/stop")
        await sleep(0.8)
        let liveAfterStop = tab.isLive
        command("/bb/tab/1/output/1/start")
        await sleep(0.8)
        let ndiAfterOutputStart = tab.runtime(for: ndi.id)?.status == .live
        command("/bb/tab/Self_Test_Scoreboard/live", [.bool(false)])
        await sleep(0.6)
        let liveAfterNameStop = tab.isLive
        command("/bb/session/goLive")
        await sleep(1.2)
        let liveAfterGoLive = tab.isLive
        command("/bb/tab/1/zoom", [.float(1.25)])
        command("/bb/tab/9/goLive")
        command("/bb/tab/1/js", [.string("1+1")])
        await sleep(1.2)
        let zoomAfter = tab.zoom
        tab.zoom = 1.0
        let received = feedbackLock.sync { feedback }
        let addresses = Set(received.map(\.address))
        func lastValue(_ address: String) -> String {
            received.last { $0.address == address }.map { $0.arguments.map(\.debugText).joined(separator: " ") } ?? "missing"
        }
        report["osc"] = [
            "liveAfterStop": liveAfterStop,
            "ndiLiveAfterOutputStart": ndiAfterOutputStart,
            "liveAfterNameStop": liveAfterNameStop,
            "liveAfterGoLive": liveAfterGoLive,
            "zoomAfterCommand": zoomAfter,
            "messagesReceivedByApp": osc.messagesReceived,
            "feedbackMessagesCollected": received.count,
            "distinctFeedbackAddresses": addresses.count,
            "pong": lastValue("/bb/pong"),
            "errors": received.filter { $0.address == "/bb/error" }.map { $0.arguments.map(\.debugText).joined() },
            "tab1IsLive": lastValue("/bb/tab/1/isLive"),
            "eventTabLive": received.filter { $0.address == "/bb/event/tabLive" }.map { $0.arguments.map(\.debugText).joined(separator: " ") },
            "heartbeat": lastValue("/bb/heartbeat"),
            "sessionUptimeText": lastValue("/bb/session/uptimeText"),
            "tabNames": lastValue("/bb/session/tabNames"),
            "output1Status": lastValue("/bb/tab/1/output/1/status"),
            "output1Fps": lastValue("/bb/tab/1/output/1/fps"),
            "audioPeakL": lastValue("/bb/audio/peakL"),
            "cpuApp": lastValue("/bb/stats/cpuApp"),
        ]
        let sampleAddresses = addresses.sorted()
        try? sampleAddresses.joined(separator: "\n").write(to: out.appendingPathComponent("osc-addresses.txt"), atomically: true, encoding: .utf8)

        if let frame = tab.frameSource.latest()?.buffer {
            writePNG(CIImage(cvPixelBuffer: frame), to: out.appendingPathComponent("frame.png"))
            report["frameSize"] = "\(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame))"
        }

        // UI snapshots
        snapshotMainWindow(delegate: delegate, named: "main-outputs.png", canvasTab: tab)
        session.sidebarPanel = .customize
        await sleep(0.6)
        snapshotMainWindow(delegate: delegate, named: "main-customize.png", canvasTab: tab)
        session.sidebarPanel = .page
        await sleep(0.4)
        snapshotMainWindow(delegate: delegate, named: "main-page.png", canvasTab: tab)
        session.sidebarPanel = .outputs

        // Switch to the other tab: the live tab must keep rendering while parked.
        let uniqueBefore = tab.outputs.compactMap { tab.runtime(for: $0.id)?.stats.snapshot().uniqueSourceFrames }.max() ?? 0
        if let otherTab { session.select(otherTab) }
        await sleep(3.0)
        let uniqueAfter = tab.outputs.compactMap { tab.runtime(for: $0.id)?.stats.snapshot().uniqueSourceFrames }.max() ?? 0
        report["parkedLiveTab"] = [
            "level": tab.host.window.level.rawValue,
            "captureFPSWhileParked": tab.frameSource.measuredFPS,
            "uniqueFramesGainedWhileParked": Int(uniqueAfter) - Int(uniqueBefore),
            "clockText": await evaluate(tab.webView, "document.getElementById('clock').textContent") ?? "",
        ]
        session.select(tab)
        await sleep(0.8)


        delegate.showDashboard()
        await sleep(3.0)
        snapshot(delegate.dashboardWindow, named: "dashboard.png")
        delegate.showPreferences()
        await sleep(0.8)
        snapshot(delegate.preferencesWindow, named: "preferences.png")

        // Session JSON round trip
        let sessionURL = out.appendingPathComponent("session.json")
        try? JSONFile.save(session.makeFile(), to: sessionURL)
        if let loaded = try? JSONFile.load(SessionFile.self, from: sessionURL) {
            report["sessionRoundTrip"] = [
                "tabs": loaded.tabs.count,
                "outputs": loaded.tabs.reduce(0) { $0 + $1.outputs.count },
                "rules": loaded.tabs.reduce(0) { $0 + $1.customization.rules.count },
            ]
        }

        session.stopAll()
        await sleep(1.0)
        let recordings = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension == "mp4" } ?? []
        report["recordings"] = recordings.map { url -> String in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(url.lastPathComponent) \(size) bytes"
        }
        var trackInfo: [String] = []
        for url in recordings {
            let asset = AVURLAsset(url: url)
            let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            var naturalSize = CGSize.zero
            if let first = video.first { naturalSize = (try? await first.load(.naturalSize)) ?? .zero }
            let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            trackInfo.append("\(url.lastPathComponent): video \(video.count) (\(Int(naturalSize.width))x\(Int(naturalSize.height))), audio \(audio.count), \(String(format: "%.1f", duration)) s")
        }
        report["recordingTracks"] = trackInfo
        feedbackReceiver.stop()
        report["finalLiveState"] = session.liveSince == nil ? "stopped" : "still live"
        report["monitor"] = monitor(app.monitor)
    }

    private static func monitor(_ m: SystemMonitor) -> [String: Any] {
        guard let s = m.latest else { return [:] }
        return ["appCPU": s.appCPU, "webCPU": s.webCPU, "systemCPU": s.systemCPU, "gpu": s.gpu,
                "appMB": s.appMemoryMB, "webMB": s.webMemoryMB, "netOut": s.networkOutMbps]
    }

    private static func writePNG(_ image: CIImage, to url: URL) {
        let context = CIContext()
        if let cg = context.createCGImage(image, from: image.extent) {
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private static func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func snapshot(_ window: NSWindow?, named name: String) {
        guard let window, let view = window.contentView, let rep = render(view) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: outputDirectory.appendingPathComponent(name))
    }

    private static func findCanvasView(in view: NSView) -> CanvasInteractionView? {
        if let canvas = view as? CanvasInteractionView { return canvas }
        for sub in view.subviews {
            if let found = findCanvasView(in: sub) { return found }
        }
        return nil
    }

    /// Renders the main window and composites the canvas picture (a CALayer
    /// that cacheDisplay does not draw) plus its overlay, as the user sees it.
    private static func snapshotMainWindow(delegate: AppDelegate, named name: String, canvasTab: BrowserTab) {
        guard let window = delegate.mainController?.window, let view = window.contentView, let rep = render(view) else { return }
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        let composite = NSImage(size: view.bounds.size)
        composite.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        if let canvasView = findCanvasView(in: view) {
            let rect = canvasView.convert(canvasView.contentRect, to: nil) // window coords (bottom-left), like the image
            if let buffer = canvasTab.frameSource.latest()?.buffer {
                let ciRep = NSCIImageRep(ciImage: CIImage(cvPixelBuffer: buffer))
                let frameImage = NSImage(size: ciRep.size)
                frameImage.addRepresentation(ciRep)
                frameImage.draw(in: rect)
            }
            let overlay = canvasTab.host.overlayView
            if let overlayRep = render(overlay) {
                let overlayImage = NSImage(size: overlay.bounds.size)
                overlayImage.addRepresentation(overlayRep)
                overlayImage.draw(in: canvasView.convert(canvasView.bounds, to: nil))
            }
        }
        composite.unlockFocus()
        if let tiff = composite.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            try? bitmap.representation(using: .png, properties: [:])?.write(to: outputDirectory.appendingPathComponent(name))
        }
    }
}
