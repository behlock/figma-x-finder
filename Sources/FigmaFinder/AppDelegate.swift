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
}
