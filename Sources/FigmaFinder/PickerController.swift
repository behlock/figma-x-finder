import AppKit
import BridgeCore

@MainActor
final class PickerController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let store: Store
    private var urls: [URL]
    private let isSetup: Bool
    private let destinations = DestinationPicker()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let sendButton = CircularSendButton(title: "Send", target: nil, action: nil)
    private let stack = PickerController.column([], spacing: 14)
    private var destinationSurface: NSView?
    private var setupSurface: NSView?
    private var preview: ImagePreviewStrip?
    private var timer: Timer?
    private var jobID: String?
    private var sentCount = 0
    private var sentName = ""
    private var skippedCount = 0
    private var sendError: String?

    init(store: Store, urls: [URL]) {
        self.store = store
        self.urls = urls
        self.isSetup = urls.isEmpty
        let window = PickerWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = urls.isEmpty ? "Connect to Figma" : "Send to Figma"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = PanelSurface(color: PanelStyle.background, radius: 0)
        super.init(window: window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }

        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        if !urls.isEmpty {
            let preview = ImagePreviewStrip(urls: urls)
            self.preview = preview
            preview.onSizeChange = { [weak self] in self?.fitWindow(animated: true) }
            preview.onRemove = { [weak self] index in
                guard let self, self.jobID == nil, self.urls.indices.contains(index) else { return }
                self.urls.remove(at: index)
                self.sendError = nil
                self.refresh()
            }
            stack.addArrangedSubview(preview)
        }
        let setupSurface = pluginStep()
        self.setupSurface = setupSurface
        stack.addArrangedSubview(setupSurface)
        destinations.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        destinations.onChange = { [weak self] in self?.sendError = nil; self?.refresh() }
        destinations.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"
        sendButton.isBordered = false
        sendButton.focusRingType = .exterior
        sendButton.toolTip = "Send to Figma (Return)"
        sendButton.setAccessibilityLabel("Send")
        let destinationRow = NSStackView(views: urls.isEmpty ? [destinations] : [destinations, sendButton])
        destinationRow.alignment = .centerY
        destinationRow.spacing = 12
        destinations.widthAnchor.constraint(equalTo: destinationRow.widthAnchor, constant: urls.isEmpty ? 0 : -66).isActive = true
        if !urls.isEmpty {
            sendButton.widthAnchor.constraint(equalToConstant: 54).isActive = true
            sendButton.heightAnchor.constraint(equalToConstant: 54).isActive = true
        }
        let destinationSurface = PanelStyle.surface(around: destinationRow)
        self.destinationSurface = destinationSurface
        stack.addArrangedSubview(destinationSurface)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(status)

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

    private static func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let group = NSStackView(views: views)
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
        return group
    }

    private func pluginStep() -> NSView {
        let button = PanelPillButton(frame: .zero)
        button.title = "Show manifest…"
        button.target = self
        button.action = #selector(revealPlugin)
        button.contentTintColor = .systemBlue
        button.toolTip = "Show manifest.json"
        button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let steps = ["Import Figma Plugin", "Run Figma Finder Bridge"]
        let rows = steps.enumerated().map { index, step -> NSView in
            let number = PanelStyle.label("\(index + 1)", size: 14, color: .secondaryLabelColor)
            number.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let title = PanelStyle.label(step, size: 14)
            title.font = .systemFont(ofSize: 14, weight: .medium)
            let content = Self.column([title], spacing: 4)
            if index == 0 {
                let description = PanelStyle.label("Plugins › Development › Import plugin from manifest", size: 12, color: .secondaryLabelColor, wrapping: true)
                content.addArrangedSubview(description)
                description.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
                let surface = PanelStyle.surface(around: button)
                content.addArrangedSubview(surface)
                surface.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
                content.setCustomSpacing(12, after: description)
            }
            let row = NSStackView(views: [number, content])
            row.alignment = .top
            row.spacing = 8
            content.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -28).isActive = true
            return row
        }
        return Self.column(rows, spacing: 20)
    }

    private func fitWindow(animated: Bool = false) {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height) + 72
        if abs(content.bounds.height - height) > 1 {
            var frame = window.frame
            let delta = height - content.bounds.height
            frame.size.height += delta
            frame.origin.y -= delta
            window.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    required init?(coder: NSCoder) { nil }
    override func close() { timer?.invalidate(); super.close() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        onClose?()
    }

    private var selected: Destination? {
        store.destinations.first(where: { $0.id == destinations.selectedID })
    }

    private func refresh() {
        let saved = store.destinations
        destinations.update(saved, rememberedID: store.lastDestinationID)
        setupSurface?.isHidden = !isSetup && !saved.isEmpty
        destinationSurface?.isHidden = isSetup || saved.isEmpty
        destinations.isEnabled = !saved.isEmpty && jobID == nil
        preview?.allowsRemoval = jobID == nil
        sendButton.isEnabled = !urls.isEmpty && selected != nil && jobID == nil
        sendButton.completed = false
        sendButton.setAccessibilityLabel("Send")
        status.textColor = .secondaryLabelColor
        status.stringValue = ""
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
        } else if !isSetup && urls.isEmpty {
            status.stringValue = "No images selected. Choose images in Finder to send."
        }
        status.isHidden = status.stringValue.isEmpty
        fitWindow()
    }

    @objc private func send() {
        guard jobID == nil, !urls.isEmpty, let destination = selected else { return }
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

    @objc private func revealPlugin() {
        let manifest = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/receiver/manifest.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            NSWorkspace.shared.activateFileViewerSelecting([manifest])
        } else {
            sendError = "The receiver plugin isn’t included in this build yet."
            refresh()
        }
    }

}

@MainActor
private final class PickerWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
