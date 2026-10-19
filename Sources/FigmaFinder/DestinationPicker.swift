import AppKit
import BridgeCore

@MainActor
final class DestinationPicker: PanelPillButton {
    var onChange: (() -> Void)?
    private(set) var selectedID: String?
    private var options: [Destination] = []
    private let popover = NSPopover()
    private let choices = DestinationChoicesController()

    init() {
        super.init(frame: .zero)
        setAccessibilityLabel("Figma destination")
        toolTip = "Choose a destination"
        target = self
        action = #selector(openChoices)
        popover.behavior = .transient
        popover.contentViewController = choices
        choices.onSelect = { [weak self] id in
            guard let self else { return }
            self.selectedID = id
            self.updateTitle()
            self.popover.close()
            self.onChange?()
        }
        choices.onCancel = { [weak self] in self?.popover.close() }
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func update(_ destinations: [Destination], rememberedID: String?) {
        if !destinations.contains(where: { $0.id == selectedID }) {
            selectedID = destinations.first(where: { $0.id == rememberedID })?.id ?? destinations.first?.id
        }
        if options != destinations {
            options = destinations
            if popover.isShown { choices.update(options, selectedID: selectedID) }
        }
        updateTitle()
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { popover.close() }
            needsDisplay = true
        }
    }

    private func updateTitle() {
        let updated = options.first(where: { $0.id == selectedID })?.pickerTitle ?? "No saved destinations"
        guard title != updated else { return }
        title = updated
        setAccessibilityValue(title)
        needsDisplay = true
    }

    @objc private func openChoices() {
        guard isEnabled else { return }
        if popover.isShown { popover.close(); return }
        choices.update(options, selectedID: selectedID)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        choices.focusChoices()
    }

}

@MainActor
private final class DestinationChoicesController: NSViewController {
    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let scroll = NSScrollView()
    private let rows = NSStackView()
    private var options: [Destination] = []
    private var highlightedIndex = 0
    private var buttons: [DestinationOptionButton] = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        scroll.documentView = rows
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }

    func update(_ destinations: [Destination], selectedID: String?) {
        _ = view
        options = destinations
        highlightedIndex = options.firstIndex(where: { $0.id == selectedID }) ?? 0
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        buttons = []
        for (index, option) in options.enumerated() {
            let button = DestinationOptionButton(title: option.pickerTitle, target: self, action: #selector(choose(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 14)
            button.alignment = .left
            button.isCurrent = option.id == selectedID
            button.setAccessibilityLabel(option.pickerTitle + (button.isCurrent ? ", selected" : ""))
            button.toolTip = option.pickerTitle
            rows.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 304),
                button.heightAnchor.constraint(equalToConstant: 36)
            ])
            buttons.append(button)
        }
        if options.isEmpty {
            let empty = PanelStyle.label("No saved destinations", color: .secondaryLabelColor)
            rows.addArrangedSubview(empty)
            empty.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        let rowHeight = CGFloat(max(1, options.count)) * 38
        rows.setFrameSize(NSSize(width: 304, height: rowHeight))
        preferredContentSize = NSSize(width: 320, height: min(280, rowHeight) + 16)
        highlight()
    }

    func focusChoices() { view.window?.makeFirstResponder(self) }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

    private func highlight() {
        for (index, button) in buttons.enumerated() {
            button.isKeyboardSelected = index == highlightedIndex
        }
        rows.layoutSubtreeIfNeeded()
        if buttons.indices.contains(highlightedIndex) {
            rows.scrollToVisible(buttons[highlightedIndex].frame)
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard options.indices.contains(sender.tag) else { return }
        onSelect?(options[sender.tag].id)
    }

    override func moveDown(_ sender: Any?) {
        highlightedIndex = min(max(0, options.count - 1), highlightedIndex + 1)
        highlight()
    }

    override func moveUp(_ sender: Any?) {
        highlightedIndex = max(0, highlightedIndex - 1)
        highlight()
    }

    override func insertNewline(_ sender: Any?) {
        if options.indices.contains(highlightedIndex) { onSelect?(options[highlightedIndex].id) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private extension Destination {
    var pickerTitle: String { nodeID == nil ? "\(name) (page)" : name }
}

@MainActor
private final class DestinationOptionButton: PointingHandButton {
    var isCurrent = false
    var isKeyboardSelected = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if isKeyboardSelected || isHighlighted {
            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        PanelStyle.drawTitle(title, in: NSRect(x: 10, y: 0, width: bounds.width - 42, height: bounds.height), font: font ?? .systemFont(ofSize: 14))
        if isCurrent {
            NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)
                    .applying(.init(paletteColors: [.systemBlue])))?
                .draw(in: NSRect(x: bounds.width - 25, y: 12, width: 12, height: 12))
        }
    }
}
