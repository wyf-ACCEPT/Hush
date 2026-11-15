import AppKit
import QuickLookThumbnailing

/// Shown when nothing is loaded: a dashed drop zone in the middle and recent files along the bottom.
final class IdleView: NSView {
    var onOpen: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    private let dropZone = DropZone()
    private let hint = NSTextField(labelWithString: "拖拽音视频文件到窗口，或点击选择文件")
    private let strip = NSView()
    private let stripTitle = NSTextField(labelWithString: "最近播放")
    private let scroll = NSScrollView()
    private let cardsHost = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "播放过的视频会出现在这里")
    private var cards: [RecentCard] = []

    static let stripHeight: CGFloat = 150

    var dropHighlighted = false {
        didSet { dropZone.highlighted = dropHighlighted }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        dropZone.onClick = { [weak self] in self?.onOpen?() }
        addSubview(dropZone)

        hint.font = .systemFont(ofSize: 14, weight: .medium)
        hint.textColor = Theme.text
        hint.alignment = .center
        addSubview(hint)

        strip.wantsLayer = true
        strip.layer?.backgroundColor = Theme.strip.cgColor
        addSubview(strip)

        stripTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        stripTitle.textColor = Theme.textDim
        strip.addSubview(stripTitle)

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = cardsHost
        strip.addSubview(scroll)

        NotificationCenter.default.addObserver(self, selector: #selector(recentsChanged),
                                               name: RecentFiles.changed, object: nil)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = NSColor(white: 1, alpha: 0.3)
        strip.addSubview(emptyLabel)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let stripH = h > 420 ? Self.stripHeight : 0
        strip.isHidden = stripH == 0
        strip.frame = NSRect(x: 0, y: 0, width: w, height: stripH)
        stripTitle.frame = NSRect(x: 18, y: stripH - 26, width: 200, height: 16)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: stripH - 30)
        emptyLabel.sizeToFit()
        emptyLabel.setFrameOrigin(NSPoint(x: 18, y: (stripH - 30) / 2 - 8))

        let cardW: CGFloat = 150, cardH: CGFloat = 108, gap: CGFloat = 12
        cardsHost.frame = NSRect(x: 0, y: 0, width: max(CGFloat(cards.count) * (cardW + gap) + 24, w), height: stripH - 30)
        for (i, card) in cards.enumerated() {
            card.frame = NSRect(x: 18 + CGFloat(i) * (cardW + gap), y: 2, width: cardW, height: cardH)
        }

        // Drop zone centred in the area above the strip.
        let areaH = h - stripH
        let zoneW = min(240, w * 0.5), zoneH = min(150, areaH * 0.42)
        let zoneY = stripH + (areaH - zoneH) / 2 + 14
        dropZone.frame = NSRect(x: ((w - zoneW) / 2).rounded(), y: zoneY.rounded(), width: zoneW, height: zoneH)
        hint.frame = NSRect(x: 20, y: (zoneY - 34).rounded(), width: max(w - 40, 0), height: 20)
    }

    @objc private func recentsChanged() {
        if !isHidden { reloadRecents() }
    }

    /// Rebuilds the recent strip from RecentFiles.
    func reloadRecents() {
        cards.forEach { $0.removeFromSuperview() }
        let urls = RecentFiles.all
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(12)
        cards = urls.map { url in
            let card = RecentCard(url: url)
            card.onClick = { [weak self] in self?.onOpenRecent?(url) }
            cardsHost.addSubview(card)
            return card
        }
        emptyLabel.isHidden = !cards.isEmpty
        needsLayout = true
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Dashed rounded rectangle with a plus sign; turns orange on hover or while dragging a file over.
final class DropZone: NSView {
    var onClick: (() -> Void)?
    var highlighted = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        let color = (highlighted || hovering) ? Theme.accent : NSColor(white: 1, alpha: 0.75)
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.lineWidth = 2.5
        path.setLineDash([9, 6], count: 2, phase: 0)
        color.setStroke()
        if highlighted {
            Theme.accent.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        path.stroke()

        let arm = min(rect.width, rect.height) * 0.2
        let plus = NSBezierPath()
        plus.move(to: NSPoint(x: rect.midX - arm, y: rect.midY))
        plus.line(to: NSPoint(x: rect.midX + arm, y: rect.midY))
        plus.move(to: NSPoint(x: rect.midX, y: rect.midY - arm))
        plus.line(to: NSPoint(x: rect.midX, y: rect.midY + arm))
        plus.lineWidth = 2.5
        plus.lineCapStyle = .round
        plus.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func mouseDown(with event: NSEvent) {}

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

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

/// One recent file: Quick Look thumbnail (film glyph when unavailable) with the name underneath.
final class RecentCard: NSView {
    var onClick: (() -> Void)?
    private let url: URL
    private let thumb = NSImageView()
    private let glyph = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private var hovering = false { didSet { refreshBorder() } }
    private var hoverArea: NSTrackingArea?

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = Theme.card.cgColor
        layer?.borderColor = Theme.accent.cgColor
        layer?.masksToBounds = true
        toolTip = url.path

        glyph.image = Theme.symbol("film", size: 24, weight: .regular)
        glyph.contentTintColor = NSColor(white: 1, alpha: 0.35)
        addSubview(glyph)

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(thumb)

        name.stringValue = url.deletingPathExtension().lastPathComponent
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingMiddle
        name.alignment = .center
        addSubview(name)

        loadThumbnail()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let imgH = h - 26
        thumb.frame = NSRect(x: 0, y: 26, width: w, height: imgH)
        glyph.frame = NSRect(x: (w - 32) / 2, y: 26 + (imgH - 32) / 2, width: 32, height: 32)
        name.frame = NSRect(x: 6, y: 5, width: w - 12, height: 15)
    }

    private func loadThumbnail() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 300, height: 170),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                self?.thumb.image = image
                self?.glyph.isHidden = true
            }
        }
    }

    private func refreshBorder() { layer?.borderWidth = hovering ? 2 : 0 }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
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
