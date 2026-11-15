import AppKit

/// Colors, symbols and formatting shared by the player UI (orange accent on dark glass).
enum Theme {
    static let accent = NSColor(srgbRed: 1.0, green: 0.56, blue: 0.12, alpha: 1)
    static let accentHover = NSColor(srgbRed: 1.0, green: 0.68, blue: 0.30, alpha: 1)
    static let icon = NSColor(white: 1, alpha: 0.88)
    static let iconDisabled = NSColor(white: 1, alpha: 0.28)
    static let track = NSColor(white: 1, alpha: 0.24)
    static let buffered = NSColor(white: 1, alpha: 0.38)
    static let text = NSColor(white: 1, alpha: 0.92)
    static let textDim = NSColor(white: 1, alpha: 0.55)
    static let strip = NSColor(white: 0.12, alpha: 1)
    static let card = NSColor(white: 0.19, alpha: 1)
    static let chip = NSColor(white: 1, alpha: 0.09)

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    static func time(_ seconds: Double, hours: Bool = false) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return hours || h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// 1 -> "1.0x", 1.25 -> "1.25x", 1.5 -> "1.5x".
    static func speed(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s += "0" }
        return s + "x"
    }
}

/// Borderless SF Symbol (or short text) button: white, orange on hover or when active.
final class IconButton: NSButton {
    var symbolName: String { didSet { refresh() } }
    var text: String? { didSet { refresh() } }
    var isActive = false { didSet { refresh() } }
    var highlightText = false { didSet { refresh() } }   // text drawn in accent even without hover
    private let pointSize: CGFloat
    private var hovering = false { didSet { refresh() } }
    private var hoverArea: NSTrackingArea?

    override var isEnabled: Bool { didSet { refresh() } }

