import AppKit
import CMpv
import OpenGL.GL3

/// Owns the mpv handle and the OpenGL render context.
/// All client-API calls happen on the main thread; rendering happens inside VideoLayer.draw.
final class MPVController {
    private(set) var handle: OpaquePointer?
    private(set) var renderContext: OpaquePointer?

    // Observed state, mirrored for the UI.
    private(set) var speed: Double = 1.0
    private(set) var paused = false
    private(set) var hasMedia = false
    private(set) var videoSize: NSSize?
    private(set) var timePos: Double = 0
    private(set) var duration: Double = 0
    private(set) var cacheTime: Double?
    private(set) var volume: Double = 100
    private(set) var muted = false
    private(set) var playlistPos: Int64 = -1
    private(set) var playlistCount: Int64 = 0
    private(set) var tracks: [Track] = []

    struct Track {
        let id: Int64
        let type: String      // "video", "audio" or "sub"
        let title: String?
        let lang: String?
        let codec: String?
        let selected: Bool
        let external: Bool

        var displayName: String {
            var parts: [String] = []
            if let title, !title.isEmpty { parts.append(title) }
            if let lang, !lang.isEmpty { parts.append(lang) }
            if parts.isEmpty { parts.append("#\(id)") }
            if let codec, !codec.isEmpty { parts.append("(\(codec))") }
            if external { parts.append("[外挂]") }
            return parts.joined(separator: " ")
        }
    }

    var onSpeedChange: ((Double) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onPathChange: ((String?) -> Void)?
    var onFullscreenRequest: ((Bool) -> Void)?
    var onVideoSize: ((NSSize) -> Void)?
    var onIdle: ((Bool) -> Void)?
    var onShutdown: (() -> Void)?
    var onVolumeChange: ((Double) -> Void)?
    /// Playback position / duration / cache changed (fires up to once per frame).
    var onTimeChange: (() -> Void)?
    /// Pause, volume, mute, speed, playlist or track list changed.
    var onStateChange: (() -> Void)?
    /// A seek happened (keyboard, menu or seek bar).
    var onSeek: (() -> Void)?

    init(ipcSocket: String? = nil) {
        guard let mpv = mpv_create() else { fatalError("mpv_create failed") }
        handle = mpv

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hush", isDirectory: true)
        let watchLater = support.appendingPathComponent("watch_later", isDirectory: true)
        try? FileManager.default.createDirectory(at: watchLater, withIntermediateDirectories: true)

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]

        var options: [(String, String)] = [
            ("vo", "libmpv"),
            ("hwdec", "auto-safe"),
            ("idle", "yes"),
            // force-window is turned on later, once the render context exists.
            ("keep-open", "yes"),
            // The native AppKit control bar replaces mpv's OSC and OSD seek bar.
            ("osc", "no"),
            ("osd-bar", "no"),
            ("osd-font", "PingFang SC"),
            ("osd-font-size", "30"),
            ("osd-border-size", "1.5"),
            ("input-default-bindings", "yes"),
            ("input-vo-keyboard", "yes"),
            ("sub-auto", "fuzzy"),
            ("sub-codepage", "auto"),
            ("audio-file-auto", "fuzzy"),
            ("hr-seek-framedrop", "no"),
            ("save-position-on-quit", "yes"),
            ("watch-later-dir", watchLater.path),
            ("screenshot-directory", desktop.path),
            ("screenshot-template", "Hush-%F-%P"),
            ("ytdl", "yes"),
            ("terminal", "no"),
        ]
        if let inputConf = Bundle.main.path(forResource: "input", ofType: "conf") {
            options.append(("input-conf", inputConf))
        }
        // Debug hook: HUSH_IPC=/path/to/socket exposes mpv's JSON IPC for scripted checks.
        if let ipcSocket {
            options.append(("input-ipc-server", ipcSocket))
        }
        // Restore the last speed / volume so a habitual 1.25x sticks across launches.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "speed") != nil {
            options.append(("speed", String(defaults.double(forKey: "speed"))))
        }
        if defaults.object(forKey: "volume") != nil {
            options.append(("volume", String(defaults.double(forKey: "volume"))))
        }
        for (key, value) in options {
            let rc = mpv_set_option_string(mpv, key, value)
            if rc < 0 { NSLog("mpv option %@=%@ failed: %@", key, value, String(cString: mpv_error_string(rc))) }
        }

        mpv_request_log_messages(mpv, "warn")
        check(mpv_initialize(mpv), "mpv_initialize")

