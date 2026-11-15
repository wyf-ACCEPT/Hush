import AppKit

/// Window content: video at the bottom, then the idle screen, title overlay and control bar.
/// Also owns mouse tracking (for auto-hiding controls) and file drops.
final class PlayerContentView: NSView {
    let videoView: VideoView
    let idleView = IdleView()
    let titleOverlay = TitleOverlay()
    let controlBar: ControlBar
    let bubble = TimeBubble()

    var onMouseActivity: (() -> Void)?
    var onMouseExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    private var trackingArea: NSTrackingArea?

    init(mpv: MPVController, controller: PlayerWindowController) {
        videoView = VideoView(mpv: mpv)
        controlBar = ControlBar(target: controller)
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for v in [videoView, idleView, titleOverlay, controlBar, bubble] as [NSView] { addSubview(v) }
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        videoView.frame = bounds
        idleView.frame = bounds
        titleOverlay.frame = NSRect(x: 0, y: h - 48, width: w, height: 48)
        controlBar.frame = NSRect(x: 0, y: 0, width: w, height: ControlBar.totalHeight)
    }

    var mouseInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    var mouseOverControls: Bool {
        guard let window, !controlBar.isHidden else { return false }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return controlBar.frame.contains(p) || p.y > bounds.height - 30
    }

