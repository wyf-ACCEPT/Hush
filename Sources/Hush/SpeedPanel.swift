import AppKit

/// Popover content for playback speed: big readout, slider, presets and fine steps.
final class SpeedPanel: NSViewController, NSTextFieldDelegate {
    static let presets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0]
    static let range = 0.25...4.0

    private let setSpeed: (Double) -> Void
    private let readout = NSTextField(labelWithString: "1.0x")
    private let slider = TrackSlider()
    private let field = NSTextField()
    private var chips: [ChipButton] = []

    init(setSpeed: @escaping (Double) -> Void) {
        self.setSpeed = setSpeed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let w: CGFloat = 292, h: CGFloat = 214
        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let title = NSTextField(labelWithString: "播放速度")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text
        title.frame = NSRect(x: 16, y: h - 34, width: 120, height: 18)
        root.addSubview(title)

        readout.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        readout.textColor = Theme.accent
        readout.alignment = .right
        readout.frame = NSRect(x: w - 136, y: h - 40, width: 120, height: 28)
        root.addSubview(readout)

        slider.minValue = Self.range.lowerBound
        slider.maxValue = Self.range.upperBound
        slider.trackHeight = 4
        slider.activeTrackHeight = 5
        slider.knobDiameter = 14
        slider.frame = NSRect(x: 10, y: h - 72, width: w - 20, height: 22)
        slider.onChange = { [weak self] value, _ in
            // Snap to 0.05 steps so the readout stays tidy.
            self?.apply((value * 20).rounded() / 20)
        }
        root.addSubview(slider)

        for (text, x, align) in [("0.25x", 16.0, NSTextAlignment.left), ("4.0x", w - 76, .right)] {
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = Theme.textDim
            label.alignment = align
            label.frame = NSRect(x: x, y: h - 88, width: 60, height: 13)
            root.addSubview(label)
        }

        // 4 x 2 preset grid.
        let cols = 4, chipW: CGFloat = 60, chipH: CGFloat = 26, gap: CGFloat = 8
        let gridX = (w - CGFloat(cols) * chipW - CGFloat(cols - 1) * gap) / 2
        for (i, value) in Self.presets.enumerated() {
            let chip = ChipButton(title: Theme.speed(value), target: self, action: #selector(presetClicked(_:)))
            chip.tag = i
            let row = i / cols, col = i % cols
            chip.frame = NSRect(x: gridX + CGFloat(col) * (chipW + gap), y: h - 126 - CGFloat(row) * (chipH + gap),
                                width: chipW, height: chipH)
            root.addSubview(chip)
            chips.append(chip)
        }

        // Fine control: -0.05 [ value ] +0.05
        let rowY: CGFloat = 14
        let minus = IconButton("minus", size: 13, tip: "减慢 0.05（[）", target: self, action: #selector(stepDown(_:)))
        minus.frame = NSRect(x: gridX, y: rowY, width: 34, height: 26)
        styleStepper(minus)
        root.addSubview(minus)

        field.frame = NSRect(x: (w - 96) / 2, y: rowY + 1, width: 96, height: 24)
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.placeholderString = "自定义"
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.toolTip = "输入任意倍速（0.1–8），回车确认"
        root.addSubview(field)

        let plus = IconButton("plus", size: 13, tip: "加快 0.05（]）", target: self, action: #selector(stepUp(_:)))
        plus.frame = NSRect(x: w - gridX - 34, y: rowY, width: 34, height: 26)
        styleStepper(plus)
        root.addSubview(plus)

        view = root
    }

    private func styleStepper(_ button: NSButton) {
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = Theme.chip.cgColor
    }

    /// Refreshes the panel from mpv's current speed.
    func update(speed: Double) {
        _ = view
        readout.stringValue = Theme.speed(speed)
        if !slider.dragging { slider.value = speed }
        if field.currentEditor() == nil { field.stringValue = String(format: "%.2f", speed) }
        for (i, chip) in chips.enumerated() { chip.isSelected = abs(Self.presets[i] - speed) < 0.001 }
    }

    private func apply(_ value: Double) {
        setSpeed(min(max(value, 0.1), 8.0))
    }

    @objc private func presetClicked(_ sender: ChipButton) { apply(Self.presets[sender.tag]) }
    @objc private func stepDown(_ sender: Any?) { apply(currentValue() - 0.05) }
    @objc private func stepUp(_ sender: Any?) { apply(currentValue() + 0.05) }

    private func currentValue() -> Double {
        Double(readout.stringValue.replacingOccurrences(of: "x", with: "")) ?? 1
    }

    @objc private func fieldCommitted(_ sender: NSTextField) {
        let text = sender.stringValue.replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces)
        if let value = Double(text) { apply(value) }
        view.window?.makeFirstResponder(nil)
    }
}
