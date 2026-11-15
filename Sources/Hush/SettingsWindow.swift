import AppKit

/// The settings window (⌘,): keyboard and mouse shortcuts grouped by topic. The ← / → seek
/// step and the ↑ / ↓ volume step are adjustable; everything else is listed for reference.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let seekControl = NSSegmentedControl()
    private let volumeSlider = NSSlider(value: 10, minValue: Double(VolumeStep.range.lowerBound),
                                        maxValue: Double(VolumeStep.range.upperBound), target: nil, action: nil)
    private let volumeLabel = NSTextField(labelWithString: "")
    private var observers: [NSObjectProtocol] = []

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "设置"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 580, height: 360)
        window.maxSize = NSSize(width: 580, height: 4000)
        super.init(window: window)
        buildContent()
        for name in [SeekStep.changed, VolumeStep.changed] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        refresh()
        window.center()
        window.setFrameAutosaveName("HushSettings")
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh() {
        let step = SeekStep.value
        seekControl.selectedSegment = SeekStep.presets.firstIndex { abs($0 - step) < 0.001 } ?? -1
        volumeSlider.integerValue = VolumeStep.value
        volumeLabel.stringValue = "\(VolumeStep.value)%"
    }

    @objc private func seekChanged(_ sender: NSSegmentedControl) {
        guard SeekStep.presets.indices.contains(sender.selectedSegment) else { return }
        SeekStep.value = SeekStep.presets[sender.selectedSegment]
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        let value = Int(sender.doubleValue.rounded())
        volumeLabel.stringValue = "\(value)%"
        if value != VolumeStep.value { VolumeStep.value = value }
    }

    @objc private func resetDefaults(_ sender: Any?) {
        SeekStep.value = 5
        VolumeStep.value = 10
    }

    // MARK: Layout

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "快捷键")
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        heading.textColor = Theme.text
        stack.addArrangedSubview(heading)
        let sub = NSTextField(labelWithString: "← / → 和 ↑ / ↓ 的幅度可以调整，对所有窗口生效；其余为固定按键。")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = Theme.textDim
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(16, after: sub)

        seekControl.segmentCount = SeekStep.presets.count
        for (i, value) in SeekStep.presets.enumerated() {
            seekControl.setLabel(SeekStep.number(value), forSegment: i)
            seekControl.setWidth(36, forSegment: i)
        }
        seekControl.trackingMode = .selectOne
        seekControl.selectedSegmentBezelColor = Theme.accent
        seekControl.target = self
        seekControl.action = #selector(seekChanged(_:))
        let seekUnit = dimLabel("秒")

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.isContinuous = true
        volumeSlider.numberOfTickMarks = 0
        if #available(macOS 14.0, *) { volumeSlider.trackFillColor = Theme.accent }
        volumeSlider.widthAnchor.constraint(equalToConstant: 170).isActive = true
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        volumeLabel.textColor = Theme.accent
        volumeLabel.alignment = .right
        volumeLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        addSection(to: stack, "播放", [
            row(["空格"], "播放 / 暂停"),
            row(["单击画面"], "播放 / 暂停", mouse: true),
            row(["←", "→"], "快退 / 快进", control: hstack([seekControl, seekUnit], spacing: 6)),
            row(["滚轮左右"], "快退 / 快进 5 秒", mouse: true),
            row(["<", ">"], "播放列表上一个 / 下一个"),
        ])
        addSection(to: stack, "音量", [
            row(["↑", "↓"], "音量增减", control: hstack([volumeSlider, volumeLabel], spacing: 8)),
            row(["滚轮上下"], "音量 ± 2%", mouse: true),
            row(["m"], "静音 / 取消静音"),
        ])
        addSection(to: stack, "倍速", [
            row(["[", "]"], "倍速 − / + 0.05"),
            row(["{", "}"], "倍速 − / + 0.25"),
            row(["Backspace"], "倍速恢复 1.0x"),
        ])
        addSection(to: stack, "画面与窗口", [
            row(["双击画面"], "全屏 / 退出全屏", mouse: true),
            row(["f"], "全屏 / 退出全屏"),
            row(["Esc"], "退出全屏"),
            row(["拖动画面"], "移动窗口", mouse: true),
            row(["s"], "截图（保存到桌面）"),
            row(["⌘N"], "新建窗口（也可以在 Dock 图标上右键）"),
            row(["q"], "关闭当前窗口，并记住播放位置"),
        ])
        addSection(to: stack, "字幕与音轨", [
            row(["j"], "切换字幕轨"),
            row(["v"], "显示 / 隐藏字幕"),
            row(["#"], "切换音轨"),
        ])

        let reset = NSButton(title: "恢复默认（5 秒 / 10%）", target: self, action: #selector(resetDefaults(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .regular
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        let resetRow = hstack([NSView(), reset], spacing: 0)
        stack.addArrangedSubview(resetRow)

        fillWidth(stack)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        window?.contentView = scroll
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        // Open tall enough to show everything when the screen allows it.
        document.layoutSubtreeIfNeeded()
        let wanted = stack.fittingSize.height
        let screenH = (NSScreen.main?.visibleFrame.height ?? 800) - 60
        window?.setContentSize(NSSize(width: 580, height: min(wanted, screenH)))
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
    }

    /// Stretches every arranged subview of a vertical stack to the stack's inner width, so
    /// cards and rows line up instead of sizing to their content.
    private func fillWidth(_ stack: NSStackView) {
        let inset = stack.edgeInsets.left + stack.edgeInsets.right
        for view in stack.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
        }
    }

    private func addSection(to stack: NSStackView, _ title: String, _ rows: [NSView]) {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = Theme.textDim
        stack.addArrangedSubview(header)

        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 0
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderColor = NSColor(white: 1, alpha: 0.07).cgColor
        card.layer?.borderWidth = 1
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .custom
                line.borderWidth = 0
                line.fillColor = NSColor(white: 1, alpha: 0.07)
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                card.addArrangedSubview(line)
            }
            card.addArrangedSubview(row)
        }
        stack.addArrangedSubview(card)
        stack.setCustomSpacing(18, after: card)
        fillWidth(card)
    }

    private func row(_ keys: [String], _ text: String, mouse: Bool = false, control: NSView? = nil) -> NSView {
        let caps = hstack(keys.map { KeyCap($0, mouse: mouse) }, spacing: 5)
        let keysBox = NSView()
        keysBox.translatesAutoresizingMaskIntoConstraints = false
        keysBox.addSubview(caps)
        NSLayoutConstraint.activate([
            keysBox.widthAnchor.constraint(equalToConstant: 128),
            caps.leadingAnchor.constraint(equalTo: keysBox.leadingAnchor),
            caps.centerYAnchor.constraint(equalTo: keysBox.centerYAnchor),
            keysBox.heightAnchor.constraint(greaterThanOrEqualTo: caps.heightAnchor),
        ])
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.text
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail

        var views: [NSView] = [keysBox, label]
        if let control {
            // A spacer that gives way first keeps every control flush with the right edge.
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            views += [spacer, control]
        }
        let row = hstack(views, spacing: 12)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        row.heightAnchor.constraint(equalToConstant: control == nil ? 36 : 46).isActive = true
        return row
    }

    private func hstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func dimLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.textDim
        return label
    }
}

/// A key drawn as a keycap; mouse gestures get a mouse glyph instead of a border.
final class KeyCap: NSView {
    init(_ text: String, mouse: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        addSubview(label)
        if mouse {
            let icon = NSImageView(image: Theme.symbol("computermouse", size: 11, weight: .regular) ?? NSImage())
            icon.contentTintColor = Theme.textDim
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = Theme.textDim
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(equalToConstant: 22),
            ])
        } else {
            wantsLayer = true
            layer?.cornerRadius = 5
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
            layer?.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
            layer?.borderWidth = 1
            label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            label.textColor = Theme.text
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(equalToConstant: 22),
                widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }
}
