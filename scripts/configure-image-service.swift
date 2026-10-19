import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: configure-image-service.swift /path/to/Info.plist")
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
var services = plist["NSServices"] as! [[String: Any]]
guard let index = services.firstIndex(where: { $0["NSMessage"] as? String == "sendToFigma" }) else {
    fatalError("Send to Figma service is missing")
}

// Match Store.prepareImage's Image I/O reader, including newer formats when
// available. Using public.image alone would also offer unsupported SVG files.
let types = (CGImageSourceCopyTypeIdentifiers() as! [String]).filter {
    UTType($0)?.conforms(to: .image) == true
}.sorted()
guard !types.isEmpty else { fatalError("No supported image decoders found") }
services[index]["NSSendFileTypes"] = types
plist["NSServices"] = services
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
