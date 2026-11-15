import AppKit

/// Routes "Open Recent" (menu + Dock) to a player window instead of NSDocument machinery.
final class HushDocumentController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        (NSApp.delegate as? AppDelegate)?.openRecent(url)
        completionHandler(nil, false, nil)
    }
}

/// App-level glue: owns the player windows, the menus and the Dock menu.
/// Each window is an independent player, so several videos can play side by side.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var players: [PlayerWindowController] = []
    private var launchURLs: [URL] = []
    private var launched = false
    private let ipcBase = ProcessInfo.processInfo.environment["HUSH_IPC"]
    private var windowCount = 0

    static let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.1, 1.2, 1.25, 1.3, 1.5, 1.75, 2.0, 2.5, 3.0]

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = HushDocumentController() // first instance becomes NSDocumentController.shared
        NSApp.mainMenu = buildMainMenu()

        // `Hush file.mkv` from a shell (Finder opens arrive via application(_:open:)).
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            if arg.contains("://"), let url = URL(string: arg) {
                launchURLs.append(url)
            } else if FileManager.default.fileExists(atPath: arg) {
                launchURLs.append(URL(fileURLWithPath: arg))
            }
        }
    }

    private var snapshotSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        installSnapshotHook()
        newPlayer().open(launchURLs)
        launchURLs = []
        NSApp.activate(ignoringOtherApps: true)
        // Debug: open the settings window at launch (for screenshots).
        if ProcessInfo.processInfo.environment["HUSH_SHOW_SETTINGS"] != nil { showSettings(nil) }
    }

    // MARK: Windows

    @discardableResult
    func newPlayer() -> PlayerWindowController {
        // Debug: HUSH_IPC=<sock> gives window 1 that socket and window N "<sock>.N".
        windowCount += 1
        let ipc = ipcBase.map { windowCount == 1 ? $0 : "\($0).\(windowCount)" }
        let player = PlayerWindowController(ipcSocket: ipc)
        if let window = player.window {
            if let reference = players.last?.window {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: reference.frame.minX,
                                                                                 y: reference.frame.maxY)))
            } else {
                window.center()
                window.setFrameAutosaveName("HushMainWindow")
            }
        }
        player.onClose = { [weak self] closed in self?.players.removeAll { $0 === closed } }
        players.append(player)
        player.start()
        return player
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc func newWindow(_ sender: Any?) {
        newPlayer()
        NSApp.activate(ignoringOtherApps: true)
    }

    private var keyPlayer: PlayerWindowController? {
        (NSApp.keyWindow?.windowController ?? NSApp.mainWindow?.windowController) as? PlayerWindowController
    }

    /// Finder / Dock opens: use an empty window if there is one, otherwise open a new window
    /// so whatever is already playing keeps playing.
    private func playerForExternalOpen() -> PlayerWindowController {
        if let key = keyPlayer, key.isIdle { return key }
        if let idle = players.first(where: { $0.isIdle }) { return idle }
        return newPlayer()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            launchURLs.append(contentsOf: urls)
            return
        }
        let player = playerForExternalOpen()
        player.open(urls)
        player.showWindow(nil)
    }

    /// "Open Recent" is a menu command, so it replaces the current window's video.
    func openRecent(_ url: URL) {
        (keyPlayer ?? playerForExternalOpen()).open([url])
    }

    /// Only reached when no player window is key (otherwise the window's openFile handles it).
    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.playerForExternalOpen().open(panel.urls)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }

    // MARK: Open Recent menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = RecentFiles.all.filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "清除菜单", action: #selector(clearRecents(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func openRecentItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openRecent(url) }
    }

    @objc private func clearRecents(_ sender: Any?) { RecentFiles.clear() }

    /// Debug: with HUSH_DEBUG=1, `kill -USR1 <pid>` renders each window's UI layers to
    /// /tmp/hush-snap-N.png (video and blur are not captured). Works while the screen is locked.
    private func installSnapshotHook() {
        guard ProcessInfo.processInfo.environment["HUSH_DEBUG"] != nil else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            // Pop up the seek preview at 30% first, then snapshot once the frame has arrived.
            self?.players.forEach { $0.debugShowPreview(at: 0.3) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.writeSnapshots() }
        }
        source.resume()
        snapshotSource = source

        // `kill -USR2 <pid>`: synthesize clicks on the first window's picture; the click count
        // (1 or 2) and the gap in ms between presses come from /tmp/hush-click ("2 120").
        signal(SIGUSR2, SIG_IGN)
        let clicks = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        clicks.setEventHandler { [weak self] in
            let spec = (try? String(contentsOfFile: "/tmp/hush-click", encoding: .utf8)) ?? "1"
            let parts = spec.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Double($0) }
            let count = Int(parts.first ?? 1), gap = (parts.count > 1 ? parts[1] : 100) / 1000
            guard let window = self?.players.first?.window, let view = window.contentView,
                  let video = view.subviews.first(where: { $0 is VideoView }) else { return }
            let point = NSPoint(x: view.bounds.midX, y: view.bounds.height * 0.6)
            for i in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(i)) {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: i + 1, pressure: 1)
                        // Straight to the video view: NSWindow drops synthesized repeat clicks.
                        guard let event else { continue }
                        if type == .leftMouseDown { video.mouseDown(with: event) } else { video.mouseUp(with: event) }
                    }
                }
            }
        }
        clicks.resume()
        clickSource = clicks
    }

    private var clickSource: DispatchSourceSignal?

    private func writeSnapshots() {
        do {
            for (i, player) in players.enumerated() {
                guard let view = player.window?.contentView, let layer = view.layer else { continue }
                let scale = player.window?.backingScaleFactor ?? 2
                let size = view.bounds.size
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { continue }
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/hush-snap-\(i + 1).png"))
                if player.mpv.duration > 0 {
                    player.thumbnailer.debugDump(fractions: [0.1, 0.5, 0.9, 0.5], duration: player.mpv.duration,
                                                 prefix: "/tmp/hush-thumb-\(i + 1)")
                }
            }
            // The speed popover lives in its own window; render a standalone copy of it.
            let panel = SpeedPanel { _ in }
            panel.update(speed: 1.25)
            let view = panel.view
            view.appearance = NSAppearance(named: .darkAqua)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/hush-snap-speed.png"))
            }
        }
    }

    // MARK: Dock

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "新建窗口", action: #selector(newWindow(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let player = players.first { player.showWindow(nil) } else { newPlayer() }
        }
        return true
    }

    // Keep running with no windows so the Dock icon / menu can open a new one.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        for player in players { player.shutdown() }
    }
}
