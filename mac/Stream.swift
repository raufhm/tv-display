// Streaming engine: virtual display → ScreenCaptureKit → VideoToolbox H.264 → TCP to the TV.
//
// Wire format (big-endian), shared with the TV receiver (app.tvscreen):
//   Mac -> TV: int32 length, byte type, int64 capture time in µs, then `length` bytes:
//              0 = SPS+PPS, 1 = key frame, 2 = frame (Annex-B H.264),
//              3 = audio format (int32 sample rate, byte channels; rate 0 = audio off),
//              4 = audio (interleaved 16-bit little-endian PCM).
//   TV -> Mac: int64 capture time of each frame, echoed once the TV has decoded it
//              (-1 = the TV reset its decoder and needs a key frame).

import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

struct StreamSettings {
    var host: String
    var port: UInt16 = 7777
    var fps: Int
    var mbps: Int
    var width = 1280
    var height = 720
    var textSize = TextSize.normal
}

/// How big things look on the TV. The stream is always 1280×720; the larger sizes make macOS draw
/// a smaller desktop at 2× (Retina), which is then scaled to 720p, so text is bigger and still sharp.
enum TextSize: Int, CaseIterable {
    case normal, larger, largest

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .larger: return "Larger"
        case .largest: return "Largest"
        }
    }
    /// Desktop size in points, and the pixels macOS draws it at.
    var points: (w: Int, h: Int) {
        switch self {
        case .normal: return (1280, 720)
        case .larger: return (960, 540)
        case .largest: return (800, 450)
        }
    }
    var pixels: (w: Int, h: Int) { self == .normal ? points : (points.w * 2, points.h * 2) }
}

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/tvdisplay.log")
private let logHandle: FileHandle? = {
    try? Data().write(to: logURL)
    return try? FileHandle(forWritingTo: logURL)
}()
private let logLock = NSLock()

func log(_ s: String) {
    let line = "[tvdisplay] \(s)"
    print(line)
    logLock.lock(); logHandle?.write((line + "\n").data(using: .utf8)!); logLock.unlock()
}

func hostNowUs() -> Int64 {
    Int64(CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000_000)
}

struct StreamError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

// MARK: - Virtual display

func makeVirtualDisplay(_ cfg: StreamSettings) throws -> CGVirtualDisplay {
    let desc = CGVirtualDisplayDescriptor()
    desc.queue = DispatchQueue(label: "vdisplay")
    desc.name = "TV Display"
    // Room for the 2× text sizes (up to 1920×1080 pixels); the stream itself stays 720p.
    desc.maxPixelsWide = 1920
    desc.maxPixelsHigh = 1080
    desc.sizeInMillimeters = CGSize(width: 708, height: 398) // ~32" panel
    desc.vendorID = 0x7456
    desc.productID = 0x0720
    desc.serialNum = 1
    desc.terminationHandler = { _, _ in log("virtual display terminated") }
    guard let display = CGVirtualDisplay(descriptor: desc) else { throw StreamError("Could not create the virtual display.") }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 1
    settings.modes = TextSize.allCases.map {
        CGVirtualDisplayMode(width: UInt32($0.points.w), height: UInt32($0.points.h), refreshRate: 60)
    }
    guard display.apply(settings) else { throw StreamError("The virtual display rejected its settings.") }
    return display
}

/// Switches the virtual display to a text size. macOS lists the 2× modes but doesn't pick them on
/// its own, so the mode is set explicitly. Returns false if the display isn't ready yet.
@discardableResult
func setTextSize(_ size: TextSize, displayID: CGDirectDisplayID) -> Bool {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
          let mode = modes.first(where: {
              $0.width == size.points.w && $0.height == size.points.h && $0.pixelWidth == size.pixels.w
          }) else { return false }
    if let cur = CGDisplayCopyDisplayMode(displayID), cur.width == mode.width, cur.pixelWidth == mode.pixelWidth {
        return true
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return false }
    CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
    let ok = CGCompleteDisplayConfiguration(config, .forSession) == .success
    if ok { log("text size: \(size.title) (\(size.points.w)x\(size.points.h) at \(size.pixels.w)x\(size.pixels.h))") }
    return ok
}

// MARK: - TCP link to the TV

struct LinkStats {
    var frames = 0, bytes = 0, dropped = 0, skipped = 0
    var latencies: [Double] = []
}