    init(_ symbol: String, size: CGFloat = 15, tip: String, target: AnyObject?, action: Selector?) {
        symbolName = symbol
        pointSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        isBordered = false
        setButtonType(.momentaryChange)
        imageScaling = .scaleNone
        refusesFirstResponder = true
        focusRingType = .none
        toolTip = tip
        self.target = target
        self.action = action
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private func refresh() {
        let color: NSColor = !isEnabled ? Theme.iconDisabled
            : hovering ? Theme.accentHover
            : (isActive || highlightText) ? Theme.accent : Theme.icon
        if let text {
            imagePosition = .noImage
            image = nil
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .paragraphStyle: style,
            ])
        } else {
            imagePosition = .imageOnly
            title = ""
            image = Theme.symbol(symbolName, size: pointSize)
            contentTintColor = color
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Thin rounded track with an orange fill and a white knob; used for seeking, volume and speed.
class TrackSlider: NSView {
    var minValue = 0.0
    var maxValue = 1.0
    var value = 0.0 { didSet { needsDisplay = true } }
    /// Optional lighter fill behind the main one (buffered range on the seek bar).
    var secondaryValue: Double? { didSet { needsDisplay = true } }
    var trackHeight: CGFloat = 3
    var activeTrackHeight: CGFloat = 5
    var knobDiameter: CGFloat = 12
    var isEnabled = true { didSet { needsDisplay = true } }
    /// Called while dragging (final == false) and on release (final == true).
    var onChange: ((_ value: Double, _ final: Bool) -> Void)?
    /// Value under the cursor while hovering, nil when the cursor leaves.
    var onHover: ((Double?) -> Void)?

    private(set) var dragging = false
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func fraction(of v: Double) -> CGFloat {
        guard maxValue > minValue else { return 0 }
        return CGFloat((min(max(v, minValue), maxValue) - minValue) / (maxValue - minValue))
    }

    private var trackRect: NSRect {
        let h = (hovering || dragging) && isEnabled ? activeTrackHeight : trackHeight
        let inset = knobDiameter / 2
        return NSRect(x: inset, y: ((bounds.height - h) / 2).rounded(), width: max(bounds.width - inset * 2, 1), height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = trackRect
        let r = t.height / 2
        Theme.track.setFill()
        NSBezierPath(roundedRect: t, xRadius: r, yRadius: r).fill()
        guard isEnabled else { return }

        if let secondaryValue {
            var b = t
            b.size.width = t.width * fraction(of: secondaryValue)
            Theme.buffered.setFill()
            NSBezierPath(roundedRect: b, xRadius: r, yRadius: r).fill()
        }
        var fill = t
        fill.size.width = t.width * fraction(of: value)
        Theme.accent.setFill()
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()

        let d = (hovering || dragging) ? knobDiameter + 2 : knobDiameter
        let knob = NSRect(x: t.minX + t.width * fraction(of: value) - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func value(at event: NSEvent) -> Double {
        let p = convert(event.locationInWindow, from: nil)
        let t = trackRect
        let f = Double(min(max((p.x - t.minX) / t.width, 0), 1))
        return minValue + f * (maxValue - minValue)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        dragging = true
        value = value(at: event)
        onChange?(value, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, dragging else { return }
        value = value(at: event)
        onChange?(value, false)
        onHover?(value)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, dragging else { return }
        dragging = false
        value = value(at: event)
        onChange?(value, true)
        if !hovering { onHover?(nil) }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        // Let scrolling over a slider reach the video view (volume / seek gestures).
        nextResponder?.scrollWheel(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if isEnabled { onHover?(value(at: event)) }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        if !dragging { onHover?(nil) }
    }
}

/// Rounded pill button used for speed presets; filled orange when selected.
final class ChipButton: NSButton {
    var isSelected = false { didSet { refresh() } }
    private var hovering = false { didSet { refresh() } }
    private var hoverArea: NSTrackingArea?

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 56, height: 26))
        self.title = title
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 7
        self.target = target
        self.action = action
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private func refresh() {
        layer?.backgroundColor = (isSelected ? Theme.accent
            : hovering ? NSColor(white: 1, alpha: 0.16) : Theme.chip).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: isSelected ? NSColor.black : Theme.text,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: isSelected ? .bold : .medium),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// Recently played local files, newest first (our own list: the system recent-documents
/// list ignores apps that don't use NSDocument). Files inside excluded folders are never
/// recorded or shown.
enum RecentFiles {
    private static let key = "recentFiles"
    private static let excludedKey = "recentExcludedFolders"
    private static let limit = 20
    /// Posted when the list or the excluded folders change.
    static let changed = Notification.Name("HushRecentFilesChanged")

    static var all: [URL] {
        stored.filter { !isExcluded($0) }.map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        guard url.isFileURL, !isExcluded(url.path) else { return }
        var paths = stored
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static var stored: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    // MARK: Excluded folders

    static var excludedFolders: [String] { UserDefaults.standard.stringArray(forKey: excludedKey) ?? [] }

    /// Adds a folder and drops any already-recorded files inside it.
    static func exclude(folder: URL) {
        let path = normalized(folder.path)
        var folders = excludedFolders
        guard !folders.contains(where: { normalized($0) == path }) else { return }
        folders.append(path)
        UserDefaults.standard.set(folders, forKey: excludedKey)
        UserDefaults.standard.set(stored.filter { !isExcluded($0) }, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func unexclude(folder path: String) {
        UserDefaults.standard.set(excludedFolders.filter { $0 != path }, forKey: excludedKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func isExcluded(_ path: String) -> Bool {
        let file = normalized(path)
        return excludedFolders.contains { folder in
            let f = normalized(folder)
            return file == f || file.hasPrefix(f.hasSuffix("/") ? f : f + "/")
        }
    }

    /// Absolute, symlink-free, lowercased (APFS volumes are case-insensitive by default).
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }
}

/// Seek step for ← / → and the rewind / forward buttons; one setting shared by all windows.
enum SeekStep {
    static let presets: [Double] = [1, 3, 5, 10, 15, 30, 60]
    static let changed = Notification.Name("HushSeekStepChanged")
    private static let key = "seekStep"

    static var value: Double {
        get {
            let v = UserDefaults.standard.double(forKey: key)
            return v > 0 ? v : 5
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0.5), 600), forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }

    /// Short form for the control bar: "5s".
    static func label(_ v: Double) -> String { number(v) + "s" }
    /// Long form for menus and tooltips: "5 秒".
    static func phrase(_ v: Double) -> String { number(v) + " 秒" }
}

/// Volume step for ↑ / ↓ in percentage points (1–30, default 10); shared by all windows.
enum VolumeStep {
    static let range = 1...30
    static let changed = Notification.Name("HushVolumeStepChanged")
    private static let key = "volumeStep"

    static var value: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: key)
            return range.contains(v) ? v : 10
        }
        set {
            UserDefaults.standard.set(min(max(newValue, range.lowerBound), range.upperBound), forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}
