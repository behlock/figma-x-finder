import Foundation

public struct HTTPRequest {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data

    public static func parse(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= 32768 else { throw BridgeError.message("Request too large.") }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard separator.lowerBound <= 8192, let text = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            throw BridgeError.message("Invalid headers.")
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[1].hasPrefix("/"), first[2] == "HTTP/1.1",
              let url = URL(string: "http://127.0.0.1" + first[1]) else {
            throw BridgeError.message("Invalid request.")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw BridgeError.message("Invalid header.") }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw BridgeError.message("Duplicate header.") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw BridgeError.message("Chunked requests are not supported.") }
        let length: Int
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0, value <= 16384 else { throw BridgeError.message("Invalid content length.") }
            length = value
        } else { length = 0 }
        guard data.count >= separator.upperBound + length else { return nil }
        return HTTPRequest(method: String(first[0]), url: url, headers: headers,
                           body: data.subdata(in: separator.upperBound..<(separator.upperBound + length)))
    }
}

public struct HTTPResponse {
    public let status: Int
    public let body: Data
    public let contentType: String

    public init(status: Int = 200, body: Data = Data(), contentType: String = "application/json") {
        self.status = status; self.body = body; self.contentType = contentType
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(status: status, body: try JSONEncoder().encode(value))
    }

    public var bytes: Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict"][status] ?? "Error"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Allow-Private-Network: true\r\n\r\n"
        return Data(headers.utf8) + body
    }
}

public final class Router {
    private let store: Store
    private var leases: [String: (receiver: String, expiry: Date)] = [:]
    public init(store: Store) { self.store = store }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        if request.method == "OPTIONS" { return HTTPResponse(status: 204) }
        guard request.headers["authorization"] == "Bearer " + store.token else {
            return HTTPResponse(status: 401)
        }
        do {
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
            switch (request.method, request.url.path) {
            case ("GET", "/v1/destinations"):
                return try .json(store.destinations)
            case ("POST", "/v1/destinations"):
                try store.save(JSONDecoder().decode(Destination.self, from: request.body))
                return try .json(store.destinations)
            case ("GET", "/v1/jobs"):
                guard let key = value("fileKey"), let receiver = value("receiver"), receiver.count <= 100, !receiver.isEmpty else {
                    throw BridgeError.message("File and receiver are required.")
                }
                guard let job = store.jobs.first(where: { $0.destination.fileKey == key }) else { return HTTPResponse(status: 204) }
                if let lease = leases[job.id], lease.receiver != receiver, lease.expiry > Date() {
                    return HTTPResponse(status: 204)
                }
                leases[job.id] = (receiver, Date().addingTimeInterval(60))
                return try .json(job)
            case ("GET", "/v1/image"):
                guard let jobID = value("job"), let imageID = value("image"),
                      let receiver = value("receiver"), leases[jobID]?.receiver == receiver else { return HTTPResponse(status: 409) }
                leases[jobID] = (receiver, Date().addingTimeInterval(60))
                return HTTPResponse(body: try store.imageData(jobID: jobID, imageID: imageID), contentType: "image/png")
            case ("POST", "/v1/ack"):
                let ack = try JSONDecoder().decode(Acknowledgement.self, from: request.body)
                guard leases[ack.jobID]?.receiver == ack.receiver else { return HTTPResponse(status: 409) }
                try store.acknowledge(jobID: ack.jobID, imageID: ack.imageID)
                return HTTPResponse(status: 204)
            case ("POST", "/v1/error"):
                let error = try JSONDecoder().decode(DeliveryError.self, from: request.body)
                guard leases[error.jobID]?.receiver == error.receiver else { return HTTPResponse(status: 409) }
                try store.reportError(jobID: error.jobID, message: error.message)
                return HTTPResponse(status: 204)
            default: return HTTPResponse(status: 404)
            }
        } catch { return (try? .json(["error": error.localizedDescription], status: 400)) ?? HTTPResponse(status: 400) }
    }

    private struct Acknowledgement: Decodable { let jobID: String; let imageID: String; let receiver: String }
    private struct DeliveryError: Decodable { let jobID: String; let message: String; let receiver: String }
}
