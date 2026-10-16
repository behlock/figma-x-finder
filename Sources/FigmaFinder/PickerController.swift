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
    private let setupSteps = PickerController.column([], spacing: 14)
    private let setupToggle = NSButton(title: "Show setup instructions", target: nil, action: nil)
    private let destinationLabel = PanelStyle.label("Saved destination", size: 12, color: .secondaryLabelColor)
    private var setupExpanded = false
    private var previouslyHadDestinations = false
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
        let steps: [NSView] = [
            PanelStyle.label("Connect Figma once, then send images from Finder.", color: .secondaryLabelColor, wrapping: true),
            pluginStep(),
            PanelStyle.surface(around: Self.column([
                PanelStyle.label("2. Connect and save a destination", size: 17),
                PanelStyle.label("In the plugin, click Connect and approve the matching code here. Select a frame, name it, and click Save destination. To use the whole page, deselect everything first.", size: 12, color: .secondaryLabelColor, wrapping: true)
            ])),
            PanelStyle.label("After reopening Figma, run the plugin again. Your destinations stay saved.", size: 12, color: .secondaryLabelColor, wrapping: true)
        ]
        for step in steps {
            setupSteps.addArrangedSubview(step)
            step.widthAnchor.constraint(equalTo: setupSteps.widthAnchor).isActive = true
        }
        setupToggle.target = self
        setupToggle.action = #selector(toggleSetup)
        setupToggle.isBordered = false
        setupToggle.bezelStyle = .inline
        setupToggle.font = .systemFont(ofSize: 12, weight: .medium)
        setupToggle.contentTintColor = .secondaryLabelColor
        setupToggle.alignment = .left
        setupToggle.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
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
        if isSetup { stack.addArrangedSubview(destinationLabel) }
        stack.addArrangedSubview(destinationSurface)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(status)
        if isSetup { stack.addArrangedSubview(setupToggle) }
        stack.addArrangedSubview(setupSteps)

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

    @objc private func toggleSetup() {
        setupExpanded.toggle()
        sendError = nil
        refresh()
    }

    private func pluginStep() -> NSView {
        let action = #selector(revealPlugin)
        let button = CircularSendButton(title: "Show plugin file", target: self, action: action)
        button.toolTip = "Show manifest.json to add the plugin to Figma once"
        button.setAccessibilityLabel("Show plugin file")
        button.isBordered = false
        button.focusRingType = .exterior
        let pill = PanelPillButton(frame: .zero)
        pill.title = "1. Add the plugin"
        pill.target = self
        pill.action = action
        pill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pill.setAccessibilityLabel("Show plugin file")
        pill.toolTip = button.toolTip
        let row = NSStackView(views: [pill, button])
        row.alignment = .centerY
        row.spacing = 12
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 38),
            pill.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -66),
            button.widthAnchor.constraint(equalToConstant: 54),
            button.heightAnchor.constraint(equalToConstant: 54)
        ])
        return PanelStyle.surface(around: Self.column([
            row,
            PanelStyle.label("Click above to show the plugin file. In Figma Desktop, choose Plugins → Development → Import plugin from manifest… and select manifest.json. Then run Figma Finder Bridge from the same menu.", size: 12, color: .secondaryLabelColor, wrapping: true)
        ]))
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
        if !saved.isEmpty && !previouslyHadDestinations { setupExpanded = false }
        previouslyHadDestinations = !saved.isEmpty
        let showingSetup = saved.isEmpty || (isSetup && setupExpanded)
        setupSteps.isHidden = !showingSetup
        setupToggle.isHidden = saved.isEmpty
        setupToggle.title = showingSetup ? "Back to sending" : "Show setup instructions"
        destinationLabel.isHidden = showingSetup
        destinationSurface?.isHidden = showingSetup
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
        } else if isSetup {
            let pending = store.jobs.reduce(0) { $0 + $1.images.count - $1.completed.count }
            if pending > 0 && !setupExpanded {
                status.stringValue = "\(pending) image\(pending == 1 ? "" : "s") waiting for Figma.\nOpen the destination file in Figma and run Figma Finder Bridge to add them."
            } else {
                status.stringValue = saved.isEmpty || setupExpanded ? "" :
                    "1. Open the destination file in Figma and run Figma Finder Bridge.\n2. In Finder, select images → Services → Send to Figma.\n3. Choose a destination and click ↗ to send."
            }
        } else if urls.isEmpty {
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
