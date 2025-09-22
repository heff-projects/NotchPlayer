import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

final class PlayerView: NSView {
    
    // MARK: Public flags
    public var isLooping: Bool = true
    public private(set) var isPaused: Bool = false
    public var isStopped: Bool { hPlayer == nil }
    
    // MARK: KVC-exposed timing (read by UI)
    @objc dynamic private(set) var currentPTS: Double = 0
    @objc dynamic private(set) var duration: Double = .nan // exact after first full pass
    @objc dynamic private(set) var fps: Double = 30.0

    // MARK: Internals
    private let displayLayer = AVSampleBufferDisplayLayer()
    
    // One dedicated queue for all decode/stop work to avoid races
    private let decodeQueue = DispatchQueue(label: "notchplayer.decode.queue")
    
    private var timer: DispatchSourceTimer?
    private var isShuttingDown: Bool = false
    
    private var hPlayer: OpaquePointer?
    private var currentURL: URL?
    private var timebase: CMTimebase?
    
    // Exact duration once we’ve completed one pass
    private var measuredDuration: Double?
    
    private var pendingImage: CVImageBuffer?
    private var pendingPTS: Double = .nan
    private let displayQueue = DispatchQueue(label: "notchplayer.display.queue")
    private var videoW: Int32 = 0
    private var videoH: Int32 = 0
    private var videoFPS: Double = 30.0

    
    
    // MARK: Init / layout
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor          // ← solid black background
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        displayLayer.isOpaque = false
        displayLayer.backgroundColor = NSColor.clear.cgColor
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()

        // Default to full-bounds if we don’t know the aspect yet
        guard videoW > 0, videoH > 0 else {
            displayLayer.frame = bounds
            if let scale = window?.backingScaleFactor { displayLayer.contentsScale = scale }
            return
        }

        let ar = CGFloat(videoW) / CGFloat(videoH)
        var targetWidth  = bounds.width
        var targetHeight = targetWidth / ar

        // If height would overflow the view, fall back to height-fit
        if targetHeight > bounds.height {
            targetHeight = bounds.height
            targetWidth  = targetHeight * ar
        }

        // Center within the view
        let x = (bounds.width  - targetWidth)  * 0.5
        let y = (bounds.height - targetHeight) * 0.5
        displayLayer.frame = CGRect(x: floor(x), y: floor(y),
                                    width: floor(targetWidth), height: floor(targetHeight))

