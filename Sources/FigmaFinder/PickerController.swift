import AppKit
import BridgeCore

@MainActor
final class PickerController: NSWindowController {
    private let store: Store
    private let urls: [URL]
    private let destinations = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private var destinationIDs: [String] = []
    private var timer: Timer?
    private var jobID: String?
    private var sentCount = 0
    private var sentName = ""
    private var skippedCount = 0

    init(store: Store, urls: [URL]) {
        self.store = store
        self.urls = urls
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: urls.isEmpty ? 330 : 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Send to Figma"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let title = NSTextField(labelWithString: urls.isEmpty ? "Connect your inspiration board" : "Send \(urls.count) selected file\(urls.count == 1 ? "" : "s")")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        status.textColor = .secondaryLabelColor
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)
        if urls.isEmpty {
            let instructions = NSTextField(wrappingLabelWithString: "Import the receiver plugin in Figma. Copy this connection key into it, then save the current page or selected frame as a destination.")
            instructions.textColor = .secondaryLabelColor
            stack.addArrangedSubview(instructions)
            let key = NSTextField(string: store.token)
            key.isEditable = false
            key.isSelectable = true
            key.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            key.lineBreakMode = .byTruncatingMiddle
            key.setAccessibilityLabel("Connection key")
            stack.addArrangedSubview(key)
            let copy = NSButton(title: "Copy connection key", target: self, action: #selector(copyKey))
            let reveal = NSButton(title: "Show receiver plugin", target: self, action: #selector(revealPlugin))
            let setupButtons = NSStackView(views: [copy, reveal])
            setupButtons.spacing = 8
            stack.addArrangedSubview(setupButtons)
            key.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        destinations.setAccessibilityLabel("Figma destination")
        stack.addArrangedSubview(destinations)
        stack.addArrangedSubview(status)
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Close", target: self, action: #selector(dismiss))
        cancel.keyEquivalent = "\u{1b}"
        let open = NSButton(title: "Open Figma", target: self, action: #selector(openFigma))
        let buttons = NSStackView(views: urls.isEmpty ? [cancel, open] : [cancel, open, sendButton])
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            destinations.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }
    override func close() { timer?.invalidate(); super.close() }
    @objc private func dismiss() { close() }

    private var selected: Destination? {
        let index = destinations.indexOfSelectedItem
        guard destinationIDs.indices.contains(index) else { return nil }
        return store.destinations.first(where: { $0.id == destinationIDs[index] })
    }

    private func refresh() {
        let remembered = selected?.id ?? store.lastDestinationID
        let saved = store.destinations
        if destinations.itemTitles != saved.map(\.name) || destinationIDs != saved.map(\.id) {
            destinations.removeAllItems()
            destinationIDs = saved.map(\.id)
            destinations.addItems(withTitles: saved.isEmpty ? ["No saved destinations"] : saved.map(\.name))
            if let index = saved.firstIndex(where: { $0.id == remembered }) { destinations.selectItem(at: index) }
        }
        destinations.isEnabled = !saved.isEmpty && jobID == nil
        sendButton.isEnabled = !urls.isEmpty && selected != nil && jobID == nil
        if let jobID {
            if let job = store.jobs.first(where: { $0.id == jobID }) {
                status.stringValue = job.lastError ?? "\(job.images.count - job.completed.count) images queued. Run the receiver in \(sentName) to finish."
            } else {
                status.stringValue = "Added \(sentCount) image\(sentCount == 1 ? "" : "s") to \(sentName)." + (skippedCount > 0 ? " \(skippedCount) skipped." : "")
            }
        } else if urls.isEmpty {
            let pending = store.jobs.reduce(0) { $0 + $1.images.count - $1.completed.count }
            status.stringValue = pending > 0 ? "\(pending) images waiting for Figma." : "Choose images in Finder, then Services → Send to Figma…"
        } else {
            status.stringValue = saved.isEmpty ? "Open this app without files to connect a Figma destination first." : "Images will be copied into this destination."
        }
    }

    @objc private func send() {
        guard let destination = selected else { return }
        do {
            let result = try store.enqueue(urls, destination: destination)
            jobID = result.job.id
            sentCount = result.job.images.count
            sentName = destination.name
            skippedCount = result.skipped.count
            refresh()
            if !result.skipped.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Queued \(sentCount) images; skipped \(skippedCount) files"
                alert.informativeText = result.skipped.joined(separator: "\n")
                alert.beginSheetModal(for: window!)
            }
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.token, forType: .string)
    }

    @objc private func revealPlugin() {
        let manifest = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/receiver/manifest.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            NSWorkspace.shared.activateFileViewerSelecting([manifest])
        } else { status.stringValue = "The receiver plugin isn’t included in this build yet." }
    }

    @objc private func openFigma() {
        NSWorkspace.shared.open(selected?.url ?? URL(string: "https://www.figma.com")!)
    }
}
