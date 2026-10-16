import AppKit
import ImageIO
import QuartzCore

@MainActor
final class ImagePreviewStrip: NSView {
    var onSizeChange: (() -> Void)?
    var onRemove: ((Int) -> Void)?
    var allowsRemoval = true {
        didSet { tiles.forEach { $0.removeButton.isEnabled = allowsRemoval } }
    }
    private let scroll = NSScrollView()
    private let row = NSStackView()
    private let fade = CAGradientLayer()
    private var tiles: [ImagePreviewTile] = []
    private var tileConstraints: [NSLayoutConstraint] = []
    private var stripHeight: NSLayoutConstraint!
    private var expanded = false
    private var side: CGFloat { expanded ? 192 : 96 }

    init(urls: [URL]) {
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.wantsLayer = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        scroll.documentView = row
        addSubview(scroll)
        stripHeight = heightAnchor.constraint(equalToConstant: 96)
        NSLayoutConstraint.activate([
            stripHeight,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for url in urls {
            let tile = ImagePreviewTile(url: url)
            tile.previewButton.target = self
            tile.previewButton.action = #selector(toggleSize)
            tile.removeButton.target = self
            tile.removeButton.action = #selector(removeImage(_:))
            row.addArrangedSubview(tile)
            tileConstraints += [tile.widthAnchor.constraint(equalToConstant: 96), tile.heightAnchor.constraint(equalToConstant: 96)]
            tiles.append(tile)
        }
        NSLayoutConstraint.activate(tileConstraints)
        updateTiles()
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        row.setFrameSize(NSSize(width: CGFloat(tiles.count) * side + CGFloat(max(0, tiles.count - 1)) * 8, height: side))
        row.layoutSubtreeIfNeeded()
        updateFade()
    }

    @objc private func toggleSize() {
        expanded.toggle()
        tileConstraints.forEach { $0.constant = side }
        stripHeight.constant = side
        if !expanded { scroll.contentView.scroll(to: .zero) }
        updateTiles()
        needsLayout = true
        onSizeChange?()
        layoutSubtreeIfNeeded()
    }

    private func updateTiles() {
        for tile in tiles {
            tile.previewButton.cornerRadius = expanded ? 24 : 15
            tile.previewButton.setAccessibilityHelp(expanded ? "Return to default preview size" : "Enlarge image previews")
            tile.previewButton.toolTip = tile.previewButton.title + (expanded ? "\nClick for default size" : "\nClick to enlarge")
        }
    }

    @objc private func removeImage(_ sender: NSButton) {
        guard allowsRemoval, let index = tiles.firstIndex(where: { $0.removeButton === sender }) else { return }
        let tile = tiles.remove(at: index)
        row.removeArrangedSubview(tile)
        tile.removeFromSuperview()
        let constraints = Array(tileConstraints[(index * 2)..<(index * 2 + 2)])
        NSLayoutConstraint.deactivate(constraints)
        tileConstraints.removeSubrange((index * 2)..<(index * 2 + 2))
        needsLayout = true
        onRemove?(index)
        onSizeChange?()
    }

    @objc private func scrolled() { updateFade() }

    private func updateFade() {
        let width = scroll.bounds.width
        guard width > 0 else { return }
        let offset = scroll.contentView.bounds.minX
        let remaining = max(0, row.bounds.width - width - offset)
        let left = min(40, max(0, offset) * 40 / 96)
        let right = min(40, remaining * 40 / 96)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = scroll.bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.locations = [0, NSNumber(value: Double(left / width)), NSNumber(value: Double(1 - right / width)), 1]
        fade.colors = [NSColor.black.withAlphaComponent(left > 0 ? 0 : 1).cgColor,
                       NSColor.black.cgColor, NSColor.black.cgColor,
                       NSColor.black.withAlphaComponent(right > 0 ? 0 : 1).cgColor]
        scroll.layer?.mask = left > 0 || right > 0 ? fade : nil
        CATransaction.commit()
    }
}

@MainActor
private final class ImagePreviewTile: NSView {
    let previewButton: ImagePreviewButton
    let removeButton = PreviewRemoveButton(title: "", target: nil, action: nil)
    init(url: URL) {
        previewButton = ImagePreviewButton(url: url)
        super.init(frame: .zero)
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewButton)
        removeButton.isBordered = false
        removeButton.setAccessibilityLabel("Remove \(url.lastPathComponent)")
        removeButton.toolTip = "Remove from this selection"
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            previewButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewButton.topAnchor.constraint(equalTo: topAnchor),
            previewButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ImagePreviewButton: PointingHandButton {
    var cornerRadius: CGFloat = 15 { didSet { needsDisplay = true } }
    private let thumbnail: NSImage?

    init(url: URL) {
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
           ] as CFDictionary) {
            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } else { thumbnail = nil }
        super.init(frame: .zero)
        title = url.lastPathComponent
        isBordered = false
        setAccessibilityLabel(url.lastPathComponent)
        focusRingType = .exterior

    }

    required init?(coder: NSCoder) { nil }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        PanelStyle.surface.setFill()
        shape.fill()
        if let thumbnail {
            let scale = max(bounds.width / thumbnail.size.width, bounds.height / thumbnail.size.height)
            let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
            thumbnail.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        } else {
            let side = min(32, bounds.width * 0.5)
            NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))?
                .draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
        }
        if isHighlighted { NSColor.black.withAlphaComponent(0.12).setFill(); shape.fill() }
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

@MainActor
private final class PreviewRemoveButton: PointingHandButton {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(isHighlighted ? 0.8 : 0.55).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)
                .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.4)])))?
            .draw(in: bounds.insetBy(dx: 6, dy: 6))
    }
}
