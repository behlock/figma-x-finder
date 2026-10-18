import AppKit
import BridgeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: Store
    private var picker: PickerController?
    private var receivedFiles = false
    private let server: LocalServer
    private var lastActivity = Date()
    private var idleTimer: Timer?

    init(store: Store) throws {
        self.store = store
        self.server = LocalServer(store: store)
        super.init()
        server.onRequest = { [weak self] in self?.lastActivity = Date() }
        server.router.onPairingRequest = { [weak self] request in self?.connectReceiver(request) }
        server.onFailure = { [weak self] message in
            self?.showError("Couldn’t start the local receiver connection", message: message)
        }
        try server.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastActivity) > 120,
                      !NSApp.windows.contains(where: \.isVisible) else { return }
                NSApp.terminate(nil)
            }
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--send" {
            showPicker(arguments.dropFirst().map { URL(fileURLWithPath: $0) })
        } else if arguments.first != "--serve", !receivedFiles {
            showPicker([])
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedFiles = true
        showPicker(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPicker([]) }
        return true
    }

    @objc func sendToFigma(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty else {
            error.pointee = "Select image files in Finder first." as NSString
            return
        }
        receivedFiles = true
        showPicker(urls)
    }

    private func showPicker(_ urls: [URL]) {
        lastActivity = Date()
        picker?.close()
        let controller = PickerController(store: store, urls: urls)
        picker = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func connectReceiver(_ request: PairingRequest) {
        lastActivity = Date()
        if picker?.window?.isVisible != true { showPicker([]) }
        guard let window = picker?.window, window.attachedSheet == nil else {
            server.router.confirmPairing(request.id, allow: false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Connect to Figma?"
        alert.informativeText = "Check that this code matches the one in the Figma plugin:\n\n\(request.code)\n\nOnly allow a connection you started. This lets the receiver access images you send and save destinations."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.server.router.confirmPairing(request.id, allow: response == .alertFirstButtonReturn)
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak window, weak alert] in
            guard let window, let alert, window.attachedSheet == alert.window else { return }
            window.endSheet(alert.window, returnCode: .abort)
        }
    }
}
