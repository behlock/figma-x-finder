import AppKit
import BridgeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: Store
    private var picker: PickerController?
    private var receivedFiles = false

    init(store: Store) throws {
        self.store = store
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "Select image files in Finder first." as NSString
            return
        }
        receivedFiles = true
        showPicker(urls)
    }

    private func showPicker(_ urls: [URL]) {
        picker?.close()
        let controller = PickerController(store: store, urls: urls)
        picker = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }
}
