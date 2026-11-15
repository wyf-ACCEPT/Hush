import AppKit

/// Bottom control bar: full-width seek line on top, transport + volume on the left,
/// time in the middle, speed / subtitles / settings / pin / full screen on the right.
final class ControlBar: NSView {
    static let barHeight: CGFloat = 52
    /// The seek bar straddles the top edge of the glass, so the view is a bit taller than the bar.
    static let totalHeight: CGFloat = barHeight + 8

    private let glass = NSVisualEffectView()
    let seekBar = TrackSlider()
    let volumeSlider = TrackSlider()
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")

    let prevButton: IconButton
    let rewindButton: IconButton
    let playButton: IconButton
    let forwardButton: IconButton
    let stepButton: IconButton
    let nextButton: IconButton
    let volumeButton: IconButton
    let speedButton: IconButton
    let subtitleButton: IconButton
    let settingsButton: IconButton
    let pinButton: IconButton
    let fullscreenButton: IconButton

    init(target: PlayerWindowController) {
        typealias P = PlayerWindowController
        prevButton = IconButton("backward.end.fill", size: 14, tip: "上一个", target: target, action: #selector(P.playlistPrev(_:)))
        rewindButton = IconButton("backward.fill", size: 15, tip: "快退", target: target, action: #selector(P.seekBackward(_:)))
        playButton = IconButton("play.fill", size: 21, tip: "播放 / 暂停（空格）", target: target, action: #selector(P.togglePause(_:)))
        forwardButton = IconButton("forward.fill", size: 15, tip: "快进", target: target, action: #selector(P.seekForward(_:)))
        stepButton = IconButton("", tip: "快进 / 快退步长", target: target, action: #selector(P.showSeekStepMenu(_:)))
        nextButton = IconButton("forward.end.fill", size: 14, tip: "下一个", target: target, action: #selector(P.playlistNext(_:)))
        volumeButton = IconButton("speaker.wave.2.fill", size: 14, tip: "静音", target: target, action: #selector(P.toggleMute(_:)))
        speedButton = IconButton("", tip: "播放速度", target: target, action: #selector(P.showSpeedPanel(_:)))
        subtitleButton = IconButton("captions.bubble", size: 15, tip: "字幕", target: target, action: #selector(P.showSubtitleMenu(_:)))
        settingsButton = IconButton("gearshape", size: 15, tip: "设置", target: target, action: #selector(P.showSettingsMenu(_:)))
        pinButton = IconButton("pin", size: 14, tip: "窗口置顶", target: target, action: #selector(P.toggleFloatOnTop(_:)))
        fullscreenButton = IconButton("arrow.up.left.and.arrow.down.right", size: 14, tip: "全屏", target: target,
                                      action: #selector(P.toggleFullScreenAction(_:)))
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: Self.totalHeight))

        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        addSubview(glass)

        speedButton.text = "1.0x"
        stepButton.text = SeekStep.label(SeekStep.value)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = Theme.text
        timeLabel.alignment = .center

        for v in [prevButton, rewindButton, playButton, forwardButton, stepButton, nextButton, volumeButton, volumeSlider,
                  timeLabel, speedButton, subtitleButton, settingsButton, pinButton, fullscreenButton] as [NSView] {
            addSubview(v)
        }

        seekBar.trackHeight = 3
        seekBar.activeTrackHeight = 5
        seekBar.knobDiameter = 12
        addSubview(seekBar)

        volumeSlider.trackHeight = 3
        volumeSlider.activeTrackHeight = 4
        volumeSlider.knobDiameter = 11
        volumeSlider.maxValue = 100
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // The strip above the glass is transparent: only the seek bar there takes clicks.
        if hit === self, convert(point, from: superview).y > Self.barHeight { return nil }
        return hit
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let bar = Self.barHeight
        glass.frame = NSRect(x: 0, y: 0, width: w, height: bar)
        seekBar.frame = NSRect(x: 0, y: bar - 8, width: w, height: 16)

        let cy = (bar - 6) / 2   // row centre, slightly below the seek line
        func place(_ v: NSView, _ x: CGFloat, _ width: CGFloat, _ height: CGFloat = 30) {
            v.frame = NSRect(x: x, y: (cy - height / 2).rounded(), width: width, height: height)
        }

        let compact = w < 520
        let tiny = w < 400
        rewindButton.isHidden = tiny
        forwardButton.isHidden = tiny
        stepButton.isHidden = tiny
        volumeSlider.isHidden = compact

        // Left group.
        var x: CGFloat = 12
        place(prevButton, x, 30); x += 32
        if !tiny { place(rewindButton, x, 30); x += 32 }
        place(playButton, x, 34, 34); x += 36
        if !tiny {
            place(forwardButton, x, 30); x += 31
            place(stepButton, x, 38); x += 40
        }
        place(nextButton, x, 30); x += 40
        place(volumeButton, x, 28); x += 30
        if !compact { place(volumeSlider, x, 86, 20); x += 90 }
        let leftEnd = x

        // Right group, laid out from the right edge.
        var r = w - 12
        r -= 30; place(fullscreenButton, r, 30)
        r -= 32; place(pinButton, r, 30)
        r -= 32; place(settingsButton, r, 30)
        r -= 32; place(subtitleButton, r, 30)
        r -= 54; place(speedButton, r, 52)
        let rightStart = r

        // Time stays centred on the window, hidden if it would collide with either group.
        let timeWidth: CGFloat = 130
        let tx = ((w - timeWidth) / 2).rounded()
        timeLabel.frame = NSRect(x: tx, y: (cy - 8).rounded(), width: timeWidth, height: 16)
        timeLabel.isHidden = tx < leftEnd + 4 || tx + timeWidth > rightStart - 4
    }

    // MARK: Updates from the player

    func updateTime(position: Double, duration: Double, cache: Double?) {
        let hours = duration >= 3600
        timeLabel.stringValue = "\(Theme.time(position, hours: hours)) / \(Theme.time(duration, hours: hours))"
        seekBar.isEnabled = duration > 0
        seekBar.maxValue = max(duration, 0.001)
        seekBar.secondaryValue = cache
        if !seekBar.dragging { seekBar.value = position }
    }

    func updateState(paused: Bool, volume: Double, muted: Bool, speed: Double, seekStep: Double,
                     canPrev: Bool, canNext: Bool, floating: Bool, fullscreen: Bool) {
        stepButton.text = SeekStep.label(seekStep)
        stepButton.toolTip = "快进 / 快退步长：\(SeekStep.phrase(seekStep))（点击修改）"
        rewindButton.toolTip = "快退 \(SeekStep.phrase(seekStep))（←）"
        forwardButton.toolTip = "快进 \(SeekStep.phrase(seekStep))（→）"
        playButton.symbolName = paused ? "play.fill" : "pause.fill"
        let level = muted ? -1 : volume
        volumeButton.symbolName = level <= 0 ? "speaker.slash.fill"
            : level < 34 ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        volumeButton.toolTip = muted ? "取消静音" : "静音"
        if !volumeSlider.dragging { volumeSlider.value = muted ? 0 : min(volume, 100) }
        speedButton.text = Theme.speed(speed)
        speedButton.highlightText = abs(speed - 1) > 0.001
        prevButton.isEnabled = canPrev
        nextButton.isEnabled = canNext
        pinButton.symbolName = floating ? "pin.fill" : "pin"
        pinButton.isActive = floating
        pinButton.toolTip = floating ? "取消置顶" : "窗口置顶"
        fullscreenButton.symbolName = fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        fullscreenButton.toolTip = fullscreen ? "退出全屏" : "全屏"
    }
}

/// Floats above the seek bar while hovering or dragging: a frame preview (when the file has
/// video) with the time under it, or just the time.
final class TimeBubble: NSView {
    private let label = NSTextField(labelWithString: "")
    private let imageLayer = CALayer()
    /// Preview size in points; nil shows the time only.
    var previewSize: NSSize? {
        didSet { if previewSize != oldValue { imageLayer.contents = nil } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.borderWidth = 1
        imageLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.cornerRadius = 5
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Keeps showing the previous frame until the new one arrives, so scrubbing doesn't flicker.
    func setImage(_ image: CGImage) {
        imageLayer.contents = image
    }

    func show(_ text: String, centerX: CGFloat, bottomY: CGFloat, within width: CGFloat) {
        label.stringValue = text
        let size: NSSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let preview = previewSize {
            let pad: CGFloat = 3
            size = NSSize(width: preview.width + pad * 2, height: preview.height + pad + 22)
            imageLayer.isHidden = false
            imageLayer.frame = NSRect(x: pad, y: 22, width: preview.width, height: preview.height)
            label.frame = NSRect(x: 0, y: 3, width: size.width, height: 15)
        } else {
            size = NSSize(width: label.intrinsicContentSize.width + 14, height: 20)
            imageLayer.isHidden = true
            label.frame = NSRect(x: 0, y: 2, width: size.width, height: 15)
        }
        let x = min(max(centerX - size.width / 2, 4), width - size.width - 4)
        frame = NSRect(x: x.rounded(), y: bottomY, width: size.width, height: size.height)
        CATransaction.commit()
        isHidden = false
    }
}

/// Top gradient with the media title, shown together with the control bar.
final class TitleOverlay: NSView {
    private let label = NSTextField(labelWithString: "")
    private let gradient = CAGradientLayer()

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.colors = [NSColor(white: 0, alpha: 0.55).cgColor, NSColor(white: 0, alpha: 0).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.text
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
        shadow.shadowBlurRadius = 3
        label.shadow = shadow
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        // Vertically aligned with the traffic-light buttons (28pt title bar).
        label.frame = NSRect(x: 90, y: bounds.height - 22, width: max(bounds.width - 180, 0), height: 17)
    }
}
