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

    static func label(_ text: String, size: CGFloat = 13,
                      color: NSColor = .labelColor, wrapping: Bool = false) -> NSTextField {
        let label = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    static func drawTitle(_ title: String, in bounds: NSRect, font: NSFont, color: NSColor = .labelColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let height = text.size().height
        text.draw(in: NSRect(x: bounds.minX, y: bounds.midY - height / 2, width: max(0, bounds.width), height: height))
    }

    static func surface(around content: NSView) -> NSView {
        let view = PanelSurface(color: surface, radius: 14, bordered: true)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
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
class PointingHandButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if let window, visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                updateHoverCursor()
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    private func updateHoverCursor() { (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set() }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); updateHoverCursor() }
    override func mouseMoved(with event: NSEvent) { updateHoverCursor() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); NSCursor.arrow.set() }
}

@MainActor
class PanelPillButton: PointingHandButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        font = .systemFont(ofSize: 17)
        alignment = .left
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { nil }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        (isHighlighted ? NSColor.quaternaryLabelColor : PanelStyle.background).setFill()
        shape.fill()
        PanelStyle.drawTitle(title, in: bounds.insetBy(dx: 12, dy: 0), font: font ?? .systemFont(ofSize: 17),
                             color: isEnabled ? (contentTintColor ?? .labelColor) : .secondaryLabelColor)
    }
}

@MainActor
final class CircularSendButton: PointingHandButton {
    enum Phase { case ready, sending, failed }
    private let progress = NSProgressIndicator()
    var phase: Phase = .ready {
        didSet {
            guard phase != oldValue else { return }
            if phase == .sending { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
            needsDisplay = true
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        progress.style = .spinning
        progress.isIndeterminate = true
        progress.appearance = NSAppearance(named: .darkAqua)
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 5, dy: 5) }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: focusRingMaskBounds).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let active = isEnabled || phase != .ready
        let ink: NSColor = phase == .failed ? .systemRed : (active ? .systemBlue : .tertiaryLabelColor)
        ink.withAlphaComponent(active ? 0.10 : 0.06).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        (isHighlighted && isEnabled ? ink.blended(withFraction: 0.15, of: .black)! : ink).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6)).fill()
        let name: String
        switch phase {
        case .ready: name = "arrow.up.right"
        case .sending: name = ""
        case .failed: name = "exclamationmark"
        }
        let symbol: NSImage? = name.isEmpty ? nil : NSImage(systemSymbolName: name, accessibilityDescription: nil)?
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
