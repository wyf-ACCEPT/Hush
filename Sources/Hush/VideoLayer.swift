import AppKit
import OpenGL.GL3

/// CAOpenGLLayer that mpv renders into through the libmpv render API (same approach as IINA).
final class VideoLayer: CAOpenGLLayer {
    private let mpv: MPVController
    private(set) var glContext: CGLContextObj?
    /// Fired once, after the mpv render context exists; files can only be loaded after this.
    var onReady: (() -> Void)?
    private let renderQueue = DispatchQueue(label: "hush.render", qos: .userInteractive)
    private var tornDown = false
    /// Set before display(); draw() clears it. Still set afterwards means CA skipped the draw.
    private var needsFlip = false
    /// Written on main from occlusion changes, read on the render queue (a stale read only costs one frame).
    private var windowVisible = true

    init(mpv: MPVController) {
        self.mpv = mpv
        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    override init(layer: Any) {
        let other = layer as! VideoLayer
        mpv = other.mpv
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(rawValue: UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFADoubleBuffer,
            kCGLPFAAccelerated,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFASupportsAutomaticGraphicsSwitching,
            CGLPixelFormatAttribute(rawValue: 0),
        ]
        var pix: CGLPixelFormatObj?
        var count: GLint = 0
        let rc = CGLChoosePixelFormat(attrs, &pix, &count)
        guard rc == kCGLNoError, let pix else { fatalError("CGLChoosePixelFormat failed: \(rc)") }
        return pix
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        let ctx = super.copyCGLContext(forPixelFormat: pf)
        var swapInterval: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swapInterval)
        CGLEnable(ctx, kCGLCEMPEngine)
        CGLSetCurrentContext(ctx)

        if glContext == nil {
            glContext = ctx
            mpv.createRenderContext { [weak self] in
                // Called on an mpv thread: draw synchronously on our render queue
                // (waiting for the main-thread CA commit drops most frames).
                guard let self else { return }
                self.renderQueue.async { self.renderFrame() }
            }
            DispatchQueue.main.async { [weak self] in
                self?.onReady?()
                self?.onReady = nil
            }
        }
        return ctx
    }

    /// Runs on the render queue for every mpv update (pattern from mpv's cocoa-cb gl_layer.swift).
    private func renderFrame(force: Bool = false) {
        guard !tornDown else { return }
        guard mpv.renderNeedsFrame() || force else { return }
        needsFlip = true
        if !windowVisible && !force {
            consumeWithoutDrawing()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display()
        CATransaction.commit()
        CATransaction.flush()
        // CA may decline to draw (occluded window, throttling). mpv still waits for the
        // frame to be consumed, and drops frames if it isn't, so consume it without drawing.
        if needsFlip { consumeWithoutDrawing() }
    }

    private func consumeWithoutDrawing() {
        guard let ctx = glContext else { return }
        needsFlip = false
        CGLLockContext(ctx)
        CGLSetCurrentContext(ctx)
        mpv.render(fbo: 0, width: 1, height: 1, skip: true)
        mpv.reportSwap()
        CGLUnlockContext(ctx)
        Self.debugSkips += 1
    }

    /// Called on main when the window's occlusion state changes.
    func setWindowVisible(_ visible: Bool) {
        renderQueue.async {
            let becameVisible = visible && !self.windowVisible
            self.windowVisible = visible
            Self.debugVisible = visible
            // Frames consumed while hidden were never drawn; repaint the current one.
            if becameVisible { self.renderFrame(force: true) }
        }
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        // Both the render queue and main-thread resizes draw here.
        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }
        guard !tornDown else { return }
        needsFlip = false

        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        if mpv.renderContext != nil {
            let start = CACurrentMediaTime()
            mpv.render(fbo: fbo, width: viewport[2], height: viewport[3])
            Self.debugCount(render: CACurrentMediaTime() - start, size: (viewport[2], viewport[3]))
        } else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        glFlush()
        mpv.reportSwap()
    }

    // Debug: HUSH_DEBUG=1 prints draws per second and average render time to stderr.
    private static let debug = ProcessInfo.processInfo.environment["HUSH_DEBUG"] != nil
    private static var debugDraws = 0
    private static var debugSkips = 0
    static var debugVisible = true
    private static var debugRenderTime = 0.0
    private static var debugWindowStart = CACurrentMediaTime()

    private static func debugCount(render: Double, size: (GLint, GLint)) {
        guard debug else { return }
        debugDraws += 1
        debugRenderTime += render
        let now = CACurrentMediaTime()
        if now - debugWindowStart >= 1 {
            let line = String(format: "visible=%d draws/s=%d skips/s=%d avg_render_ms=%.2f thread=%@ size=%dx%d\n",
                              debugVisible ? 1 : 0, debugDraws, debugSkips, debugRenderTime / Double(max(debugDraws, 1)) * 1000,
                              Thread.isMainThread ? "main" : "render", size.0, size.1)
            FileHandle.standardError.write(line.data(using: .utf8)!)
            debugDraws = 0
            debugSkips = 0
            debugRenderTime = 0
            debugWindowStart = now
        }
    }

    /// Frees the render context with our GL context current, as libmpv requires.
    func teardown() {
        renderQueue.sync {
            tornDown = true
            guard let ctx = glContext else { mpv.freeRenderContext(); return }
            CGLLockContext(ctx)
        CGLSetCurrentContext(ctx)
            mpv.freeRenderContext()
            CGLUnlockContext(ctx)
        }
    }
}
