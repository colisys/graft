import XCTest
@testable import GraftWayland

private final class CapturingDelegate: WaylandCompositorDelegate {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private(set) var pixels: Data?
    private(set) var width = 0
    private(set) var height = 0
    private(set) var stride = 0
    private(set) var title: String?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func compositor(
        _ compositor: WaylandCompositor,
        didUpdateSurface surfaceID: UInt32,
        pixels: Data,
        width: Int,
        height: Int,
        stride: Int,
        title: String?
    ) {
        lock.lock()
        self.pixels = pixels
        self.width = width
        self.height = height
        self.stride = stride
        self.title = title
        lock.unlock()
        expectation.fulfill()
    }
}

final class WaylandCompositorTests: XCTestCase {
    func testDisplaysSharedMemorySurfaceFromWaylandClient() throws {
        let socketPath = "/tmp/graft-wayland-test-\(UUID().uuidString.prefix(8)).sock"
        let compositor = WaylandCompositor(socketPath: socketPath)
        let expectation = expectation(description: "Wayland surface received")
        let delegate = CapturingDelegate(expectation: expectation)
        compositor.delegate = delegate
        try compositor.start()
        defer {
            compositor.stop()
            unlink(socketPath)
        }

        let session = try WaylandDemoClient.sendTestPattern(
            socketPath: socketPath,
            width: 4,
            height: 4
        )
        defer { session.close() }

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(delegate.width, 4)
        XCTAssertEqual(delegate.height, 4)
        XCTAssertEqual(delegate.stride, 16)
        XCTAssertEqual(delegate.title, "Graft Wayland Surface")
        XCTAssertEqual(delegate.pixels?.count, 4 * 4 * 4)
        let pixels = try XCTUnwrap(delegate.pixels)
        XCTAssertEqual(pixels[pixels.startIndex], 0) // B
        XCTAssertEqual(pixels[pixels.startIndex + 1], 0) // G
        XCTAssertEqual(pixels[pixels.startIndex + 2], 96) // R
        XCTAssertEqual(pixels[pixels.startIndex + 3], 255) // A
    }
}
