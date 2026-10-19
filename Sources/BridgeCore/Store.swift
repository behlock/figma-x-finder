import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct Destination: Codable, Equatable, Sendable {
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

public struct QueuedImage: Codable, Sendable {
    public let id: String
    public let name: String
    public let format: String?
    public let width: Int?
    public let height: Int?
    fileprivate var fileExtension: String { format == "jpeg" ? "jpg" : "png" }
    fileprivate var contentType: String { format == "jpeg" ? "image/jpeg" : "image/png" }
}

public struct Job: Codable, Sendable {
    public let id: String
    public let destination: Destination
    public let images: [QueuedImage]
    public var completed: Set<String> = []
    public var lastError: String?
}

public struct EnqueueResult: Sendable {
    public let job: Job
    public let skipped: [String]
}

public final class Store {
    public static let maximumImagesPerBatch = 100
    private static let preparationQueue = DispatchQueue(label: "figma-finder.image-preparation", qos: .userInitiated)
    private struct PreparedImage {
        let format: String
        let width: Int
        let height: Int
    }
    private struct State: Codable {
        var destinations: [Destination] = []
        var lastDestinationID: String?
        var token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var jobs: [Job] = []
    }

    public let directory: URL
    private var state: State
    private let encoder = JSONEncoder()
    private var preparations = 0
    public var isPreparingImages: Bool { preparations > 0 }
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
        try validateEnqueue(urls, destination: destination)
        return try commit(Self.prepare(urls, destination: destination, queueDirectory: queueDirectory))
    }

    // Only immutable input and an isolated job directory leave the main actor.
    // State is read and committed on the main actor, after preparation finishes.
    @MainActor
    public func enqueueInBackground(_ urls: [URL], destination: Destination) async throws -> EnqueueResult {
        try validateEnqueue(urls, destination: destination)
        preparations += 1
        defer { preparations -= 1 }
        let directory = queueDirectory
        let prepared: EnqueueResult = try await withCheckedThrowingContinuation { continuation in
            Self.preparationQueue.async {
                continuation.resume(with: Result { try Self.prepare(urls, destination: destination, queueDirectory: directory) })
            }
        }
        return try commit(prepared)
    }

    private func validateEnqueue(_ urls: [URL], destination: Destination) throws {
        guard state.destinations.contains(destination) else {
            throw BridgeError.message("This destination is no longer saved.")
        }
        guard !urls.isEmpty else { throw BridgeError.message("Choose images in Finder to send.") }
        guard urls.count <= Self.maximumImagesPerBatch else {
            throw BridgeError.message("Send up to \(Self.maximumImagesPerBatch) images at a time.")
        }
    }

    private static func prepare(_ urls: [URL], destination: Destination, queueDirectory: URL) throws -> EnqueueResult {
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
                let prepared = try autoreleasepool { try prepareImage(url, to: folder.appendingPathComponent(imageID)) }
                images.append(QueuedImage(id: imageID, name: url.lastPathComponent, format: prepared.format,
                                          width: prepared.width, height: prepared.height))
            } catch { skipped.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        guard !images.isEmpty else { throw BridgeError.message(skipped.joined(separator: "\n")) }
        let job = Job(id: id, destination: destination, images: images)
        committed = true
        return EnqueueResult(job: job, skipped: skipped)
    }

    private func commit(_ result: EnqueueResult) throws -> EnqueueResult {
        var committed = false
        defer {
            if !committed { try? FileManager.default.removeItem(at: queueDirectory.appendingPathComponent(result.job.id)) }
        }
        // A destination may be removed or renamed while preparation is running.
        guard state.destinations.contains(result.job.destination) else {
            throw BridgeError.message("This destination has changed. Choose it again to send.")
        }
        var updated = state
        updated.jobs.append(result.job)
        updated.lastDestinationID = result.job.destination.id
        try persist(updated)
        committed = true
        return result
    }

    public func imageData(jobID: String, imageID: String) throws -> Data {
        let image = try queuedImage(jobID: jobID, imageID: imageID)
        return try Data(contentsOf: queueDirectory.appendingPathComponent(jobID).appendingPathComponent(imageID + "." + image.fileExtension))
    }

    public func imageContentType(jobID: String, imageID: String) throws -> String {
        try queuedImage(jobID: jobID, imageID: imageID).contentType
    }

    private func queuedImage(jobID: String, imageID: String) throws -> QueuedImage {
        guard let job = state.jobs.first(where: { $0.id == jobID }),
              let image = job.images.first(where: { $0.id == imageID }), !job.completed.contains(imageID)
        else { throw BridgeError.message("Queued image not found.") }
        return image
    }

    public func acknowledge(jobID: String, imageID: String) throws {
        guard let index = state.jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard let image = state.jobs[index].images.first(where: { $0.id == imageID }) else {
            throw BridgeError.message("Queued image not found.")
        }
        guard !state.jobs[index].completed.contains(imageID) else { return }
        var updated = state
        updated.jobs[index].completed.insert(imageID)
        updated.jobs[index].lastError = nil
        let finished = updated.jobs[index].completed.count == updated.jobs[index].images.count
        if finished { updated.jobs.remove(at: index) }
        // Persist acknowledgement before deleting the local image.
        try persist(updated)
        let folder = queueDirectory.appendingPathComponent(jobID)
        try? FileManager.default.removeItem(at: finished ? folder : folder.appendingPathComponent(imageID + "." + image.fileExtension))
    }

    public func reportError(jobID: String, message: String) throws {
        guard let index = state.jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let message = String(message.prefix(500))
        guard state.jobs[index].lastError != message else { return }
        var updated = state
        updated.jobs[index].lastError = message
        try persist(updated)
    }

    private static func prepareImage(_ url: URL, to output: URL) throws -> PreparedImage {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw BridgeError.message("Not a readable image.") }
        let type = CGImageSourceGetType(source) as String?
        let jpeg = type == UTType.jpeg.identifier
        let format = jpeg ? "jpeg" : "png"
        let target = output.appendingPathExtension(jpeg ? "jpg" : "png")
        let byteLimit = 10 * 1024 * 1024
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // Keep already compatible images byte-for-byte, including transparency.
        // Animated images still use only their first frame, as before.
        if (jpeg || type == UTType.png.identifier), max(width, height) <= 4096,
           orientation == 1, CGImageSourceGetCount(source) == 1,
           (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= byteLimit {
            try FileManager.default.copyItem(at: url, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return PreparedImage(format: format, width: width, height: height)
        }
        // Do not encode the same dimensions repeatedly for inputs under 4096px.
        let firstSize = min(4096, max(width, height))
        for maxPixels in [firstSize] + [3072, 2048, 1024].filter({ $0 < firstSize }) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels
              ] as CFDictionary)
            else { throw BridgeError.message("Not a readable image.") }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else {
                throw BridgeError.message("Couldn’t prepare this image.")
            }
            let options = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil
            CGImageDestinationAddImage(destination, image, options)
            guard CGImageDestinationFinalize(destination) else {
                throw BridgeError.message("Couldn’t prepare this image.")
            }
            guard data.length <= byteLimit else { continue }
            try (data as Data).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return PreparedImage(format: format, width: image.width, height: image.height)
        }
        throw BridgeError.message("Couldn’t fit the prepared image within 10 MB.")
    }

    private func persist(_ updated: State) throws {
        try encoder.encode(updated).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        state = updated
    }
}