        mpv_observe_property(mpv, 0, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "media-title", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, "path", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, "fullscreen", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "idle-active", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "mute", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "playlist-pos", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "playlist-count", MPV_FORMAT_INT64)
        // Only used as a change notification; tracks are read back via sub-properties.
        mpv_observe_property(mpv, 0, "track-list", MPV_FORMAT_NONE)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(mpv, { ctx in
            let controller = Unmanaged<MPVController>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { controller.drainEvents() }
        }, ctx)
    }

    // MARK: Render context (called from VideoLayer with the CGL context current)

    func createRenderContext(updateCallback: @escaping () -> Void) {
        guard let mpv = handle, renderContext == nil else { return }

        let getProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
            guard let name else { return nil }
            let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
            let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
            return CFBundleGetFunctionPointerForName(bundle, symbol)
        }

        var glInit = mpv_opengl_init_params(get_proc_address: getProcAddress, get_proc_address_ctx: nil)
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }

        withUnsafeMutablePointer(to: &glInit) { glInitPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: glInitPtr),
                mpv_render_param(),
            ]
            var ctx: OpaquePointer?
            check(mpv_render_context_create(&ctx, mpv, &params), "mpv_render_context_create")
            renderContext = ctx
        }

        renderUpdate = updateCallback
        let me = Unmanaged.passUnretained(self).toOpaque()
        mpv_render_context_set_update_callback(renderContext, { ctx in
            let controller = Unmanaged<MPVController>.fromOpaque(ctx!).takeUnretainedValue()
            controller.renderUpdate?()
        }, me)
    }

    private var renderUpdate: (() -> Void)?

    /// Returns true when mpv has a new frame to draw.
    func renderNeedsFrame() -> Bool {
        guard let rc = renderContext else { return false }
        return (mpv_render_context_update(rc) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0
    }

    /// Renders the current frame into `fbo`. With `skip`, mpv only consumes the frame
    /// (advancing its timing) without drawing; used when Core Animation declined to draw.
    func render(fbo: Int32, width: Int32, height: Int32, skip: Bool = false) {
        guard let rc = renderContext else { return }
        var fboParams = mpv_opengl_fbo(fbo: fbo, w: width, h: height, internal_format: 0)
        var flipY: Int32 = 1
        // Don't sleep until the frame's target time inside render(): the layer's
        // vsync already paces us, and sleeping on top of it pushes every frame late.
        var blockForTarget: Int32 = 0
        var skipRendering: Int32 = skip ? 1 : 0
        withUnsafeMutablePointer(to: &fboParams) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                withUnsafeMutablePointer(to: &blockForTarget) { blockPtr in
                    withUnsafeMutablePointer(to: &skipRendering) { skipPtr in
                        var params = [
                            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blockPtr),
                            mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: skipPtr),
                            mpv_render_param(),
                        ]
                        mpv_render_context_render(rc, &params)
                    }
                }
            }
        }
    }

    func reportSwap() {
        if let rc = renderContext { mpv_render_context_report_swap(rc) }
    }

    // MARK: Commands

    func command(_ args: [String]) {
        guard let mpv = handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        mpv_command(mpv, &cargs)
    }

    /// String form: supports prefixes such as `osd-msg`.
    func commandString(_ cmd: String) {
        guard let mpv = handle else { return }
        mpv_command_string(mpv, cmd)
    }

    func open(_ urls: [URL], append: Bool = false) {
        let subtitleExts: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi", "lrc"]
        var first = !append
        for url in urls {
            let target = url.isFileURL ? url.path : url.absoluteString
            if url.isFileURL, subtitleExts.contains(url.pathExtension.lowercased()) {
                command(["sub-add", target, "select"])
                continue
            }
            command(["loadfile", target, first ? "replace" : "append-play"])
            first = false
            if url.isFileURL { RecentFiles.add(url) }
        }
    }

    func setSpeed(_ value: Double) {
        let clamped = min(max(value, 0.1), 8.0)
        commandString(String(format: "osd-msg set speed %.2f", clamped))
    }

    func setFlag(_ name: String, _ value: Bool) {
        guard let mpv = handle else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &flag)
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let mpv = handle else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
    }

    func getString(_ name: String) -> String? {
        guard let mpv = handle, let cstr = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    func getInt(_ name: String) -> Int64? {
        guard let mpv = handle else { return nil }
        var value: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    // MARK: Events

    private func drainEvents() {
        guard let mpv = handle else { return }
        while true {
            guard let event = mpv_wait_event(mpv, 0)?.pointee else { return }
            switch event.event_id {
            case MPV_EVENT_NONE:
                return
            case MPV_EVENT_SHUTDOWN:
                onShutdown?()
                return
            case MPV_EVENT_LOG_MESSAGE:
                if let msg = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                    let text = String(cString: msg.text).trimmingCharacters(in: .newlines)
                    NSLog("[mpv/%@] %@", String(cString: msg.prefix), text)
                }
            case MPV_EVENT_VIDEO_RECONFIG:
                if let w = getInt("video-out-params/dw"), let h = getInt("video-out-params/dh"), w > 0, h > 0 {
                    let size = NSSize(width: CGFloat(w), height: CGFloat(h))
                    if size != videoSize {
                        videoSize = size
                        onVideoSize?(size)
                    }
                }
            case MPV_EVENT_START_FILE:
                videoSize = nil
            case MPV_EVENT_SEEK:
                onSeek?()
            case MPV_EVENT_PROPERTY_CHANGE:
                handleProperty(event.data!.assumingMemoryBound(to: mpv_event_property.self).pointee)
            default:
                break
            }
        }
    }

    private func reloadTracks() {
        let count = Int(getInt("track-list/count") ?? 0)
        tracks = (0..<count).compactMap { i in
            let base = "track-list/\(i)/"
            guard let id = getInt(base + "id"), let type = getString(base + "type") else { return nil }
            return Track(id: id, type: type, title: getString(base + "title"), lang: getString(base + "lang"),
                         codec: getString(base + "codec"), selected: getString(base + "selected") == "yes",
                         external: getString(base + "external") == "yes")
        }
    }

    private func handleProperty(_ prop: mpv_event_property) {
        let name = String(cString: prop.name)
        if name == "track-list" {
            reloadTracks()
            onStateChange?()
            return
        }
        guard let data = prop.data else {
            // Property became unavailable (e.g. no file loaded).
            switch name {
            case "time-pos": timePos = 0; onTimeChange?()
            case "duration": duration = 0; onTimeChange?()
            case "demuxer-cache-time": cacheTime = nil
            default: break
            }
            return
        }
        switch (name, prop.format) {
        case ("speed", MPV_FORMAT_DOUBLE):
            speed = data.assumingMemoryBound(to: Double.self).pointee
            UserDefaults.standard.set(speed, forKey: "speed")
            onSpeedChange?(speed)
            onStateChange?()
        case ("volume", MPV_FORMAT_DOUBLE):
            volume = data.assumingMemoryBound(to: Double.self).pointee
            UserDefaults.standard.set(volume, forKey: "volume")
            onVolumeChange?(volume)
            onStateChange?()
        case ("mute", MPV_FORMAT_FLAG):
            muted = data.assumingMemoryBound(to: Int32.self).pointee != 0
            onStateChange?()
        case ("time-pos", MPV_FORMAT_DOUBLE):
            timePos = data.assumingMemoryBound(to: Double.self).pointee
            onTimeChange?()
        case ("duration", MPV_FORMAT_DOUBLE):
            duration = data.assumingMemoryBound(to: Double.self).pointee
            onTimeChange?()
        case ("demuxer-cache-time", MPV_FORMAT_DOUBLE):
            cacheTime = data.assumingMemoryBound(to: Double.self).pointee
        case ("playlist-pos", MPV_FORMAT_INT64):
            playlistPos = data.assumingMemoryBound(to: Int64.self).pointee
            onStateChange?()
        case ("playlist-count", MPV_FORMAT_INT64):
            playlistCount = data.assumingMemoryBound(to: Int64.self).pointee
            onStateChange?()
        case ("pause", MPV_FORMAT_FLAG):
            paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
            onStateChange?()
        case ("media-title", MPV_FORMAT_STRING):
            let s = data.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee
            onTitleChange?(String(cString: s))
        case ("path", MPV_FORMAT_STRING):
            let s = data.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee
            onPathChange?(String(cString: s))
        case ("fullscreen", MPV_FORMAT_FLAG):
            onFullscreenRequest?(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case ("idle-active", MPV_FORMAT_FLAG):
            let idle = data.assumingMemoryBound(to: Int32.self).pointee != 0
            hasMedia = !idle
            onIdle?(idle)
            onStateChange?()
        default:
            break
        }
    }

    // MARK: Teardown

    /// Must be called with the render GL context current (VideoLayer handles that).
    func freeRenderContext() {
        if let rc = renderContext {
            mpv_render_context_set_update_callback(rc, nil, nil)
            mpv_render_context_free(rc)
            renderContext = nil
        }
    }

    func destroy() {
        guard let mpv = handle else { return }
        handle = nil
        // terminate_destroy runs `quit`, which writes the watch-later resume point.
        mpv_terminate_destroy(mpv)
    }

    private func check(_ rc: Int32, _ what: String) {
        if rc < 0 { fatalError("\(what) failed: \(String(cString: mpv_error_string(rc)))") }
    }
}