final class Link {
    private let cfg: StreamSettings
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false
    private let sendQueue = DispatchQueue(label: "send", qos: .userInteractive)
    private var pending = 0          // frames queued but not yet written
    private var needKey = true       // drop P-frames until the next key frame
    // Flow control: frames sent but not yet shown on the TV. The TV's display is locked to
    // 60 Hz, so without this any surplus would queue up and latency would grow without bound.
    private let maxInFlight = 4
    private var inFlight = 0
    private var lastAckUs: Int64 = 0
    private var stats = LinkStats()
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    private var pendingAudio = 0
    var onKeyFrameRequest: (() -> Void)?

    init(_ cfg: StreamSettings) { self.cfg = cfg }

    var connected: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }

    func start() { Thread { self.connectLoop() }.start() }

    func stop() {
        lock.lock()
        stopped = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1 }
        lock.unlock()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func connectLoop() {
        while !isStopped {
            if connected { Thread.sleep(forTimeInterval: 0.3); continue }
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = cfg.port.bigEndian
            guard inet_pton(AF_INET, cfg.host, &addr.sin_addr) == 1 else {
                close(s); Thread.sleep(forTimeInterval: 1); continue
            }
            var one: Int32 = 1
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var sndbuf: Int32 = 512 * 1024
            setsockopt(s, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if !ok {
                close(s)
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            lock.lock()
            if stopped { lock.unlock(); close(s); return }
            fd = s; needKey = true; pending = 0; pendingAudio = 0; inFlight = 0; lastAckUs = hostNowUs()
            lock.unlock()
            log("connected to \(cfg.host):\(cfg.port)")
            onConnect?()
            Thread { self.ackLoop(s) }.start()
        }
    }

    private func drop(_ s: Int32) {
        lock.lock()
        let was = fd == s
        if was { fd = -1; close(s); log("disconnected") }
        lock.unlock()
        if was { onDisconnect?() }
    }

    // The TV echoes each frame's capture time once it hands the frame to the display.
    private func ackLoop(_ s: Int32) {
        var buf = [UInt8](repeating: 0, count: 8)
        while true {
            var got = 0
            while got < 8 {
                let n = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress! + got, 8 - got, 0) }
                if n <= 0 { drop(s); return }
                got += n
            }
            let ts = buf.reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            if ts == -1 {
                // The TV rebuilt its decoder and needs a key frame.
                lock.lock(); inFlight = 0; needKey = true; lock.unlock()
                onKeyFrameRequest?()
                continue
            }
            let now = hostNowUs()
            let ms = Double(now - ts) / 1000
            lock.lock()
            stats.latencies.append(ms)
            inFlight = max(0, inFlight - 1)
            lastAckUs = now
            lock.unlock()
        }
    }

    /// Whether the TV has room for another frame. Capture skips frames (before encoding, so the
    /// stream stays intact) while it doesn't. If acks stall, frames are let through anyway so the
    /// decoder, which holds a couple of frames back, always gets enough input to flush.
    var readyForFrame: Bool {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return false }
        if inFlight < maxInFlight || hostNowUs() - lastAckUs > 100_000 { return true }
        stats.skipped += 1
        return false
    }

    /// Queues one packet. Returns false if the link wants a key frame (after a drop).
    @discardableResult
    func send(type: UInt8, ts: Int64, payload: Data, isKey: Bool) -> Bool {
        lock.lock()
        guard fd >= 0 else { lock.unlock(); return false }
        if needKey && !isKey && type != 0 { stats.dropped += 1; lock.unlock(); return false }
        if pending > 3 && type != 0 {
            // Network can't keep up: skip until a fresh key frame so latency doesn't build up.
            needKey = true; stats.dropped += 1; lock.unlock(); return false
        }
        if isKey { needKey = false }
        pending += 1
        if type != 0 { inFlight += 1 }
        let s = fd
        lock.unlock()

        write(s, packet(type, ts, payload)) { ok, bytes in
            self.lock.lock()
            self.pending -= 1
            if type != 0 { self.stats.frames += 1 }
            self.stats.bytes += bytes
            self.lock.unlock()
        }
        return true
    }

    /// Audio bypasses video pacing; if the network stalls, old audio is dropped instead of queued.
    func sendAudio(type: UInt8, payload: Data) {
        lock.lock()
        guard fd >= 0, pendingAudio < 20 else { lock.unlock(); return }
        pendingAudio += 1
        let s = fd
        lock.unlock()
        write(s, packet(type, hostNowUs(), payload)) { _, bytes in
            self.lock.lock()
            self.pendingAudio -= 1
            self.stats.bytes += bytes
            self.lock.unlock()
        }
    }

    private func packet(_ type: UInt8, _ ts: Int64, _ payload: Data) -> Data {
        var pkt = Data(capacity: 13 + payload.count)
        var len = UInt32(payload.count).bigEndian
        var t = UInt64(bitPattern: ts).bigEndian
        withUnsafeBytes(of: &len) { pkt.append(contentsOf: $0) }
        pkt.append(type)
        withUnsafeBytes(of: &t) { pkt.append(contentsOf: $0) }
        pkt.append(payload)
        return pkt
    }

    private func write(_ s: Int32, _ pkt: Data, done: @escaping (Bool, Int) -> Void) {
        sendQueue.async {
            let ok = pkt.withUnsafeBytes { raw -> Bool in
                var off = 0
                while off < raw.count {
                    let n = Darwin.send(s, raw.baseAddress! + off, raw.count - off, 0)
                    if n <= 0 { return false }
                    off += n
                }
                return true
            }
            done(ok, pkt.count)
            if !ok { self.drop(s) }
        }
    }

    func takeStats() -> LinkStats {
        lock.lock(); defer { lock.unlock() }
        let r = stats
        stats = LinkStats()
        return r
    }
}

