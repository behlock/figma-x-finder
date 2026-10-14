import AppKit

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