    // MARK: Mouse tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { onMouseActivity?() }
    override func mouseEntered(with event: NSEvent) { onMouseActivity?() }
    override func mouseExited(with event: NSEvent) { onMouseExit?() }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        idleView.dropHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { idleView.dropHighlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        idleView.dropHighlighted = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// One player window with its own mpv instance. Menu actions reach it through the responder chain.
final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let mpv: MPVController
    let thumbnailer = Thumbnailer()
    private var content: PlayerContentView!
    private var ready = false
    private var pendingURLs: [URL] = []
    private var closed = false
    private var hideTimer: Timer?
    private var controlsShown = true
    private var occlusionObserver: NSObjectProtocol?
    private var seekStepObserver: NSObjectProtocol?
    private var speedPopover: NSPopover?
    private var speedPanel: SpeedPanel?

    var onClose: ((PlayerWindowController) -> Void)?

    /// True when this window can take a new file without interrupting playback.
    var isIdle: Bool { !mpv.hasMedia && pendingURLs.isEmpty }

    init(ipcSocket: String?) {
        mpv = MPVController(ipcSocket: ipcSocket)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Hush"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 360, height: 220)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        content = PlayerContentView(mpv: mpv, controller: self)
        window.contentView = content
        window.delegate = self
        // Stop drawing while the window is fully hidden; mpv frames are still consumed.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, let window = self.window else { return }
            self.content.videoView.videoLayer.setWindowVisible(window.occlusionState.contains(.visible))
        }
        seekStepObserver = NotificationCenter.default.addObserver(
            forName: SeekStep.changed, object: nil, queue: .main) { [weak self] _ in self?.refreshState() }
        wireCallbacks()
        setIdle(true)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// Shows the window and creates the GL + mpv render context right away.
    func start() {
        showWindow(nil)
        window?.makeFirstResponder(content.videoView)
        content.videoView.videoLayer.display()
    }

    private func wireCallbacks() {
        content.videoView.videoLayer.onReady = { [weak self] in
            guard let self else { return }
            self.ready = true
            self.mpv.commandString("set force-window yes")
            if !self.pendingURLs.isEmpty {
                self.mpv.open(self.pendingURLs)
                self.pendingURLs = []
            }
        }
        content.onDrop = { [weak self] urls in self?.open(urls) }
        content.videoView.onClick = { [weak self] in
            guard let self, self.mpv.hasMedia else { return }
            self.togglePause(nil)
        }
        content.videoView.onDoubleClick = { [weak self] in self?.toggleFullScreenAction(nil) }
        content.videoView.onArrowKey = { [weak self] code in self?.handleArrowKey(code) ?? false }
        content.onMouseActivity = { [weak self] in self?.mouseActivity() }
        content.onMouseExit = { [weak self] in self?.scheduleHide(after: 0.6) }
        content.idleView.onOpen = { [weak self] in self?.openFile(nil) }
        content.idleView.onOpenRecent = { [weak self] url in self?.open([url]) }

        let bar = content.controlBar
        bar.seekBar.onChange = { [weak self] value, final in
            // Keyframe seeks while scrubbing keep it responsive; the exact seek lands on release.
            self?.mpv.command(["seek", String(format: "%.3f", value), final ? "absolute+exact" : "absolute+keyframes"])
        }
        bar.seekBar.onHover = { [weak self] value in self?.showSeekBubble(value) }
        bar.volumeSlider.onChange = { [weak self] value, _ in
            guard let self else { return }
            if self.mpv.muted { self.mpv.setFlag("mute", false) }
            self.mpv.setDouble("volume", value.rounded())
        }

        mpv.onTitleChange = { [weak self] title in
            self?.window?.title = title
            self?.content.titleOverlay.title = title
        }
        mpv.onPathChange = { [weak self] path in
            self?.thumbnailer.load(path: path)
            guard let path, !path.contains("://") else { self?.window?.representedURL = nil; return }
            self?.window?.representedURL = URL(fileURLWithPath: path)
        }
        thumbnailer.onReady = { [weak self] size in self?.content.bubble.previewSize = size }
        thumbnailer.onImage = { [weak self] _, image in self?.content.bubble.setImage(image) }
        mpv.onIdle = { [weak self] idle in self?.setIdle(idle) }
        mpv.onFullscreenRequest = { [weak self] wantFullscreen in
            guard let window = self?.window else { return }
            if wantFullscreen != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
        mpv.onVideoSize = { [weak self] size in
            // While idle, force-window makes mpv report a placeholder size; ignore it.
            guard let self, self.mpv.hasMedia else { return }
            self.fitWindow(to: size)
        }
        mpv.onShutdown = { [weak self] in
            // `q` inside mpv closes just this window.
            guard let self, !self.closed else { return }
            self.window?.close()
        }
        mpv.onTimeChange = { [weak self] in
            guard let self else { return }
            self.content.controlBar.updateTime(position: self.mpv.timePos, duration: self.mpv.duration,
                                               cache: self.mpv.cacheTime)
        }
        mpv.onStateChange = { [weak self] in self?.refreshState() }
        mpv.onSeek = { [weak self] in self?.mouseActivity(revealOnly: true) }
    }

    private func refreshState() {
        guard let window else { return }
        content.controlBar.updateState(
            paused: mpv.paused, volume: mpv.volume, muted: mpv.muted, speed: mpv.speed, seekStep: SeekStep.value,
            canPrev: mpv.playlistPos > 0, canNext: mpv.playlistPos >= 0 && mpv.playlistPos < mpv.playlistCount - 1,
            floating: window.level == .floating, fullscreen: window.styleMask.contains(.fullScreen))
        speedPanel?.update(speed: mpv.speed)
        if mpv.paused { showControls() } else { scheduleHide() }
    }

    private func setIdle(_ idle: Bool) {
        content.idleView.isHidden = !idle
        content.controlBar.isHidden = idle
        content.titleOverlay.isHidden = idle
        if idle {
            window?.title = "Hush"
            window?.contentResizeIncrements = NSSize(width: 1, height: 1)   // clears the video aspect lock
            restoreIdleSize()
            content.idleView.reloadRecents()
            thumbnailer.load(path: nil)
            showControls()
        }
        refreshState()
    }

    // MARK: Auto-hiding controls

    private func mouseActivity(revealOnly: Bool = false) {
        showControls()
        scheduleHide(after: revealOnly ? 1.2 : 2.0)
    }

    private func showControls() {
        hideTimer?.invalidate()
        guard !controlsShown else { return }
        controlsShown = true
        setControlsAlpha(1)
    }

    private func scheduleHide(after delay: TimeInterval = 2.0) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.hideControlsIfIdle()
        }
    }

    private func hideControlsIfIdle() {
        guard controlsShown, mpv.hasMedia, !mpv.paused, !(speedPopover?.isShown ?? false) else { return }
        if content.mouseOverControls && content.mouseInside {
            scheduleHide()
            return
        }
        controlsShown = false
        setControlsAlpha(0)
        content.bubble.isHidden = true
        if content.mouseInside { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    private func setControlsAlpha(_ alpha: CGFloat) {
        let titlebar = window?.standardWindowButton(.closeButton)?.superview
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = alpha > 0 ? 0.15 : 0.35
            content.controlBar.animator().alphaValue = alpha
            content.titleOverlay.animator().alphaValue = alpha
            titlebar?.animator().alphaValue = alpha
        }
    }

    /// Debug (HUSH_DEBUG snapshot hook): shows the seek preview at a fraction of the duration.
    func debugShowPreview(at fraction: Double) {
        guard mpv.duration > 0 else { return }
        showControls()
        showSeekBubble(mpv.duration * fraction)
    }

    private func showSeekBubble(_ value: Double?) {
        guard let value, mpv.duration > 0 else {
            content.bubble.isHidden = true
            return
        }
        let bar = content.controlBar.seekBar
        let inset = bar.knobDiameter / 2
        let fraction = CGFloat(value / mpv.duration)
        let x = bar.frame.minX + inset + (bar.bounds.width - inset * 2) * fraction
        content.bubble.show(Theme.time(value, hours: mpv.duration >= 3600), centerX: x,
                            bottomY: ControlBar.totalHeight + 2, within: content.bounds.width)
        if content.bubble.previewSize != nil { thumbnailer.request(time: value) }
    }

    // MARK: Opening

    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if ready { mpv.open(urls) } else { pendingURLs.append(contentsOf: urls) }
    }

