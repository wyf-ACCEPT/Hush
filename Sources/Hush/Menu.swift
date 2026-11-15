import AppKit

extension AppDelegate {
    /// Player commands use a nil target, so they go to the key window's PlayerWindowController
    /// through the responder chain.
    func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        // App
        let app = submenu(main, "Hush")
        app.addItem(withTitle: "关于 Hush", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 Hush", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "退出 Hush", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let file = submenu(main, "文件")
        let newWin = item("新建窗口", #selector(newWindow(_:)), "n")
        newWin.target = self
        file.addItem(newWin)
        file.addItem(item("打开…", #selector(PlayerWindowController.openFile(_:)), "o"))
        file.addItem(item("打开网址…", #selector(PlayerWindowController.openURL(_:)), "o", [.command, .shift]))
        let recentItem = NSMenuItem(title: "最近打开", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "最近打开")
        recent.delegate = self   // rebuilt from RecentFiles each time it opens
        recentItem.submenu = recent
        file.addItem(recentItem)
        file.addItem(.separator())
        file.addItem(item("加载字幕文件…", #selector(PlayerWindowController.addSubtitle(_:)), "o", [.command, .option]))
        file.addItem(.separator())
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Edit (needed for copy / paste in the URL and speed fields)
        let edit = submenu(main, "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Playback
        typealias P = PlayerWindowController
        let playback = submenu(main, "播放")
        playback.addItem(item("播放 / 暂停", #selector(P.togglePause(_:)), "p"))
        playback.addItem(item("快进 10 秒", #selector(P.seekForward(_:)), arrow(NSRightArrowFunctionKey)))
        playback.addItem(item("快退 10 秒", #selector(P.seekBackward(_:)), arrow(NSLeftArrowFunctionKey)))
        playback.addItem(.separator())
        playback.addItem(item("下一个", #selector(P.playlistNext(_:)), arrow(NSRightArrowFunctionKey), [.command, .shift]))
        playback.addItem(item("上一个", #selector(P.playlistPrev(_:)), arrow(NSLeftArrowFunctionKey), [.command, .shift]))
        playback.addItem(.separator())

        let speedItem = NSMenuItem(title: "倍速", action: nil, keyEquivalent: "")
        let speed = NSMenu(title: "倍速")
        for value in Self.speedPresets {
            let entry = item(Theme.speed(value), #selector(P.setPresetSpeed(_:)), "")
            entry.representedObject = value
            speed.addItem(entry)
        }
        speed.addItem(item("自定义…", #selector(P.customSpeed(_:)), ""))
        speed.addItem(.separator())
        speed.addItem(item("加快 0.05", #selector(P.speedUp(_:)), "]"))
        speed.addItem(item("减慢 0.05", #selector(P.speedDown(_:)), "["))
        speed.addItem(item("恢复 1.0x", #selector(P.speedReset(_:)), "0"))
        speedItem.submenu = speed
        playback.addItem(speedItem)
        playback.addItem(.separator())
        playback.addItem(item("音量 +10%", #selector(P.volumeUp(_:)), arrow(NSUpArrowFunctionKey)))
        playback.addItem(item("音量 −10%", #selector(P.volumeDown(_:)), arrow(NSDownArrowFunctionKey)))
        playback.addItem(item("静音", #selector(P.toggleMute(_:)), "m", [.command, .option]))

        // Subtitles & audio
        let subs = submenu(main, "字幕")
        subs.addItem(item("加载字幕文件…", #selector(P.addSubtitle(_:)), ""))
        subs.addItem(item("切换字幕轨", #selector(P.cycleSubtitle(_:)), "j"))
        subs.addItem(item("显示 / 隐藏字幕", #selector(P.toggleSubtitle(_:)), "j", [.command, .shift]))
        subs.addItem(.separator())
        subs.addItem(item("切换音轨", #selector(P.cycleAudio(_:)), "a", [.command, .shift]))

        // Window
        let win = submenu(main, "窗口")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(item("窗口置顶", #selector(P.toggleFloatOnTop(_:)), "t", [.command, .option]))
        let fs = win.addItem(withTitle: "全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        win.addItem(.separator())
        win.addItem(item("截图", #selector(P.screenshot(_:)), "s", [.command, .shift]))
        win.addItem(.separator())
        NSApp.windowsMenu = win

        // Help
        let help = submenu(main, "帮助")
        let shortcuts = NSMenuItem(title: "键盘快捷键", action: #selector(showSettings(_:)), keyEquivalent: "/")
        shortcuts.target = self
        help.addItem(shortcuts)
        NSApp.helpMenu = help

        return main
    }

    private func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        holder.submenu = menu
        parent.addItem(holder)
        return menu
    }

    /// nil target: dispatched through the responder chain to the key player window.
    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = mods
        return entry
    }

    private func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key))!))
    }
}
