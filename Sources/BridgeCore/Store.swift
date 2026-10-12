import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct Destination: Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public let fileKey: String
    public let pageID: String
    public let nodeID: String?

    public init(id: String = UUID().uuidString, name: String, fileKey: String, pageID: String, nodeID: String?) {
        self.id = id
        self.name = name
        self.fileKey = fileKey
        self.pageID = pageID
        self.nodeID = nodeID
    }

    public var url: URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "www.figma.com"
        url.path = "/design/\(fileKey)"
        url.queryItems = [URLQueryItem(name: "node-id", value: nodeID ?? pageID)]
        return url.url!
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              fileKey.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              pageID.range(of: "^[0-9]+:[0-9]+$", options: .regularExpression) != nil,
              nodeID == nil || nodeID!.range(of: "^[0-9]+:[0-9]+$", options: .regularExpression) != nil
        else { throw BridgeError.message("Choose a valid Figma Design page or frame.") }
    }
}

public enum BridgeError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

public struct QueuedImage: Codable {
    public let id: String
    public let name: String
    public let width: Int
    public let height: Int
}

public struct Job: Codable {
    public let id: String
    public let destination: Destination
    public let images: [QueuedImage]
    public var completed: Set<String> = []
    public var lastError: String?
}

public struct EnqueueResult {
    public let job: Job
    public let skipped: [String]
}

public final class Store {
    private struct State: Codable {
        var destinations: [Destination] = []
        var lastDestinationID: String?
        var token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var jobs: [Job] = []
    }

    public let directory: URL
    private var state: State
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    public var destinations: [Destination] { state.destinations }
    public var lastDestinationID: String? { state.lastDestinationID }
    public var token: String { state.token }
    public var jobs: [Job] { state.jobs }
    private var queueDirectory: URL { directory.appendingPathComponent("queue", isDirectory: true) }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("state.json")
        state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try persist(state)
    }

    public func save(_ destination: Destination) throws {
        try destination.validate()
        var updated = state
        if let index = updated.destinations.firstIndex(where: {
            $0.fileKey == destination.fileKey && $0.pageID == destination.pageID && $0.nodeID == destination.nodeID
        }) {
            let existing = updated.destinations[index]
            updated.destinations[index] = Destination(id: existing.id, name: destination.name, fileKey: existing.fileKey, pageID: existing.pageID, nodeID: existing.nodeID)
        } else {
            // Registration never accepts an externally supplied local ID.
            updated.destinations.append(Destination(name: destination.name, fileKey: destination.fileKey, pageID: destination.pageID, nodeID: destination.nodeID))
        }
        try persist(updated)
    }

    public func enqueue(_ urls: [URL], destination: Destination) throws -> EnqueueResult {
        guard state.destinations.contains(where: { $0 == destination }) else {
            throw BridgeError.message("This destination is no longer saved.")
        }
        guard urls.count <= 100 else { throw BridgeError.message("Send up to 100 images at a time.") }
        let id = UUID().uuidString
        let folder = queueDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: folder) } }
        var images: [QueuedImage] = []
        var skipped: [String] = []
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            do {
                let imageID = UUID().uuidString
                let image = try prepareImage(url, to: folder.appendingPathComponent(imageID + ".png"))
                images.append(QueuedImage(id: imageID, name: url.lastPathComponent, width: image.0, height: image.1))
            } catch { skipped.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        guard !images.isEmpty else { throw BridgeError.message(skipped.joined(separator: "\n")) }
        let job = Job(id: id, destination: destination, images: images)
        var updated = state
        updated.jobs.append(job)
        updated.lastDestinationID = destination.id
        try persist(updated)
        committed = true
        return EnqueueResult(job: job, skipped: skipped)
    }

    public func imageData(jobID: String, imageID: String) throws -> Data {
        guard let job = state.jobs.first(where: { $0.id == jobID }),
              job.images.contains(where: { $0.id == imageID }), !job.completed.contains(imageID)
        else { throw BridgeError.message("Queued image not found.") }
        return try Data(contentsOf: queueDirectory.appendingPathComponent(jobID).appendingPathComponent(imageID + ".png"))
    }

    public func acknowledge(jobID: String, imageID: String) throws {
        guard let index = state.jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard state.jobs[index].images.contains(where: { $0.id == imageID }) else {
            throw BridgeError.message("Queued image not found.")
        }
        var updated = state
        updated.jobs[index].completed.insert(imageID)
        updated.jobs[index].lastError = nil
        let finished = updated.jobs[index].completed.count == updated.jobs[index].images.count
        if finished { updated.jobs.remove(at: index) }
        // Persist acknowledgement before deleting the local image.
        try persist(updated)
        let folder = queueDirectory.appendingPathComponent(jobID)
        try? FileManager.default.removeItem(at: finished ? folder : folder.appendingPathComponent(imageID + ".png"))
    }

    public func reportError(jobID: String, message: String) throws {
        guard let index = state.jobs.firstIndex(where: { $0.id == jobID }) else { return }
        var updated = state
        updated.jobs[index].lastError = String(message.prefix(500))
        try persist(updated)
    }

    private func prepareImage(_ url: URL, to output: URL) throws -> (Int, Int) {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary)
        else { throw BridgeError.message("Not a readable image.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw BridgeError.message("Couldn’t prepare this image.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 10 * 1024 * 1024 else {
            throw BridgeError.message("Prepared image exceeds 10 MB.")
        }
        try (data as Data).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        return (image.width, image.height)
    }

    public func remember(_ id: String) throws {
        var updated = state
        updated.lastDestinationID = id
        try persist(updated)
    }

    private func persist(_ updated: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        state = updated
    }
}