// MARK: - Encoder

final class Encoder {
    private var session: VTCompressionSession?
    private let link: Link
    private var forceKey = true
    private let keyLock = NSLock()

    init(_ cfg: StreamSettings, link: Link) throws {
        self.link = link
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(cfg.width), height: Int32(cfg.height),
                                            codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw StreamError("The video encoder could not start (\(st)).") }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: cfg.mbps * 1_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: cfg.fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: cfg.fps * 10,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
        ]
        for (k, v) in props {
            let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
            if r != noErr { log("note: property \(k) not supported (\(r))") }
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    func requestKeyFrame() { keyLock.lock(); forceKey = true; keyLock.unlock() }

    func encode(_ pixels: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        keyLock.lock(); let key = forceKey; forceKey = false; keyLock.unlock()
        let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props,
                                        infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.emit(sample)
        }
    }

    private func emit(_ sample: CMSampleBuffer) {
        let ts = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1_000_000)
        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first, first[kCMSampleAttachmentKey_NotSync] as? Bool == true {
            isKey = false
        }
        let startCode: [UInt8] = [0, 0, 0, 1]
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var cfg = Data()
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    cfg.append(contentsOf: startCode)
                    cfg.append(ptr, count: size)
                }
            }
            link.send(type: 0, ts: ts, payload: cfg, isKey: false)
        }

        // AVCC (4-byte length prefixes) -> Annex-B (start codes).
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var total = 0
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &total, dataPointerOut: &base) == noErr,
              let base else { return }
        var out = Data(capacity: total)
        var off = 0
        base.withMemoryRebound(to: UInt8.self, capacity: total) { p in
            while off + 4 <= total {
                let n = Int(p[off]) << 24 | Int(p[off + 1]) << 16 | Int(p[off + 2]) << 8 | Int(p[off + 3])
                off += 4
                guard n > 0, off + n <= total else { break }
                out.append(contentsOf: startCode)
                out.append(p + off, count: n)
                off += n
            }
        }
        if !link.send(type: isKey ? 1 : 2, ts: ts, payload: out, isKey: isKey) {
            requestKeyFrame()
        }
    }

    func stop() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }
}

