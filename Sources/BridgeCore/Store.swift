import Foundation

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
}

public final class Store {
    private struct State: Codable {
        var destinations: [Destination] = []
        var lastDestinationID: String?
    }

    public let directory: URL
    private var state: State
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    public var destinations: [Destination] { state.destinations }
    public var lastDestinationID: String? { state.lastDestinationID }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("state.json")
        state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
    }

    public func save(_ destination: Destination) throws {
        var updated = state
        if let index = updated.destinations.firstIndex(where: { $0.id == destination.id }) {
            updated.destinations[index] = destination
        } else {
            updated.destinations.append(destination)
        }
        try persist(updated)
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
