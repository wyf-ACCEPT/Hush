import AppKit

/// Hosts the video layer and forwards keyboard / mouse-button / wheel input to mpv,
/// so mpv's default key bindings (and input.conf) keep working under the native UI.
final class VideoView: NSView {
    let mpv: MPVController
    let videoLayer: VideoLayer

    private var scrollAccumY: CGFloat = 0
    private var scrollAccumX: CGFloat = 0
    private var mouseDownPoint: NSPoint?
    private var pendingClick: DispatchWorkItem?
    private var lastClickFired: Date?

    /// Single click on the picture (fired after a short delay so a double click can cancel it).
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// Plain arrow key (key code 123–126); return true when handled.
    var onArrowKey: ((UInt16) -> Bool)?

    init(mpv: MPVController) {
        self.mpv = mpv
        self.videoLayer = VideoLayer(mpv: mpv)
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func makeBackingLayer() -> CALayer { videoLayer }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, (123...126).contains(event.keyCode), onArrowKey?(event.keyCode) == true { return }
        guard let name = Self.mpvKeyName(event) else { return }
        mpv.command(["keypress", name])
    }

    private static let specialKeys: [UInt16: String] = [
        49: "SPACE", 36: "ENTER", 76: "KP_ENTER", 53: "ESC", 51: "BS", 117: "DEL", 48: "TAB",
        123: "LEFT", 124: "RIGHT", 125: "DOWN", 126: "UP",
        115: "HOME", 119: "END", 116: "PGUP", 121: "PGDWN",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func mpvKeyName(_ event: NSEvent) -> String? {
        let flags = event.modifierFlags
        var mods: [String] = []
        if flags.contains(.control) { mods.append("Ctrl") }
        if flags.contains(.option) { mods.append("Alt") }
        if flags.contains(.command) { mods.append("Meta") }

        var key: String
        if let special = specialKeys[event.keyCode] {
            key = special
            if flags.contains(.shift) { mods.append("Shift") }
        } else {
            // With Ctrl/Alt/Cmd use the unmodified character (Alt would otherwise give "å" etc.).
            // charactersIgnoringModifiers still honours Shift, so "{" stays "{".
            let useRaw = !mods.isEmpty
            guard let chars = useRaw ? event.charactersIgnoringModifiers : event.characters,
                  let c = chars.first else { return nil }
            key = String(c)
        }
        switch key {
        case "+": key = "PLUS"
        case "#": key = "SHARP"
        default: break
        }
        return (mods + [key]).joined(separator: "+")
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        // Dragging the picture moves the window (the title bar is hidden under the video).
        guard let start = mouseDownPoint, let window, !window.styleMask.contains(.fullScreen) else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > 3 {
            mouseDownPoint = nil
            window.performDrag(with: event)
        }
    }

    /// Click = play / pause, double click = full screen. The single click waits briefly so a
    /// double click doesn't pause first; a slow double click undoes the pause instead.
    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }   // the press turned into a window drag
        mouseDownPoint = nil
        if event.clickCount >= 2 {
            if let pendingClick {
                pendingClick.cancel()
                self.pendingClick = nil
            } else if let fired = lastClickFired, Date().timeIntervalSince(fired) < NSEvent.doubleClickInterval {
                onClick?()
            }
            lastClickFired = nil
            if event.clickCount == 2 { onDoubleClick?() }
        } else if event.clickCount == 1 {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingClick = nil
                self?.lastClickFired = Date()
                self?.onClick?()
            }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + min(NSEvent.doubleClickInterval, 0.25), execute: work)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        mpv.command(["keypress", "MBTN_RIGHT"])
    }

    override func scrollWheel(with event: NSEvent) {
        // Normalise to physical direction so "fingers up / wheel away" is always positive.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollAccumY += event.scrollingDeltaY * sign
        scrollAccumX += event.scrollingDeltaX * sign
        while abs(scrollAccumY) >= step {
            mpv.command(["keypress", scrollAccumY > 0 ? "WHEEL_UP" : "WHEEL_DOWN"])
            scrollAccumY -= scrollAccumY > 0 ? step : -step
        }
        let stepX = step * 3
        while abs(scrollAccumX) >= stepX {
            mpv.command(["keypress", scrollAccumX > 0 ? "WHEEL_LEFT" : "WHEEL_RIGHT"])
            scrollAccumX -= scrollAccumX > 0 ? stepX : -stepX
        }
        if event.phase == .ended || event.momentumPhase == .ended {
            scrollAccumX = 0
            scrollAccumY = 0
        }
    }
}
