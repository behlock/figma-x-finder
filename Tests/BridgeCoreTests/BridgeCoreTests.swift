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

    private func image(name: String = "reference image 日本.png", width: Int = 20, height: Int = 10) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
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
        XCTAssertEqual(result.job.images[0].width, 4096)
    }

    func testRegistrationKeepsIdentityOnRename() throws {
        let store = try store()
        let id = store.destinations[0].id
        try store.save(Destination(name: "Renamed", fileKey: "file123", pageID: "0:1", nodeID: "1:2"))
        XCTAssertEqual(store.destinations.count, 1)
        XCTAssertEqual(store.destinations[0].id, id)
        XCTAssertThrowsError(try store.save(Destination(name: "Bad", fileKey: "../bad", pageID: "0:1", nodeID: nil)))
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
}
