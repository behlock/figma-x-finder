import AppKit
import BridgeCore

@MainActor
final class PickerController: NSWindowController {
    private let destinations = NSPopUpButton()

    init(store: Store, urls: [URL]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Send to Figma"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let title = NSTextField(labelWithString: urls.isEmpty ? "Connect your inspiration board" : "Send \(urls.count) selected file\(urls.count == 1 ? "" : "s")")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "Destinations will appear here after you register a page or frame in the Figma receiver.")
        description.textColor = .secondaryLabelColor
        destinations.addItems(withTitles: store.destinations.map(\.name))
        if let id = store.lastDestinationID, let index = store.destinations.firstIndex(where: { $0.id == id }) {
            destinations.selectItem(at: index)
        }
        if store.destinations.isEmpty {
            destinations.addItem(withTitle: "No saved destinations")
            destinations.isEnabled = false
        }
        let send = NSButton(title: "Send", target: nil, action: nil)
        send.isEnabled = false
        let cancel = NSButton(title: "Close", target: self, action: #selector(dismiss))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, send])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [title, description, destinations, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            destinations.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
    @objc private func dismiss() { close() }
}
