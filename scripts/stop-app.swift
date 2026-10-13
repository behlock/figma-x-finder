import AppKit

let copies = NSRunningApplication.runningApplications(withBundleIdentifier: "com.behlock.figma-finder-bridge")
for copy in copies { _ = copy.terminate() }
let deadline = Date().addingTimeInterval(3)
while copies.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard copies.allSatisfy(\.isTerminated) else {
    fputs("Quit Figma Finder Bridge before installing the update.\n", stderr)
    exit(1)
}
