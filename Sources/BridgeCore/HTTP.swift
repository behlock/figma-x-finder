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
        guard let length = Int(headers["content-length"] ?? "0"), (0...16384).contains(length) else {
            throw BridgeError.message("Invalid content length.")
        }
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
        let reason = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 410: "Gone", 429: "Too Many Requests"][status] ?? "Error"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Allow-Private-Network: true\r\n\r\n"
        return Data(headers.utf8) + body
    }
}

public final class Router {
    private let store: Store
    private let now: () -> Date
    private var pairing: PairingSession?
    private var nextPairingAt = Date.distantPast
    public var onPairingRequest: ((PairingRequest) -> Void)?
    private var leases: [String: (receiver: String, expiry: Date)] = [:]
    private var failures: [String: (attempts: Int, retryAt: Date)] = [:]
    public init(store: Store, now: @escaping () -> Date = Date.init) { self.store = store; self.now = now }

    public func confirmPairing(_ id: String, allow: Bool) {
        guard pairing?.request.id == id, pairing!.expiry > now(), pairing!.approved == nil else { return }
        pairing?.approved = allow
    }

    private struct PairingSession {
        let request: PairingRequest
        let expiry: Date
        var approved: Bool?
    }

    private func handlePairing(_ request: HTTPRequest) throws -> HTTPResponse {
        guard request.method == "POST", request.headers["content-type"]?.lowercased() == "application/json" else {
            return HTTPResponse(status: 400)
        }
        switch request.url.path {
        case "/v1/pairing/start":
            guard let onPairingRequest else {
                return try .json(["error": "Open the Mac app to connect."], status: 409)
            }
            guard pairing == nil || pairing!.expiry <= now() else {
                return try .json(["error": "A connection request is already waiting. Approve it or wait two minutes before trying again."], status: 409)
            }
            guard now() >= nextPairingAt else {
                return try .json(["error": "Wait a moment before connecting again."], status: 429)
            }
            let request = PairingRequest(id: UUID().uuidString, code: String(format: "%06d", Int.random(in: 0...999999)))
            pairing = PairingSession(request: request, expiry: now().addingTimeInterval(120))
            nextPairingAt = now().addingTimeInterval(10)
            onPairingRequest(request)
            return try .json(request)
        case "/v1/pairing/status":
            struct Check: Decodable { let id: String }
            let check = try JSONDecoder().decode(Check.self, from: request.body)
            guard let session = pairing, session.request.id == check.id else { return HTTPResponse(status: 404) }
            guard session.expiry > now() else {
                pairing = nil
                return try .json(["error": "Connection request expired. Click Connect to try again."], status: 410)
            }
            guard let approved = session.approved else { return try .json(["state": "pending"], status: 202) }
            pairing = nil // The secret is released once, only to this request after local approval.
            guard approved else { return try .json(["error": "Connection cancelled. Click Connect to try again."], status: 403) }
            return try .json(["state": "connected", "token": store.token])
        default: return HTTPResponse(status: 404)
        }
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        if request.method == "OPTIONS" { return HTTPResponse(status: 204) }
        do {
            if request.url.path.hasPrefix("/v1/pairing/") { return try handlePairing(request) }
            guard request.headers["authorization"] == "Bearer " + store.token else { return HTTPResponse(status: 401) }
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
            switch (request.method, request.url.path) {
            case ("GET", "/v1/destinations"):
                return try .json(store.destinations)
            case ("POST", "/v1/destinations"):
                return try .json(store.save(JSONDecoder().decode(Destination.self, from: request.body)))
            case ("POST", "/v1/destinations/undo"):
                try store.undo(JSONDecoder().decode(DestinationChange.self, from: request.body))
                return HTTPResponse(status: 204)
            case ("GET", "/v1/jobs"):
                guard let key = value("fileKey"), let receiver = value("receiver"), receiver.count <= 100, !receiver.isEmpty else {
                    throw BridgeError.message("File and receiver are required.")
                }
                let time = now()
                let candidates = store.jobs.filter { job in
                    job.destination.fileKey == key && (failures[job.id].map { $0.retryAt <= time } ?? true)
                }
                // Fresh work takes priority over a repeatedly failing destination.
                guard let job = candidates.first(where: { $0.lastError == nil }) ?? candidates.first else {
                    return HTTPResponse(status: 204)
                }
                if let lease = leases[job.id], lease.receiver != receiver, lease.expiry > time {
                    return HTTPResponse(status: 204)
                }
                leases[job.id] = (receiver, now().addingTimeInterval(60))
                return try .json(job)
            case ("GET", "/v1/image"):
                guard let jobID = value("job"), let imageID = value("image"),
                      let receiver = value("receiver"), leases[jobID]?.receiver == receiver else { return HTTPResponse(status: 409) }
                leases[jobID] = (receiver, now().addingTimeInterval(60))
                return HTTPResponse(body: try store.imageData(jobID: jobID, imageID: imageID),
                                    contentType: try store.imageContentType(jobID: jobID, imageID: imageID))
            case ("POST", "/v1/lease"):
                let lease = try JSONDecoder().decode(DeliveryLease.self, from: request.body)
                guard leases[lease.jobID]?.receiver == lease.receiver,
                      store.jobs.contains(where: { $0.id == lease.jobID }) else { return HTTPResponse(status: 409) }
                leases[lease.jobID] = (lease.receiver, now().addingTimeInterval(60))
                return HTTPResponse(status: 204)
            case ("POST", "/v1/ack"):
                let ack = try JSONDecoder().decode(Acknowledgement.self, from: request.body)
                guard leases[ack.jobID]?.receiver == ack.receiver else { return HTTPResponse(status: 409) }
                try store.acknowledge(jobID: ack.jobID, imageID: ack.imageID)
                failures.removeValue(forKey: ack.jobID)
                if store.jobs.contains(where: { $0.id == ack.jobID }) {
                    leases[ack.jobID] = (ack.receiver, now().addingTimeInterval(60))
                } else { leases.removeValue(forKey: ack.jobID) }
                return HTTPResponse(status: 204)
            case ("POST", "/v1/error"):
                let error = try JSONDecoder().decode(DeliveryError.self, from: request.body)
                guard leases[error.jobID]?.receiver == error.receiver else { return HTTPResponse(status: 409) }
                try store.reportError(jobID: error.jobID, message: error.message)
                let attempts = min((failures[error.jobID]?.attempts ?? 0) + 1, 4)
                failures[error.jobID] = (attempts, now().addingTimeInterval(min(30, 5 * pow(2, Double(attempts - 1)))))
                return HTTPResponse(status: 204)
            default: return HTTPResponse(status: 404)
            }
        } catch { return (try? .json(["error": error.localizedDescription], status: 400)) ?? HTTPResponse(status: 400) }
    }

    private struct Acknowledgement: Decodable { let jobID: String; let imageID: String; let receiver: String }
    private struct DeliveryLease: Decodable { let jobID: String; let receiver: String }
    private struct DeliveryError: Decodable { let jobID: String; let message: String; let receiver: String }
}

public struct PairingRequest: Encodable {
    public let id: String
    public let code: String
}
