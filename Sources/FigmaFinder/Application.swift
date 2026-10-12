import AppKit
import BridgeCore

@main
enum Application {
@MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    do {
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
    alert.messageText = "Couldn’t open Figma Finder Bridge"
    alert.informativeText = error.localizedDescription
    alert.runModal()
    }
}
}