        // Keep Retina scale correct to avoid fractional rounding artifacts
        if let scale = window?.backingScaleFactor {
            displayLayer.contentsScale = scale
        }
    }

    deinit { stop() }
    
    // MARK: Public API
    
    func openAndPlay(url: URL) {
        currentURL = url

        // Gate: only allow NotchLC
        let isNotch = url.path.withCString { ff_is_notchlc($0) }
        if isNotch != 1 {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Unsupported Codec"
                alert.informativeText = "This player only supports NotchLC files.\n\nSelected file:\n\(url.lastPathComponent)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }

        // Reset all per-file state so duration is recalculated on each open
        decodeQueue.sync {
            self.measuredDuration = nil
            self.pendingImage = nil
            self.pendingPTS = .nan
            self.videoW = 0
            self.videoH = 0
        }
        DispatchQueue.main.async {
            // UI sees unknown duration until the new file reports it
            self.duration = .nan
            self.currentPTS = 0
            self.displayLayer.flushAndRemoveImage()
        }

        // Stop any current playback and start fresh
        stop()
        startDecodeLoop(path: url.path, resumeFrom: 0)
        play()
    }


    
    func play() {
        guard let tb = ensureTimebase() else { return }
        CMTimebaseSetTime(tb, time: .zero)
        CMTimebaseSetRate(tb, rate: 1.0)
        isPaused = false
    }
    
    func pause() {
        guard let tb = timebase else { return }
        CMTimebaseSetRate(tb, rate: 0.0)
        isPaused = true
    }
    
    func resume() {
        guard let tb = timebase else { return }
        CMTimebaseSetRate(tb, rate: 1.0)
        isPaused = false
    }
    
    func stopPlayback() {
        // Graceful shutdown of decode on the decode queue (no races)
        stop()
        
        // Clear the layer and reset the clock to 0 on main
        DispatchQueue.main.async {
            self.displayLayer.flushAndRemoveImage()
        }
        if let tb = timebase {
            CMTimebaseSetRate(tb, rate: 0.0)
            CMTimebaseSetTime(tb, time: .zero)
        }
        currentPTS = 0
        // Keep 'duration' as-is so UI can still show known length after first pass
        isPaused = false // next Play starts from 0
    }
    
    // MARK: Core
    
    private func stop() {
        decodeQueue.sync {
            isShuttingDown = true
            
            // Safely stop timer
            if let t = timer {
                t.setEventHandler {} // prevent firing into freed state
                t.cancel()
                timer = nil
            }
            
            // Close decoder if open
            if let hp = hPlayer {
                hPlayer = nil
                ff_close(hp)
            }
            
            isShuttingDown = false
        }
    }
    
    private func ensureTimebase() -> CMTimebase? {
        if let tb = timebase { return tb }
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &tb)
        timebase = tb
        if let tb = tb {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 0.0)
            displayLayer.controlTimebase = tb
        }
        return timebase
    }
    
    private func startDecodeLoop(path: String, resumeFrom: Double) {
        // All decode work runs on the dedicated queue
        decodeQueue.async {
            // Clear any old visuals up front
            DispatchQueue.main.async {
                self.displayLayer.flushAndRemoveImage()
            }

            var w: Int32 = 0, h: Int32 = 0
            var tbSec: Double = 0
            var durHeader: Double = .nan

            // Open demux/decoder
            guard let handle = ff_open(path, &w, &h, &tbSec, &durHeader) else {
                print("ff_open failed for path: \(path)")
                return
            }
            self.hPlayer = handle
            self.videoW = w
            self.videoH = h

            // ---- Duration selection (match ffprobe by default) ----
            @inline(__always) func isValidDuration(_ v: Double) -> Bool { v.isFinite && v > 0 }

            // Pull exactly what ffprobe [FORMAT] prints
            let fmtDur = path.withCString { ff_format_duration($0) }

            // Fallbacks
            var chosen = fmtDur
            if !isValidDuration(chosen) { chosen = durHeader }
            if !isValidDuration(chosen) {
                chosen = path.withCString { ff_probe_duration($0) }
            }

            // Optional: a precise demux scan near EOF (no decoding). If you want to
            // UPGRADE immediately beyond ffprobe's value, uncomment the next two lines.
            let precise = path.withCString { ff_precise_duration($0) }
            // if isValidDuration(precise) { chosen = precise }

            if let known = self.measuredDuration, isValidDuration(known) {
                DispatchQueue.main.async { self.duration = known }
            } else {
                let picked = isValidDuration(chosen) ? chosen : .nan
                DispatchQueue.main.async { self.duration = picked }
            }
            // -------------------------------------------------------

            // Prepare playback clock/timebase
            _ = self.ensureTimebase()
            if let tb = self.timebase {
                CMTimebaseSetTime(tb, time: CMTime(seconds: resumeFrom, preferredTimescale: 600))
                // Rate is controlled by play()/pause()/resume()
            }

            // Resize window to match clip aspect (do this on main)
            DispatchQueue.main.async { [weak self] in
                self?.resizeWindowToVideoAspect(videoWidth: w, videoHeight: h)
            }

            // FPS probe (cadence); default to 30 if unknown
            let fpsGuess: Double = path.withCString { ff_get_avg_fps($0) }
            let fps: Double = (fpsGuess.isFinite && fpsGuess > 0) ? fpsGuess : 30.0
            let frameInterval = max(1.0 / fps, 0.001) // seconds
            self.videoFPS = fps
            DispatchQueue.main.async { self.fps = fps }


            // Pacing: don’t decode more than a small lead ahead of the clock
            let presentLead: Double = max(0.5 * frameInterval, 0.003) // ~½ frame
            let epsilon: Double = 0.001

            // Reset pending frame state
            self.pendingImage = nil
            self.pendingPTS = .nan

            // Timer at frame cadence with tiny leeway to reduce jitter
            let t = DispatchSource.makeTimerSource(queue: self.decodeQueue)
            let tickNs = max(1_000_000, Int((frameInterval * 1_000_000_000).rounded())) // ≥1ms
            t.schedule(deadline: .now(), repeating: .nanoseconds(tickNs), leeway: .milliseconds(1))

            t.setEventHandler { [weak self] in
                guard let self = self else { return }
                if self.isShuttingDown { return }
                guard self.hPlayer != nil else { return }

                // If paused, keep UI clock updated but don’t decode/enqueue
                if let tb = self.timebase, CMTimebaseGetRate(tb) == 0 {
                    self.currentPTS = CMTimeGetSeconds(CMTimebaseGetTime(tb))
                    return
                }

                // Authoritative playhead = timebase time
                let nowSec: Double = {
                    if let tb = self.timebase { return CMTimeGetSeconds(CMTimebaseGetTime(tb)) }
                    return 0
                }()
                self.currentPTS = nowSec

                // 1) Present pending frame when due; otherwise don't drain
                if let ib = self.pendingImage, self.pendingPTS.isFinite {
                    if self.pendingPTS <= nowSec + epsilon {
                        var timing = CMSampleTimingInfo()
                        timing.presentationTimeStamp = CMTime(seconds: self.pendingPTS, preferredTimescale: 600)
                        timing.duration = .invalid
                        timing.decodeTimeStamp = .invalid

                        var vfmt: CMVideoFormatDescription?
                        CMVideoFormatDescriptionCreateForImageBuffer(
                            allocator: kCFAllocatorDefault,
                            imageBuffer: ib,
                            formatDescriptionOut: &vfmt
                        )
                        if let vfmt = vfmt {
                            var sbuf: CMSampleBuffer?
                            CMSampleBufferCreateReadyWithImageBuffer(
                                allocator: kCFAllocatorDefault,
                                imageBuffer: ib,
                                formatDescription: vfmt,
                                sampleTiming: &timing,
                                sampleBufferOut: &sbuf
                            )
                            if let sbuf = sbuf {
                                self.displayQueue.async { self.displayLayer.enqueue(sbuf) }
                            }
                        }

                        self.pendingImage = nil
                        self.pendingPTS = .nan
                    } else {
                        return // not time yet → don’t fetch more
                    }
                }

                // 2) No pending frame: fetch exactly one
                var umib: Unmanaged<CVImageBuffer>?
                var pts: Double = .nan
                let rc = ff_next_frame(self.hPlayer, &umib, &pts)

                if rc == 1, let umib = umib {
                    let ib: CVImageBuffer = umib.takeRetainedValue()
                    let ptsForPresentation: Double = pts.isFinite ? pts : nowSec

                    // If frame is ahead of clock, hold it to avoid racing to EOF
                    if ptsForPresentation > nowSec + presentLead {
                        self.pendingImage = ib
                        self.pendingPTS = ptsForPresentation
                        return
                    }

                    var timing = CMSampleTimingInfo()
                    timing.presentationTimeStamp = CMTime(seconds: ptsForPresentation, preferredTimescale: 600)
                    timing.duration = .invalid
                    timing.decodeTimeStamp = .invalid

                    var vfmt: CMVideoFormatDescription?
                    CMVideoFormatDescriptionCreateForImageBuffer(
                        allocator: kCFAllocatorDefault,
                        imageBuffer: ib,
                        formatDescriptionOut: &vfmt
                    )
                    if let vfmt = vfmt {
                        var sbuf: CMSampleBuffer?
                        CMSampleBufferCreateReadyWithImageBuffer(
                            allocator: kCFAllocatorDefault,
                            imageBuffer: ib,
                            formatDescription: vfmt,
                            sampleTiming: &timing,
                            sampleBufferOut: &sbuf
                        )
                        if let sbuf = sbuf {
                            self.displayQueue.async { self.displayLayer.enqueue(sbuf) }
                        }
                    }

                } else if rc == 0 {
                    // EOF: promote measured runtime
                    if let tb = self.timebase {
                        let measured = CMTimeGetSeconds(CMTimebaseGetTime(tb))
                        self.measuredDuration = measured
                        DispatchQueue.main.async { self.duration = measured }
                    }

                    // Stop cleanly
                    self.timer?.setEventHandler {}
                    self.timer?.cancel()
                    self.timer = nil
                    if let hp = self.hPlayer {
                        self.hPlayer = nil
                        ff_close(hp)
                    }

                    // Loop if enabled
                    if self.isLooping, let url = self.currentURL {
                        DispatchQueue.main.async {
                            self.displayLayer.flushAndRemoveImage()
                        }
                        if let tb = self.timebase {
                            let wasPlaying = (CMTimebaseGetRate(tb) > 0)
                            CMTimebaseSetTime(tb, time: .zero)
                            CMTimebaseSetRate(tb, rate: wasPlaying ? 1.0 : 0.0)
                        }
                        self.startDecodeLoop(path: url.path, resumeFrom: 0)
                    }

                } else if rc < 0 {
                    // Decode error
                    print("ff_next_frame error: \(rc)")
                    self.timer?.setEventHandler {}
                    self.timer?.cancel()
                    self.timer = nil
                    if let hp = self.hPlayer {
                        self.hPlayer = nil
                        ff_close(hp)
                    }
                    DispatchQueue.main.async {
                        self.displayLayer.flushAndRemoveImage()
                    }
                }
            }

            t.resume()
            self.timer = t
        }
    }


    private func resizeWindowToVideoAspect(videoWidth: Int32, videoHeight: Int32) {
        guard videoWidth > 0, videoHeight > 0, let win = self.window else { return }

        let ar = CGFloat(videoWidth) / CGFloat(videoHeight)

        func clampAndRound(_ size: NSSize) -> NSSize {
            var out = size
            if let screen = win.screen {
                let maxW = screen.visibleFrame.width * 0.90
                let maxH = screen.visibleFrame.height * 0.90
                if out.height > maxH {
                    let s = maxH / out.height
                    out.width  = floor(out.width  * s)
                    out.height = floor(out.height * s)
                }
                if out.width > maxW {
                    let s = maxW / out.width
                    out.width  = floor(out.width  * s)
                    out.height = floor(out.height * s)
                }
                out.width = max(out.width, 480) // sensible minimum width
            }
            out.width  = round(out.width)
            out.height = round(out.height)
            return out
        }

        // Make sure layout is up to date for accurate measurements
        win.contentView?.layoutSubtreeIfNeeded()
        self.layoutSubtreeIfNeeded()

        // Current content size and actual PlayerView width
        let contentSize = win.contentLayoutRect.size
        let videoW = max(1, self.bounds.width)
        let nonVideoH = max(0, contentSize.height - self.bounds.height)

        var target = NSSize(width: contentSize.width,
                            height: (videoW / ar) + nonVideoH)
        target = clampAndRound(target)

        // Lock content aspect so manual resizes keep the ratio
        win.contentAspectRatio = NSSize(width: CGFloat(videoWidth), height: CGFloat(videoHeight))
        
        win.setContentSize(target)
    }
}
