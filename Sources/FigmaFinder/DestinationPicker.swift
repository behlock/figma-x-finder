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
        toolTip = "Choose or search destinations"
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
            if !isEnabled { popover.close() }
            needsDisplay = true
        }
    }

    private func updateTitle() {
        title = options.first(where: { $0.id == selectedID })?.name ?? "No saved destinations"
        setAccessibilityValue(title)
        needsDisplay = true
    }

    @objc private func openChoices() {
        guard isEnabled else { return }
        if popover.isShown { popover.close(); return }
        choices.update(options, selectedID: selectedID, resetSearch: true)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        choices.focusSearch()
    }

}

@MainActor
private final class DestinationChoicesController: NSViewController, NSSearchFieldDelegate {
    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let rows = NSStackView()
    private var options: [Destination] = []
    private var filtered: [Destination] = []
    private var selectedID: String?
    private var highlightedIndex = 0
    private var buttons: [DestinationOptionButton] = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        search.placeholderString = "Search destinations"
        search.setAccessibilityLabel("Search destinations")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        scroll.documentView = rows
        view.addSubview(search)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }

    func update(_ destinations: [Destination], selectedID: String?, resetSearch: Bool = false) {
        _ = view
        options = destinations
        self.selectedID = selectedID
        if resetSearch { search.stringValue = "" }
        rebuild()
    }

    func focusSearch() { view.window?.makeFirstResponder(search) }
    func controlTextDidChange(_ obj: Notification) { rebuild() }

    private func rebuild() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = options.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        highlightedIndex = filtered.firstIndex(where: { $0.id == selectedID }) ?? 0
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        buttons = []
        for (index, option) in filtered.enumerated() {
            let button = DestinationOptionButton(title: option.name, target: self, action: #selector(choose(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 14)
            button.alignment = .left
            button.isCurrent = option.id == selectedID
            button.setAccessibilityLabel(option.name + (button.isCurrent ? ", selected" : ""))
            button.toolTip = option.name
            rows.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 304),
                button.heightAnchor.constraint(equalToConstant: 36)
            ])
            buttons.append(button)
        }
        if filtered.isEmpty {
            let empty = PanelStyle.label("No matching destinations", color: .secondaryLabelColor)
            rows.addArrangedSubview(empty)
            empty.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        let rowHeight = CGFloat(max(1, filtered.count)) * 38
        rows.setFrameSize(NSSize(width: 304, height: rowHeight))
        preferredContentSize = NSSize(width: 320, height: min(280, rowHeight) + 54)
        highlight()
    }

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
        guard filtered.indices.contains(sender.tag) else { return }
        onSelect?(filtered[sender.tag].id)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            highlightedIndex = min(max(0, filtered.count - 1), highlightedIndex + 1)
            highlight()
        case #selector(NSResponder.moveUp(_:)):
            highlightedIndex = max(0, highlightedIndex - 1)
            highlight()
        case #selector(NSResponder.insertNewline(_:)):
            if filtered.indices.contains(highlightedIndex) { onSelect?(filtered[highlightedIndex].id) }
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default: return false
        }
        return true
    }
}

@MainActor
private final class DestinationOptionButton: NSButton {
    var isCurrent = false
    var isKeyboardSelected = false { didSet { needsDisplay = true } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
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
