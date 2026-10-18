import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct Destination: Codable, Equatable {
    public let id: String
    public var name: String
    public let fileKey: String
    public var pageID: String
    public let nodeID: String?

    public init(name: String, fileKey: String, pageID: String, nodeID: String?) {
        id = UUID().uuidString
        self.name = name
        self.fileKey = fileKey
        self.pageID = pageID
        self.nodeID = nodeID
    }

    private enum CodingKeys: String, CodingKey { case id, name, fileKey, pageID, nodeID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try values.decode(String.self, forKey: .name)
        fileKey = try values.decode(String.self, forKey: .fileKey)
        pageID = try values.decode(String.self, forKey: .pageID)
        nodeID = try values.decodeIfPresent(String.self, forKey: .nodeID)
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              fileKey.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              pageID.range(of: "^[0-9]+:[0-9]+$", options: .regularExpression) != nil,
              nodeID == nil || nodeID!.range(of: "^[0-9]+:[0-9]+$", options: .regularExpression) != nil
        else { throw BridgeError.message("Choose a valid Figma Design page or frame.") }
    }

    fileprivate func hasSameTarget(as other: Destination) -> Bool {
        fileKey == other.fileKey && nodeID == other.nodeID && (nodeID != nil || pageID == other.pageID)
    }
}

public enum BridgeError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

public struct DestinationChange: Codable {
    public let destination: Destination
    public let previousName: String?
}

public struct QueuedImage: Codable {
    public let id: String
    public let name: String
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
        var unique: [Destination] = []
        for destination in state.destinations {
            if let index = unique.firstIndex(where: { $0.hasSameTarget(as: destination) }) {
                unique[index].name = destination.name
                unique[index].pageID = destination.pageID
                if state.lastDestinationID == destination.id { state.lastDestinationID = unique[index].id }
            } else { unique.append(destination) }
        }
        state.destinations = unique
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try persist(state)
    }

    @discardableResult
    public func save(_ destination: Destination) throws -> DestinationChange {
        try destination.validate()
        var updated = state
        let index = updated.destinations.firstIndex(where: { $0.hasSameTarget(as: destination) })
        let previousName = index.map { updated.destinations[$0].name }
        if let index {
            updated.destinations[index].name = destination.name
            updated.destinations[index].pageID = destination.pageID
        } else {
            // Registration never accepts an externally supplied local ID.
            updated.destinations.append(Destination(name: destination.name, fileKey: destination.fileKey, pageID: destination.pageID, nodeID: destination.nodeID))
        }
        try persist(updated)
        return DestinationChange(destination: updated.destinations[index ?? (updated.destinations.count - 1)], previousName: previousName)
    }

    public func undo(_ change: DestinationChange) throws {
        guard let index = state.destinations.firstIndex(of: change.destination) else {
            throw BridgeError.message("This destination has changed. Save it again to continue.")
        }
        var updated = state
        if let name = change.previousName {
            updated.destinations[index].name = name
            try updated.destinations[index].validate()
        } else {
            updated.destinations.remove(at: index)
            if updated.lastDestinationID == change.destination.id { updated.lastDestinationID = nil }
        }
        try persist(updated)
    }

    public func enqueue(_ urls: [URL], destination: Destination) throws -> EnqueueResult {
        guard state.destinations.contains(destination) else {
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
                try prepareImage(url, to: folder.appendingPathComponent(imageID + ".png"))
                images.append(QueuedImage(id: imageID, name: url.lastPathComponent))
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

    private func prepareImage(_ url: URL, to output: URL) throws {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { throw BridgeError.message("Not a readable image.") }
        // Detailed photos can exceed the byte budget even within the pixel limit.
        // Re-render from the original at smaller sizes, retaining PNG transparency.
        for maxPixels in [4096, 3072, 2048, 1024] {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels
              ] as CFDictionary)
            else { throw BridgeError.message("Not a readable image.") }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw BridgeError.message("Couldn’t prepare this image.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw BridgeError.message("Couldn’t prepare this image.")
            }
            guard data.length <= 10 * 1024 * 1024 else { continue }
            try (data as Data).write(to: output, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            return
        }
        throw BridgeError.message("Couldn’t fit the prepared image within 10 MB.")
    }

    private func persist(_ updated: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        state = updated
    }
}
