import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import BridgeCore

final class BridgeCoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func image(name: String = "reference image 日本.png", width: Int = 20, height: Int = 10, noisy: Bool = false) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if noisy {
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            var seed: UInt32 = 12345
            for offset in stride(from: 0, to: width * height * 4, by: 4) {
                seed ^= seed << 13
                seed ^= seed >> 17
                seed ^= seed << 5
                pixels[offset] = UInt8(truncatingIfNeeded: seed)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: seed >> 8)
                pixels[offset + 2] = UInt8(truncatingIfNeeded: seed >> 16)
                pixels[offset + 3] = 255
            }
        }
        let url = directory.appendingPathComponent(name)
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return url
    }

    private func store() throws -> Store {
        let store = try Store(directory: directory.appendingPathComponent("data"))
        try store.save(Destination(name: "Inspiration", fileKey: "file123", pageID: "0:1", nodeID: "1:2"))
        return store
    }

    func testQueueSurvivesRestartAndOriginalDeletion() throws {
        let store = try store()
        let original = try image()
        let result = try store.enqueue([original], destination: store.destinations[0])
        try FileManager.default.removeItem(at: original)
        let reopened = try Store(directory: store.directory)
        XCTAssertEqual(reopened.token, store.token)
        XCTAssertEqual(reopened.lastDestinationID, store.destinations[0].id)
        let bytes = try reopened.imageData(jobID: result.job.id, imageID: result.job.images[0].id)
        XCTAssertNotNil(CGImageSourceCreateWithData(bytes as CFData, nil))
        XCTAssertEqual(result.job.images[0].name, "reference image 日本.png")
    }

    func testLegacyImageMetadataRemainsReadable() throws {
        let data = Data(#"{"id":"image1","name":"reference.png","width":20,"height":10}"#.utf8)
        let image = try JSONDecoder().decode(QueuedImage.self, from: data)
        XCTAssertEqual(image.id, "image1")
        XCTAssertEqual(image.name, "reference.png")
    }

    func testAcknowledgementIsPersistentAndIdempotent() throws {
        let store = try store()
        let result = try store.enqueue([try image(), try image(name: "second.png")], destination: store.destinations[0])
        let first = result.job.images[0].id
        try store.acknowledge(jobID: result.job.id, imageID: first)
        try store.acknowledge(jobID: result.job.id, imageID: first)
        let reopened = try Store(directory: store.directory)
        XCTAssertEqual(reopened.jobs[0].completed, [first])
        XCTAssertThrowsError(try reopened.imageData(jobID: result.job.id, imageID: "../../state"))
        try reopened.acknowledge(jobID: result.job.id, imageID: result.job.images[1].id)
        XCTAssertTrue(reopened.jobs.isEmpty)
    }

    func testPartialSelectionAndOversizedImage() throws {
        let store = try store()
        let large = try image(width: 5000, height: 20)
        let result = try store.enqueue([large, directory.appendingPathComponent("missing.txt")], destination: store.destinations[0])
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.job.images.count, 1)
        let bytes = try store.imageData(jobID: result.job.id, imageID: result.job.images[0].id)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 4096)
    }

    func testRegistrationKeepsIdentityOnRename() throws {
        let store = try store()
        let id = store.destinations[0].id
        try store.save(Destination(name: "Renamed", fileKey: "file123", pageID: "0:1", nodeID: "1:2"))
        XCTAssertEqual(store.destinations.count, 1)
        XCTAssertEqual(store.destinations[0].id, id)
        XCTAssertThrowsError(try store.save(Destination(name: "Bad", fileKey: "../bad", pageID: "0:1", nodeID: nil)))
    }

    func testDetailedImageIsResizedToFitByteBudgetWithoutChangingOriginal() throws {
        let store = try store()
        let original = try image(width: 2400, height: 2400, noisy: true)
        let originalBytes = try Data(contentsOf: original)
        XCTAssertGreaterThan(originalBytes.count, 10 * 1024 * 1024)
        let result = try store.enqueue([original], destination: store.destinations[0])
        let image = try XCTUnwrap(result.job.images.first)
        let bytes = try store.imageData(jobID: result.job.id, imageID: image.id)
        XCTAssertLessThanOrEqual(bytes.count, 10 * 1024 * 1024)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, decoded.height)
        XCTAssertLessThan(decoded.width, 2400)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    func testHTTPRequiresTokenAndReassemblesPartialBody() throws {
        let store = try store()
        let router = Router(store: store)
        let unauthenticated = try XCTUnwrap(HTTPRequest.parse(Data("GET /v1/destinations HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)))
        XCTAssertEqual(router.handle(unauthenticated).status, 401)
        let partial = Data("POST /v1/destinations HTTP/1.1\r\nContent-Length: 2\r\n\r\n{".utf8)
        XCTAssertNil(try HTTPRequest.parse(partial))
        XCTAssertEqual(try HTTPRequest.parse(partial + Data("}".utf8))?.body, Data("{}".utf8))
        let valid = try XCTUnwrap(HTTPRequest.parse(Data("GET /v1/destinations HTTP/1.1\r\nAuthorization: Bearer \(store.token)\r\n\r\n".utf8)))
        XCTAssertEqual(router.handle(valid).status, 200)
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)))
    }

    private func pairingRequest(_ path: String, id: String? = nil) throws -> HTTPRequest {
        HTTPRequest(method: "POST", url: URL(string: "http://localhost" + path)!,
                    headers: ["content-type": "application/json"],
                    body: try JSONEncoder().encode(id.map { ["id": $0] } ?? [:]))
    }

    func testPairingReleasesCredentialOnceAfterMatchingLocalApproval() throws {
        let store = try store()
        let router = Router(store: store)
        var prompt: PairingRequest?
        router.onPairingRequest = { prompt = $0 }
        let start = router.handle(try pairingRequest("/v1/pairing/start"))
        XCTAssertEqual(start.status, 200)
        let request = try XCTUnwrap(prompt)
        XCTAssertEqual(request.code.count, 6)
        XCTAssertFalse(String(decoding: start.body, as: UTF8.self).contains(store.token))
        XCTAssertEqual(router.handle(try pairingRequest("/v1/pairing/start")).status, 409)
        XCTAssertEqual(router.handle(try pairingRequest("/v1/pairing/status", id: "wrong")).status, 404)
        router.confirmPairing("wrong", allow: true)
        let check = try pairingRequest("/v1/pairing/status", id: request.id)
        let pending = router.handle(check)
        XCTAssertEqual(pending.status, 202)
        XCTAssertFalse(String(decoding: pending.body, as: UTF8.self).contains(store.token))
        router.confirmPairing(request.id, allow: true)
        let connected = router.handle(check)
        XCTAssertEqual(connected.status, 200)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: connected.body)["token"], store.token)
        XCTAssertEqual(router.handle(check).status, 404)
        // Approval never makes the image/destination API public.
        let unauthenticated = HTTPRequest(method: "GET", url: URL(string: "http://localhost/v1/destinations")!, headers: [:], body: Data())
        XCTAssertEqual(router.handle(unauthenticated).status, 401)
    }

    func testPairingDenialExpiryAndInvalidRequestsNeverReleaseCredential() throws {
        let store = try store()
        var time = Date()
        let router = Router(store: store, now: { time })
        var prompt: PairingRequest?
        router.onPairingRequest = { prompt = $0 }
        let invalid = HTTPRequest(method: "POST", url: URL(string: "http://localhost/v1/pairing/start")!, headers: [:], body: Data())
        XCTAssertEqual(router.handle(invalid).status, 400)
        XCTAssertNil(prompt)
        _ = router.handle(try pairingRequest("/v1/pairing/start"))
        let first = try XCTUnwrap(prompt)
        router.confirmPairing(first.id, allow: false)
        router.confirmPairing(first.id, allow: true) // A denial cannot be overwritten.
        let denied = router.handle(try pairingRequest("/v1/pairing/status", id: first.id))
        XCTAssertEqual(denied.status, 403)
        XCTAssertFalse(String(decoding: denied.body, as: UTF8.self).contains(store.token))
        XCTAssertEqual(router.handle(try pairingRequest("/v1/pairing/start")).status, 429)
        time.addTimeInterval(11)
        XCTAssertEqual(router.handle(try pairingRequest("/v1/pairing/start")).status, 200)
        let second = try XCTUnwrap(prompt)
        XCTAssertNotEqual(first.id, second.id)
        time.addTimeInterval(121)
        router.confirmPairing(second.id, allow: true)
        let expired = router.handle(try pairingRequest("/v1/pairing/status", id: second.id))
        XCTAssertEqual(expired.status, 410)
        XCTAssertFalse(String(decoding: expired.body, as: UTF8.self).contains(store.token))
        XCTAssertEqual(router.handle(try pairingRequest("/v1/pairing/start")).status, 200)
        XCTAssertEqual(store.destinations.count, 1)
        XCTAssertEqual(try Store(directory: store.directory).token, store.token)
    }
}