// MARK: - Capture

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let cfg: StreamSettings
    private let encoder: Encoder
    private let link: Link
    private var stream: SCStream?
    private var lastPixels: CVPixelBuffer?
    private var lastFrameUs: Int64 = 0
    private let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    private var ticker: DispatchSourceTimer?
    var onError: ((Error) -> Void)?

    init(_ cfg: StreamSettings, encoder: Encoder, link: Link) {
        self.cfg = cfg; self.encoder = encoder; self.link = link
    }

    func start(displayID: CGDirectDisplayID) async throws {
        var scDisplay: SCDisplay?
        for _ in 0..<50 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let scDisplay else { throw StreamError("The TV display did not come online.") }

        let sc = SCStreamConfiguration()
        sc.width = cfg.width
        sc.height = cfg.height
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.fps))
        sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        sc.queueDepth = 3
        sc.showsCursor = true
        sc.colorSpaceName = CGColorSpace.sRGB
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: sc, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s

        // The TV's decoder only releases a frame once later frames arrive, so a static screen
        // would leave the newest picture stuck inside it. Keep a steady frame rate by repeating
        // the last frame when nothing changed (an unchanged P-frame is ~100 bytes).
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(cfg.fps)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, let p = self.lastPixels, self.link.connected else { return }
            guard self.link.readyForFrame else { return }
            let now = hostNowUs()
            if now - self.lastFrameUs < Int64(interval * 800_000) { return }
            self.lastFrameUs = now
            self.encoder.encode(p, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        t.resume()
        ticker = t
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        guard let s = stream else { return }
        stream = nil
        let done = DispatchSemaphore(value: 0)
        s.stopCapture { _ in done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw),
              status == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        lastPixels = pixels
        lastFrameUs = hostNowUs()
        // If the TV is behind, skip; the repeat timer sends the newest picture once it catches up.
        guard link.readyForFrame else { lastFrameUs = 0; return }
        encoder.encode(pixels, pts: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// After (re)connecting, send the current picture as a key frame straight away.
    func resendLast() {
        queue.async {
            guard let p = self.lastPixels else { return }
            self.encoder.requestKeyFrame()
            self.encoder.encode(p, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error.localizedDescription)")
        onError?(error)
    }
}

// MARK: - Session (one "TV Display is on" lifetime)

final class StreamSession {
    let settings: StreamSettings
    private var display: CGVirtualDisplay?
    private let link: Link
    private let encoder: Encoder
    private let capture: Capture
    var onError: ((Error) -> Void)? {
        didSet { capture.onError = onError }
    }

    init(_ settings: StreamSettings) throws {
        self.settings = settings
        link = Link(settings)
        encoder = try Encoder(settings, link: link)
        capture = Capture(settings, encoder: encoder, link: link)
        let capture = self.capture
        link.onConnect = {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { capture.resendLast() }
        }
        link.onKeyFrameRequest = { capture.resendLast() }
        link.onDisconnect = { [weak self] in self?.updateAudio() }
        let previous = link.onConnect
        link.onConnect = { [weak self] in
            previous?()
            self?.updateAudio()
        }
    }

    // MARK: Audio

    private let audioQueue = DispatchQueue(label: "audio-control")
    private var tap: AnyObject?
    private var wantAudio = false

    /// Plays the Mac's sound on the TV instead of the Mac (macOS 14.2+).
    func setAudioOnTV(_ on: Bool) {
        audioQueue.async { self.wantAudio = on }
        updateAudio()
    }

    /// The tap only runs while the TV is connected, so the Mac never goes silent for nothing.
    private func updateAudio() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard #available(macOS 14.2, *) else { return }
            let should = self.wantAudio && self.link.connected
            if should, self.tap == nil {
                let t = AudioTap()
                var sentFormat = false
                t.onPCM = { [weak self] rate, ch, data in
                    guard let link = self?.link else { return }
                    if !sentFormat {
                        sentFormat = true
                        var fmt = Data()
                        var r = UInt32(rate).bigEndian
                        withUnsafeBytes(of: &r) { fmt.append(contentsOf: $0) }
                        fmt.append(UInt8(ch))
                        link.sendAudio(type: 3, payload: fmt)
                    }
                    link.sendAudio(type: 4, payload: data)
                }
                do {
                    try t.start()
                    self.tap = t
                } catch {
                    t.stop()
                    log("audio: \(error.localizedDescription)")
                }
            } else if !should, let t = self.tap as? AudioTap {
                t.stop()
                self.tap = nil
                var off = Data(count: 5) // rate 0 tells the TV to stop playing
                off[4] = 0
                self.link.sendAudio(type: 3, payload: off)
            }
        }
    }

    var connected: Bool { link.connected }
    var displayID: CGDirectDisplayID? { display?.displayID }

    func start() async throws {
        let d = try makeVirtualDisplay(settings)
        display = d
        log("virtual display \(d.displayID) created (\(settings.width)x\(settings.height))")
        // The display needs a moment to come online before its modes can be set.
        for _ in 0..<30 {
            if setTextSize(settings.textSize, displayID: d.displayID) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        do {
            try await capture.start(displayID: d.displayID)
        } catch {
            stop()
            throw error
        }
        log("capturing at up to \(settings.fps) fps, \(settings.mbps) Mbps; streaming to \(settings.host):\(settings.port)")
        link.start()
    }

    func takeStats() -> LinkStats { link.takeStats() }

    /// Changes the text size live; the stream keeps running.
    func apply(textSize: TextSize) {
        guard let id = display?.displayID else { return }
        setTextSize(textSize, displayID: id)
    }

    func stop() {
        audioQueue.sync {
            if #available(macOS 14.2, *), let t = tap as? AudioTap { t.stop() }
            tap = nil
            wantAudio = false
        }
        link.stop()
        capture.stop()
        encoder.stop()
        if display != nil { log("virtual display removed") }
        display = nil // releasing the CGVirtualDisplay removes it from the system
    }
}
