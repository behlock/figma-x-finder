import AppKit
import BridgeCore

@main
enum Application {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do {
            try handOverFromOtherCopies()
            let override = ProcessInfo.processInfo.environment["FIGMA_FINDER_DATA_DIR"]
            let directory = override.map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Figma Finder Bridge", isDirectory: true)
            let delegate = try AppDelegate(store: Store(directory: directory))
            app.delegate = delegate
            app.servicesProvider = delegate
            NSUpdateDynamicServices()
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t open Figma x Finder"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @MainActor private static func handOverFromOtherCopies() throws {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !copies.isEmpty else { return }
        // Shut down peers before loading their shared queue or binding the listener.
        for copy in copies { _ = copy.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while copies.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard copies.allSatisfy(\.isTerminated) else {
            throw BridgeError.message("Another copy is still running. Quit Figma x Finder and open the installed app again. Queued images are retained.")
        }
    }
}
