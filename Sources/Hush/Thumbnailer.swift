import AppKit
import CMpv

/// Seek-bar previews. Each window owns one: a second, hidden mpv instance that opens the same
/// local file paused, seeks to keyframes on request and renders them with the software
/// renderer, so every format mpv can play gets previews (AVFoundation would only cover a few).
///
/// Public API is main-thread only. All mpv work happens on a private serial queue; requests
/// are coalesced so only the most recent hover position is decoded.
final class Thumbnailer {
    /// Called on the main thread with a rendered frame for a requested time.
    var onImage: ((Double, CGImage) -> Void)?
    /// Called on the main thread after a file is loaded: the preview size in points, or nil
    /// when the file has no video (or nothing is loaded).
    var onReady: ((NSSize?) -> Void)?

    /// Largest preview, in points; rendered at 2x.
    static let maxSize = NSSize(width: 208, height: 150)

    private let queue = DispatchQueue(label: "hush.thumbnailer", qos: .userInitiated)
    private let wake = DispatchSemaphore(value: 0)

    // Shared between main and queue, guarded by `lock`.
    private let lock = NSLock()
    private var pending: (time: Double, generation: Int)?
    private var working = false
    private var generation = 0

    // Queue-only state.
    private var handle: OpaquePointer?
    private var render: OpaquePointer?
    private var loadedGeneration = 0
    private var hasVideo = false
    private var pixelWidth = 0, pixelHeight = 0, stride = 0
    private var buffer: UnsafeMutableRawPointer?
    private var restarted = false
    private var abortOnRequest = false
    private var cache: [Int: (image: CGImage, exact: Bool)] = [:]
    private var cacheOrder: [Int] = []

    // MARK: Main-thread API

    /// Loads a local file for previews (nil unloads). Streams are not previewed.
    func load(path: String?) {
        let gen = bump()
        queue.async { self.doLoad(path, generation: gen) }
    }

    func request(time: Double) {
        lock.lock()
        pending = (time, generation)
        lock.unlock()
        kick()
    }

    /// Releases the mpv instance; the object must not be used afterwards.
    func destroy() {
        _ = bump()
        queue.async {
            if let rc = self.render {
                mpv_render_context_set_update_callback(rc, nil, nil)
                mpv_render_context_free(rc)
            }
            if let mpv = self.handle {
                mpv_set_wakeup_callback(mpv, nil, nil)
                mpv_terminate_destroy(mpv)
            }
            self.render = nil
            self.handle = nil
            free(self.buffer)
            self.buffer = nil
        }
    }

    private func bump() -> Int {
        lock.lock()
        generation += 1
        pending = nil
        let gen = generation
        lock.unlock()
        return gen
    }

    /// Starts the worker unless it is already running. Safe from any thread.
    private func kick() {
        lock.lock()
        guard !working, pending != nil else { lock.unlock(); return }
        working = true
        lock.unlock()
        queue.async { self.drain() }
    }

    // MARK: Worker (queue)

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else { working = false; lock.unlock(); return }
            if job.generation != loadedGeneration {
                // The matching load is still queued behind us: let it run, then retry.
                working = false
                lock.unlock()
                queue.async { self.kick() }
                return
            }
            pending = nil
            lock.unlock()

            let key = Int(job.time.rounded())
            var exact = cache[key]?.exact ?? false
            guard let image = cache[key]?.image ?? produce(at: job.time) else { continue }
            if cache[key] == nil {
                // Within 1s of the target is accurate enough; only refine keyframes further away.
                exact = abs((shownTime ?? -10) - job.time) <= 1.0
                store(image, exact: exact, key: key)
            }
            deliver(image, job)

