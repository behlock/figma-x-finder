import AppKit
import BridgeCore

@MainActor
final class PickerController: NSWindowController {
    private let store: Store
    private let urls: [URL]
    private let destinations = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let sendButton = CircularSendButton(title: "Send", target: nil, action: nil)
    private let stack = NSStackView()
    private var destinationIDs: [String] = []
    private var timer: Timer?
    private var jobID: String?
    private var sentCount = 0
    private var sentName = ""
    private var skippedCount = 0
    private var sendError: String?

    init(store: Store, urls: [URL]) {
        self.store = store
        self.urls = urls
        let window = PickerWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Send to Figma"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = PanelSurface(color: PanelStyle.background, radius: 0)
        super.init(window: window)
        window.onCancel = { [weak self] in self?.close() }

        let title = PanelStyle.label(urls.isEmpty ? "Connect to Figma" : "Send to Figma", size: 22, weight: .medium)
        let heading = NSStackView(views: [title])
        if urls.isEmpty {
            heading.addArrangedSubview(PanelStyle.label("A home for your inspiration.", color: .secondaryLabelColor))
        }
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 5
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(heading)
        if urls.isEmpty {
            let instructions = PanelStyle.label("Import the receiver plugin in Figma, copy the connection key into it, then save a page or frame as a destination.", color: .secondaryLabelColor, wrapping: true)
            stack.addArrangedSubview(instructions)
            let key = NSTextField(string: store.token)
            key.isEditable = false
            key.isSelectable = true
            key.isBordered = false
            key.drawsBackground = false
            key.textColor = .secondaryLabelColor
            key.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            key.lineBreakMode = .byTruncatingMiddle
            key.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            key.setAccessibilityLabel("Connection key")
            stack.addArrangedSubview(PanelStyle.surface(around: key))
            let copy = secondaryButton("Copy connection key", action: #selector(copyKey))
            let reveal = secondaryButton("Show receiver plugin", action: #selector(revealPlugin))
            let setupButtons = NSStackView(views: [copy, reveal])
            setupButtons.spacing = 16
            stack.addArrangedSubview(setupButtons)
        } else {
            stack.addArrangedSubview(PanelStyle.preview(urls))
        }
        destinations.setAccessibilityLabel("Figma destination")
        destinations.isBordered = false
        destinations.font = .systemFont(ofSize: 17, weight: .regular)
        destinations.cell?.lineBreakMode = .byTruncatingTail
        destinations.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        destinations.target = self
        destinations.action = #selector(destinationChanged)
        destinations.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let destinationLabel = PanelStyle.label("Destination", size: 11, color: .secondaryLabelColor)
        let destinationFields = NSStackView(views: [destinationLabel, destinations])
        destinationFields.orientation = .vertical
        destinationFields.alignment = .leading
        destinationFields.spacing = 3
        destinations.widthAnchor.constraint(equalTo: destinationFields.widthAnchor).isActive = true
        destinationFields.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"
        sendButton.isBordered = false
        sendButton.focusRingType = .exterior
        sendButton.toolTip = "Send to Figma (Return)"
        sendButton.setAccessibilityLabel("Send")
        let destinationRow = NSStackView(views: urls.isEmpty ? [destinationFields] : [destinationFields, sendButton])
        destinationRow.alignment = .centerY
        destinationRow.spacing = 12
        destinationFields.widthAnchor.constraint(equalTo: destinationRow.widthAnchor, constant: urls.isEmpty ? 0 : -66).isActive = true
        if !urls.isEmpty {
            sendButton.widthAnchor.constraint(equalToConstant: 54).isActive = true
            sendButton.heightAnchor.constraint(equalToConstant: 54).isActive = true
        }
        stack.addArrangedSubview(PanelStyle.surface(around: destinationRow))
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(status)

        let open = secondaryButton("Open Figma ↗", action: #selector(openFigma))
        open.setAccessibilityLabel("Open Figma")
        let footer = NSView()
        footer.addSubview(open)
        NSLayoutConstraint.activate([
            open.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            open.topAnchor.constraint(equalTo: footer.topAnchor),
            open.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 28)
        ])
        stack.addArrangedSubview(footer)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 48)
        ])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func secondaryButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return button
    }

    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height) + 72
        if abs(content.bounds.height - height) > 1 {
            var frame = window.frame
            let delta = height - content.bounds.height
            frame.size.height += delta
            frame.origin.y -= delta
            window.setFrame(frame, display: true)
        }
    }

    required init?(coder: NSCoder) { nil }
    override func close() { timer?.invalidate(); super.close() }

    private var selected: Destination? {
        let index = destinations.indexOfSelectedItem
        guard destinationIDs.indices.contains(index) else { return nil }
        return store.destinations.first(where: { $0.id == destinationIDs[index] })
    }

    private func refresh() {
        let remembered = selected?.id ?? store.lastDestinationID
        let saved = store.destinations
        if destinations.numberOfItems == 0 || (!saved.isEmpty && destinations.itemTitles != saved.map(\.name)) || destinationIDs != saved.map(\.id) {
            destinations.removeAllItems()
            destinationIDs = saved.map(\.id)
            destinations.addItems(withTitles: saved.isEmpty ? ["No saved destinations"] : saved.map(\.name))
            if let index = saved.firstIndex(where: { $0.id == remembered }) { destinations.selectItem(at: index) }
        }
        destinations.isEnabled = !saved.isEmpty && jobID == nil
        sendButton.isEnabled = !urls.isEmpty && selected != nil && jobID == nil
        sendButton.completed = false
        sendButton.setAccessibilityLabel("Send")
        status.textColor = .secondaryLabelColor
        if let jobID {
            if let job = store.jobs.first(where: { $0.id == jobID }) {
                if job.lastError != nil { status.textColor = .systemRed }
                let pending = job.images.count - job.completed.count
                status.stringValue = job.lastError ?? "\(pending) image\(pending == 1 ? "" : "s") queued. Run the receiver in \(sentName) to finish."
            } else {
                sendButton.completed = true
                sendButton.setAccessibilityLabel("Sent")
                status.stringValue = "Added \(sentCount) image\(sentCount == 1 ? "" : "s") to \(sentName)." + (skippedCount > 0 ? " \(skippedCount) skipped." : "")
            }
        } else if let sendError {
            status.stringValue = sendError
            status.textColor = .systemRed
        } else if urls.isEmpty {
            let pending = store.jobs.reduce(0) { $0 + $1.images.count - $1.completed.count }
            status.stringValue = pending > 0 ? "\(pending) images waiting for Figma." : "Choose images in Finder, then Services → Send to Figma…"
        } else {
            status.stringValue = saved.isEmpty ? "Open this app without files to connect a Figma destination first." : ""
        }
        status.isHidden = status.stringValue.isEmpty
        fitWindow()
    }

    @objc private func send() {
        guard let destination = selected else { return }
        sendError = nil
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
        } catch {
            sendError = error.localizedDescription
            refresh()
        }
    }

    @objc private func destinationChanged() { sendError = nil; refresh() }

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

@MainActor
private final class PickerWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
