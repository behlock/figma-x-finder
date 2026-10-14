import AppKit
import ImageIO

@MainActor
enum PanelStyle {
    static let background = adaptive(light: 0.995, dark: 0.105)
    static let surface = adaptive(light: 0.965, dark: 0.16)
    static let border = NSColor(name: "Panel border") { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.09 : 0.045)
    }

    private static func adaptive(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: 1)
        }
    }

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, wrapping: Bool = false) -> NSTextField {
        let label = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    static func surface(around content: NSView, padding: CGFloat = 12) -> NSView {
        let view = PanelSurface(color: surface, radius: 14, bordered: true)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding)
        ])
        return view
    }

    static func preview(_ urls: [URL]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        for url in urls.prefix(3) {
            let view = NSImageView()
            if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128
               ] as CFDictionary) {
                view.image = NSImage(cgImage: thumbnail, size: .zero)
            } else {
                view.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                view.contentTintColor = .secondaryLabelColor
            }
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = 7
            view.layer?.masksToBounds = true
            view.setAccessibilityLabel(url.lastPathComponent)
            row.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: 52).isActive = true
            view.heightAnchor.constraint(equalToConstant: 52).isActive = true
        }
        let name = label(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) selected files", size: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.toolTip = urls.prefix(3).map(\.lastPathComponent).joined(separator: "\n")
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = label(urls.count == 1 ? "Ready to collect" : "Originals stay in Finder", size: 11, color: .secondaryLabelColor, wrapping: true)
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(labels)
        labels.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -CGFloat(min(3, urls.count) * 60)).isActive = true
        name.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        return surface(around: row)
    }
}

@MainActor
final class PanelSurface: NSView {
    private let color: NSColor
    private let radius: CGFloat
    private let bordered: Bool

    init(color: NSColor, radius: CGFloat, bordered: Bool = false) {
        self.color = color
        self.radius = radius
        self.bordered = bordered
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: bordered ? 0.5 : 0, dy: bordered ? 0.5 : 0), xRadius: radius, yRadius: radius)
        color.setFill()
        shape.fill()
        if bordered { PanelStyle.border.setStroke(); shape.lineWidth = 1; shape.stroke() }
    }
}

@MainActor
final class CircularSendButton: NSButton {
    var completed = false { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 5, dy: 5) }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: focusRingMaskBounds).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let active = isEnabled || completed
        let ink: NSColor = active ? .systemBlue : .tertiaryLabelColor
        ink.withAlphaComponent(active ? 0.10 : 0.06).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        (isHighlighted && isEnabled ? ink.blended(withFraction: 0.15, of: .black)! : ink).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6)).fill()
        let symbol = NSImage(systemSymbolName: completed ? "checkmark" : "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        symbol?.draw(in: NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