            // The pointer has rested: replace the keyframe with the exact frame.
            if !exact, !hasPendingRequest, let precise = produce(at: job.time, exact: true) {
                store(precise, exact: true, key: key)
                deliver(precise, job)
            }
        }
    }

    private var hasPendingRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    private func deliver(_ image: CGImage, _ job: (time: Double, generation: Int)) {
        DispatchQueue.main.async {
            guard self.currentGeneration == job.generation else { return }
            self.onImage?(job.time, image)
        }
    }

    private var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func doLoad(_ path: String?, generation gen: Int) {
        cache.removeAll()
        cacheOrder.removeAll()
        hasVideo = false
        guard let path, !path.contains("://"), FileManager.default.fileExists(atPath: path) else {
            if let mpv = handle { command(mpv, ["stop"]) }
            loadedGeneration = gen
            DispatchQueue.main.async { if self.currentGeneration == gen { self.onReady?(nil) } }
            return
        }
        guard let mpv = ensureHandle() else { loadedGeneration = gen; return }

        restarted = false
        command(mpv, ["loadfile", path, "replace"])
        // Paused load: the first frame arrives with a playback restart.
        if waitForFrame(timeout: 5) {
            var w: Int64 = 0, h: Int64 = 0
            if mpv_get_property(mpv, "video-out-params/dw", MPV_FORMAT_INT64, &w) >= 0,
               mpv_get_property(mpv, "video-out-params/dh", MPV_FORMAT_INT64, &h) >= 0, w > 0, h > 0 {
                let scale = min(Self.maxSize.width / CGFloat(w), Self.maxSize.height / CGFloat(h))
                let points = NSSize(width: (CGFloat(w) * scale).rounded(), height: (CGFloat(h) * scale).rounded())
                allocate(width: Int(points.width) * 2, height: Int(points.height) * 2)
                hasVideo = true
                consumeFrame()
                loadedGeneration = gen
                DispatchQueue.main.async { if self.currentGeneration == gen { self.onReady?(points) } }
                return
            }
        }
        loadedGeneration = gen
        DispatchQueue.main.async { if self.currentGeneration == gen { self.onReady?(nil) } }
    }

    /// Keyframe seeks are near-instant but can land seconds before `time`; exact seeks decode
    /// the whole GOP. An exact seek gives up as soon as a newer request arrives.
    private func produce(at time: Double, exact: Bool = false) -> CGImage? {
        guard hasVideo, let mpv = handle else { return nil }
        consumeFrame()   // drop anything stale before seeking
        restarted = false
        abortOnRequest = exact
        command(mpv, ["seek", String(format: "%.3f", time), exact ? "absolute+exact" : "absolute+keyframes"])
        let ok = waitForFrame(timeout: exact ? 3 : 1.5)
        abortOnRequest = false
        return ok ? renderImage() : nil
    }

    /// Position of the frame last decoded by the preview instance.
    private var shownTime: Double? {
        guard let mpv = handle else { return nil }
        var t = 0.0
        return mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &t) >= 0 ? t : nil
    }

    /// Waits until the current seek / load has produced its frame. The frame must be rendered
    /// as soon as it is ready: mpv's video output blocks (up to ~200ms) until the frame is
    /// taken, and only reports the playback restart afterwards.
    private func waitForFrame(timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var restartedAt: Date?
        while Date() < deadline {
            if abortOnRequest, hasPendingRequest { return false }
            if let rc = render, mpv_render_context_update(rc) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
                return true
            }
            pumpEvents()
            if restarted {
                // Restart without a new frame (seek landed on the frame already shown).
                if restartedAt == nil { restartedAt = Date() }
                if Date().timeIntervalSince(restartedAt!) > 0.1 { return true }
            }
            _ = wake.wait(timeout: .now() + 0.05)
        }
        return false
    }

    private func pumpEvents() {
        guard let mpv = handle else { return }
        while let event = mpv_wait_event(mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            if event.event_id == MPV_EVENT_PLAYBACK_RESTART { restarted = true }
        }
    }

    private func consumeFrame() {
        guard let rc = render, mpv_render_context_update(rc) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        _ = renderImage()
    }

    private func renderImage() -> CGImage? {
        guard let rc = render, let buffer, pixelWidth > 0 else { return nil }
        var size: [Int32] = [Int32(pixelWidth), Int32(pixelHeight)]
        var strideValue = stride
        let format = strdup("rgb0")
        defer { free(format) }
        size.withUnsafeMutableBufferPointer { sizePtr in
            withUnsafeMutablePointer(to: &strideValue) { stridePtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePtr.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(format)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: buffer),
                    mpv_render_param(),
                ]
                mpv_render_context_render(rc, &params)
            }
        }
        let data = Data(bytes: buffer, count: stride * pixelHeight) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func allocate(width: Int, height: Int) {
        guard width != pixelWidth || height != pixelHeight || buffer == nil else { return }
        free(buffer)
        buffer = nil
        pixelWidth = width
        pixelHeight = height
        stride = (width * 4 + 63) / 64 * 64   // mpv prefers 64-byte aligned rows and pointer
        var raw: UnsafeMutableRawPointer?
        if posix_memalign(&raw, 64, stride * height) == 0 { buffer = raw }
    }

    private func store(_ image: CGImage, exact: Bool, key: Int) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = (image, exact)
        if cacheOrder.count > 300 { cache[cacheOrder.removeFirst()] = nil }
    }

    /// Debug (HUSH_DEBUG snapshot hook): renders previews at the given fractions of `duration`
    /// to "<prefix>-<i>.png" and logs how long each took.
    func debugDump(fractions: [Double], duration: Double, prefix: String) {
        queue.async {
            for (i, f) in fractions.enumerated() {
                var start = Date()
                _ = self.produce(at: duration * f)
                let keyMs = Date().timeIntervalSince(start) * 1000
                let keyPos = self.shownTime ?? -1
                start = Date()
                let image = self.produce(at: duration * f, exact: true)
                NSLog("thumb %.0f%%: keyframe %.0f ms (at %.1fs), exact %@ %.0f ms (at %.1fs)", f * 100, keyMs, keyPos,
                      image == nil ? "nil" : "ok", Date().timeIntervalSince(start) * 1000, self.shownTime ?? -1)
                guard let image else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
            }
        }
    }

    // MARK: mpv instance

    private func ensureHandle() -> OpaquePointer? {
        if let handle { return handle }
        guard let mpv = mpv_create() else { return nil }
        let options: [(String, String)] = [
            ("vo", "libmpv"),
            ("pause", "yes"),
            ("idle", "yes"),
            ("keep-open", "always"),
            ("aid", "no"),
            ("sid", "no"),
            ("audio-file-auto", "no"),
            ("sub-auto", "no"),
            ("osd-level", "0"),
            ("hwdec", "no"),
            ("hr-seek", "no"),
            ("vd-lavc-threads", "4"),
            ("vd-lavc-fast", "yes"),
            ("vd-lavc-skiploopfilter", "all"),
            ("sw-fast", "yes"),
            ("zimg-scaler", "bilinear"),
            ("cache", "no"),
            ("demuxer-readahead-secs", "0"),
            ("resume-playback", "no"),
            ("save-position-on-quit", "no"),
            ("load-scripts", "no"),
            ("osc", "no"),
            ("ytdl", "no"),
            ("input-default-bindings", "no"),
            ("terminal", "no"),
        ]
        for (key, value) in options { mpv_set_option_string(mpv, key, value) }
        guard mpv_initialize(mpv) >= 0 else { mpv_destroy(mpv); return nil }

        let apiType = strdup(MPV_RENDER_API_TYPE_SW)
        defer { free(apiType) }
        var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType), mpv_render_param()]
        var rc: OpaquePointer?
        guard mpv_render_context_create(&rc, mpv, &params) >= 0, let rc else {
            mpv_terminate_destroy(mpv)
            return nil
        }

        // Both callbacks fire on mpv threads; they only wake the worker.
        let me = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(mpv, { ctx in
            Unmanaged<Thumbnailer>.fromOpaque(ctx!).takeUnretainedValue().wake.signal()
        }, me)
        mpv_render_context_set_update_callback(rc, { ctx in
            Unmanaged<Thumbnailer>.fromOpaque(ctx!).takeUnretainedValue().wake.signal()
        }, me)
        handle = mpv
        render = rc
        return mpv
    }

    private func command(_ mpv: OpaquePointer, _ args: [String]) {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        mpv_command(mpv, &cargs)
    }
}