    @objc func openFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.open(panel.urls) }
        }
    }

    @objc func openURL(_ sender: Any?) {
        guard let window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") { field.stringValue = s }
        let alert = NSAlert()
        alert.messageText = "打开网址"
        alert.informativeText = "任意 http(s) 视频流，或 yt-dlp 支持的网页。"
        alert.accessoryView = field
        alert.addButton(withTitle: "打开")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)),
                  url.scheme != nil else { return }
            self?.open([url])
        }
    }

    @objc func addSubtitle(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.mpv.command(["sub-add", url.path, "select"])
        }
    }

    // MARK: Playback actions

    @objc func togglePause(_ sender: Any?) { mpv.commandString("cycle pause") }
    // Exact seeks: with long keyframe intervals a keyframe seek could jump far past a short step.
    @objc func seekForward(_ sender: Any?) { mpv.command(["seek", String(SeekStep.value), "relative+exact"]) }
    @objc func seekBackward(_ sender: Any?) { mpv.command(["seek", String(-SeekStep.value), "relative+exact"]) }
    @objc func volumeUp(_ sender: Any?) { nudgeVolume(Double(VolumeStep.value)) }
    @objc func volumeDown(_ sender: Any?) { nudgeVolume(-Double(VolumeStep.value)) }

    /// mpv's own volume (not the system volume), clamped to 0–100%.
    private func nudgeVolume(_ delta: Double) {
        let value = min(max(mpv.volume + delta, 0), 100).rounded()
        if delta > 0, mpv.muted { mpv.setFlag("mute", false) }
        mpv.setDouble("volume", value)
        mpv.command(["show-text", "音量 \(Int(value))%" + (delta < 0 && mpv.muted ? "（静音中）" : "")])
        mouseActivity(revealOnly: true)
    }

    private func handleArrowKey(_ code: UInt16) -> Bool {
        guard mpv.hasMedia else { return false }
        switch code {
        case 123: seekBackward(nil)
        case 124: seekForward(nil)
        case 125: volumeDown(nil)
        case 126: volumeUp(nil)
        default: return false
        }
        return true
    }

    @objc func showSeekStepMenu(_ sender: Any?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "← / → 快进快退步长", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let current = SeekStep.value
        for value in SeekStep.presets {
            let item = actionItem(SeekStep.phrase(value), #selector(setSeekStep(_:)))
            item.representedObject = value
            item.state = abs(value - current) < 0.001 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let isPreset = SeekStep.presets.contains { abs($0 - current) < 0.001 }
        let custom = actionItem(isPreset ? "自定义…" : "自定义（\(SeekStep.phrase(current))）…", #selector(customSeekStep(_:)))
        custom.state = isPreset ? .off : .on
        menu.addItem(custom)
        popUp(menu, from: content.controlBar.stepButton)
    }

    @objc func setSeekStep(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { SeekStep.value = value }
    }

    @objc func customSeekStep(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "快进 / 快退步长"
        alert.informativeText = "按 ← / → 或点击快进快退按钮时跳过的秒数（0.5–600）。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = String(format: "%g", SeekStep.value)
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                  let value = Double(field.stringValue.trimmingCharacters(in: .whitespaces)), value > 0 else { return }
            SeekStep.value = value
        }
    }
    @objc func playlistNext(_ sender: Any?) { mpv.commandString("playlist-next") }
    @objc func playlistPrev(_ sender: Any?) { mpv.commandString("playlist-prev") }
    @objc func cycleSubtitle(_ sender: Any?) { mpv.commandString("cycle sub") }
    @objc func toggleSubtitle(_ sender: Any?) { mpv.commandString("cycle sub-visibility") }
    @objc func cycleAudio(_ sender: Any?) { mpv.commandString("cycle audio") }
    @objc func screenshot(_ sender: Any?) { mpv.commandString("osd-msg screenshot") }
    @objc func toggleMute(_ sender: Any?) { mpv.commandString("cycle mute") }

    @objc func selectTrack(_ sender: NSMenuItem) {
        guard let (type, id) = sender.representedObject as? (String, Int64) else { return }
        let property = type == "sub" ? "sid" : "aid"
        mpv.command(["set", property, id < 0 ? "no" : String(id)])
    }

    @objc func setPresetSpeed(_ sender: NSMenuItem) {
        mpv.setSpeed(sender.representedObject as? Double ?? 1.0)
    }
    @objc func speedUp(_ sender: Any?) { mpv.setSpeed(mpv.speed + 0.05) }
    @objc func speedDown(_ sender: Any?) { mpv.setSpeed(mpv.speed - 0.05) }
    @objc func speedReset(_ sender: Any?) { mpv.setSpeed(1.0) }

    @objc func showSpeedPanel(_ sender: Any?) {
        if let speedPopover, speedPopover.isShown {
            speedPopover.performClose(nil)
            return
        }
        let panel = SpeedPanel { [weak self] value in self?.mpv.setSpeed(value) }
        let popover = NSPopover()
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        speedPanel = panel
        speedPopover = popover
        panel.update(speed: mpv.speed)
        let anchor: NSView = mpv.hasMedia ? content.controlBar.speedButton : content
        let rect = mpv.hasMedia ? anchor.bounds : NSRect(x: content.bounds.midX, y: content.bounds.midY, width: 1, height: 1)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }

    @objc func showSubtitleMenu(_ sender: Any?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addTrackItems(to: menu, type: "sub", offTitle: "关闭字幕")
        menu.addItem(.separator())
        menu.addItem(actionItem("加载字幕文件…", #selector(addSubtitle(_:))))
        menu.addItem(actionItem("显示 / 隐藏字幕", #selector(toggleSubtitle(_:))))
        popUp(menu, from: content.controlBar.subtitleButton)
    }

    @objc func showSettingsMenu(_ sender: Any?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let audioItem = NSMenuItem(title: "音轨", action: nil, keyEquivalent: "")
        let audio = NSMenu()
        audio.autoenablesItems = false
        addTrackItems(to: audio, type: "audio", offTitle: nil)
        audioItem.submenu = audio
        menu.addItem(audioItem)
        menu.addItem(.separator())
        menu.addItem(actionItem("截图（保存到桌面）", #selector(screenshot(_:))))
        menu.addItem(actionItem("打开网址…", #selector(openURL(_:))))
        menu.addItem(actionItem("新建窗口", #selector(AppDelegate.newWindow(_:)), target: NSApp.delegate))
        menu.addItem(.separator())
        let excludedItem = NSMenuItem(title: "最近播放黑名单", action: nil, keyEquivalent: "")
        excludedItem.submenu = excludedFoldersMenu()
        menu.addItem(excludedItem)
        menu.addItem(.separator())
        menu.addItem(actionItem("设置与快捷键…", #selector(showShortcuts(_:))))
        popUp(menu, from: content.controlBar.settingsButton)
    }

    /// Folders whose videos never show up in the recent lists.
    private func excludedFoldersMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "这些文件夹里的视频不会出现在最近播放", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let folders = RecentFiles.excludedFolders
        if folders.isEmpty {
            let none = NSMenuItem(title: "（空）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for folder in folders {
            let item = NSMenuItem(title: (folder as NSString).abbreviatingWithTildeInPath, action: nil, keyEquivalent: "")
            item.image = NSWorkspace.shared.icon(forFile: folder)
            item.image?.size = NSSize(width: 16, height: 16)
            let sub = NSMenu()
            sub.autoenablesItems = false
            let reveal = actionItem("在 Finder 中显示", #selector(revealExcludedFolder(_:)))
            reveal.representedObject = folder
            sub.addItem(reveal)
            let remove = actionItem("移出黑名单", #selector(removeExcludedFolder(_:)))
            remove.representedObject = folder
            sub.addItem(remove)
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if let url = window?.representedURL, !RecentFiles.isExcluded(url.path) {
            let current = actionItem("加入当前视频所在的文件夹", #selector(excludeCurrentFolder(_:)))
            current.toolTip = url.deletingLastPathComponent().path
            menu.addItem(current)
        }
        menu.addItem(actionItem("添加文件夹…", #selector(addExcludedFolder(_:))))
        return menu
    }

    @objc func excludeCurrentFolder(_ sender: Any?) {
        guard let url = window?.representedURL else { return }
        RecentFiles.exclude(folder: url.deletingLastPathComponent())
    }

    @objc func addExcludedFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "加入黑名单"
        panel.message = "选中的文件夹（含子文件夹）里的视频不会出现在最近播放"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            panel.urls.forEach { RecentFiles.exclude(folder: $0) }
        }
    }

    @objc func revealExcludedFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @objc func removeExcludedFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        RecentFiles.unexclude(folder: path)
    }

    private func addTrackItems(to menu: NSMenu, type: String, offTitle: String?) {
        let tracks = mpv.tracks.filter { $0.type == type }
        if let offTitle {
            let off = actionItem(offTitle, #selector(selectTrack(_:)))
            off.representedObject = (type, Int64(-1))
            off.state = tracks.contains { $0.selected } ? .off : .on
            menu.addItem(off)
        }
        if tracks.isEmpty {
            let none = NSMenuItem(title: type == "sub" ? "没有字幕轨" : "没有音轨", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for track in tracks {
            let item = actionItem(track.displayName, #selector(selectTrack(_:)))
            item.representedObject = (type, track.id)
            item.state = track.selected ? .on : .off
            menu.addItem(item)
        }
    }

    private func actionItem(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        return item
    }

    private func popUp(_ menu: NSMenu, from button: NSView) {
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
    }

    @objc func customSpeed(_ sender: Any?) { showSpeedPanel(sender) }

    @objc func toggleFloatOnTop(_ sender: Any?) {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
        refreshState()
    }

    @objc func toggleFullScreenAction(_ sender: Any?) { window?.toggleFullScreen(nil) }

    @objc func showShortcuts(_ sender: Any?) { SettingsWindowController.shared.show() }

    // MARK: Menu state

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setPresetSpeed(_:)), let value = item.representedObject as? Double {
            item.state = abs(mpv.speed - value) < 0.001 ? .on : .off
        } else if item.action == #selector(customSpeed(_:)) {
            let isPreset = AppDelegate.speedPresets.contains { abs($0 - mpv.speed) < 0.001 }
            item.title = isPreset ? "自定义…" : "自定义（\(Theme.speed(mpv.speed))）…"
            item.state = isPreset ? .off : .on
        } else if item.action == #selector(volumeUp(_:)) {
            item.title = "音量 +\(VolumeStep.value)%"
        } else if item.action == #selector(volumeDown(_:)) {
            item.title = "音量 −\(VolumeStep.value)%"
        } else if item.action == #selector(seekForward(_:)) {
            item.title = "快进 \(SeekStep.phrase(SeekStep.value))"
        } else if item.action == #selector(seekBackward(_:)) {
            item.title = "快退 \(SeekStep.phrase(SeekStep.value))"
        } else if item.action == #selector(toggleFloatOnTop(_:)) {
            item.state = window?.level == .floating ? .on : .off
        }
        return true
    }

    // MARK: Window

    private func fitWindow(to videoSize: NSSize) {
        guard let window, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let scale = screen.backingScaleFactor
        // Native pixel size in points, capped to 80% of the visible screen.
        var size = NSSize(width: videoSize.width / scale, height: videoSize.height / scale)
        if size.width < 640 { size = NSSize(width: 640, height: 640 * videoSize.height / videoSize.width) }
        let k = min(1, visible.width * 0.8 / size.width, visible.height * 0.8 / size.height)
        size = NSSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())

        let old = window.frame
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        var origin = NSPoint(x: old.midX - frameSize.width / 2, y: old.midY - frameSize.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - frameSize.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - frameSize.height)
        window.contentAspectRatio = videoSize
        window.setFrame(NSRect(origin: origin, size: frameSize), display: true, animate: true)
    }

    /// Grows a window that was sized for a small video back to the idle layout's size.
    private func restoreIdleSize() {
        guard let window, window.isVisible, !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let old = window.frame
        guard old.width < 900 || old.height < 560 else { return }
        let size = NSSize(width: min(max(old.width, 960), visible.width), height: min(max(old.height, 600), visible.height))
        var origin = NSPoint(x: old.midX - size.width / 2, y: old.midY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        mpv.setFlag("fullscreen", true)
        content.titleOverlay.isHidden = true
        refreshState()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        mpv.setFlag("fullscreen", false)
        content.titleOverlay.isHidden = !mpv.hasMedia
        refreshState()
    }

    func windowWillClose(_ notification: Notification) { shutdown() }

    /// Stops playback (writing the resume point) and releases mpv. Safe to call twice.
    func shutdown() {
        guard !closed else { return }
        closed = true
        hideTimer?.invalidate()
        speedPopover?.close()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        if let seekStepObserver { NotificationCenter.default.removeObserver(seekStepObserver) }
        content.videoView.videoLayer.teardown()
        thumbnailer.destroy()
        mpv.destroy()
        onClose?(self)
    }
}
