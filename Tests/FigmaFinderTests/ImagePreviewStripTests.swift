import AppKit
import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import FigmaFinder

final class ImagePreviewStripTests: XCTestCase {
    @MainActor
    func testThumbnailsAreDeliveredOnMainActorAndRefreshedAfterChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.png")
        func writeImage(width: Int, height: Int) throws {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        func load() async -> CGImage? {
            await withCheckedContinuation { continuation in
                ImageThumbnailLoader.load(url) { image in
                    XCTAssertTrue(Thread.isMainThread)
                    continuation.resume(returning: image)
                }
            }
        }
        try writeImage(width: 20, height: 10)
        let firstResult = await load()
        let first = try XCTUnwrap(firstResult)
        let cachedResult = await load()
        let cached = try XCTUnwrap(cachedResult)
        // NSCache may evict at any time; both cache hits and misses must return
        // the right image, and an edited file must never reuse stale pixels.
        XCTAssertEqual(first.width, cached.width)
        XCTAssertEqual(first.height, cached.height)
        try writeImage(width: 10, height: 40)
        let changedResult = await load()
        let changed = try XCTUnwrap(changedResult)
        XCTAssertEqual(changed.width, 10)
        XCTAssertEqual(changed.height, 40)
    }

    @MainActor
    func testClickedImageStaysVisibleWhenResizingScrolledPreviews() async throws {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 400))
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let strip = ImagePreviewStrip(urls: (0..<8).map { URL(fileURLWithPath: "/image-\($0).png") })
        strip.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            strip.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(strip.subviews.first as? NSScrollView)
        let row = try XCTUnwrap(scroll.documentView as? NSStackView)

        for index in [2, 7, 4, 0] {
            let tile = row.arrangedSubviews[index]
            let button = try XCTUnwrap(tile.subviews.first as? NSButton)
            tile.scrollToVisible(tile.bounds)
            for size: CGFloat in [192, 96] {
                strip.onSizeChange = {
                    // Resizing the window can display intermediate frames immediately.
                    XCTAssertEqual(tile.frame.width, size)
                    XCTAssertTrue(scroll.documentVisibleRect.contains(tile.frame), "Clicked image \(index) must be visible before the window resize starts")
                    let offset = scroll.contentView.bounds.origin
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(scroll.contentView.bounds.origin, offset, "Window layout must not correct the preview scroll position")
                }
                button.performClick(nil)
                XCTAssertEqual(tile.frame.width, size)
                XCTAssertTrue(scroll.documentVisibleRect.contains(tile.frame), "Clicked image \(index) left the viewport")
            }
        }
    }
}
