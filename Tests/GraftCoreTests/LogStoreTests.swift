import Combine
import XCTest
@testable import GraftCore

final class LogStoreTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let writer = DispatchQueue(label: "test.log.writer")
    private var url: URL { directory.appendingPathComponent("test.log") }

    override func tearDownWithError() throws {
        writer.sync {}
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testBurstPublishesOneOrderedSuffixButPersistsAllLines() throws {
        let store = LogStore(maxEntries: 100, fileURL: url, fileQueue: writer)
        let published = expectation(description: "one batched publication")
        let lines = (0..<250).map { "line-\($0)" }
        let subscription = store.$entries.dropFirst().sink { entries in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(entries.map(\.text), Array(lines.suffix(100)))
            published.fulfill()
        }
        defer { subscription.cancel() }

        store.append(lines.prefix(210).joined(separator: "\n"))
        for line in lines.dropFirst(210) { store.append(line) }
        wait(for: [published], timeout: 3)
        writer.sync {}
        let disk = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(disk.map { String($0.components(separatedBy: "] [INFO] ").last!) }, lines)
    }

    @MainActor
    func testClearDropsPublishedAndPendingLinesWithoutClearingFile() throws {
        let store = LogStore(maxEntries: 100, fileURL: url, fileQueue: writer)
        func awaitBatch(_ expected: [String], perform: () -> Void) {
            let published = expectation(description: "publish \(expected)")
            let subscription = store.$entries.dropFirst().sink { entries in
                XCTAssertEqual(entries.map(\.text), expected)
                published.fulfill()
            }
            perform()
            wait(for: [published], timeout: 3)
            subscription.cancel()
        }

        awaitBatch(["visible"]) { store.append("visible") }
        awaitBatch(["after"]) {
            store.append("pending")
            store.clear()
            store.isRecording = false
            store.append("paused")
            store.isRecording = true
            store.append("  after \n \n", level: .warning)
        }
        awaitBatch([]) { store.clear() }
        writer.sync {}
        let disk = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(disk.map { String($0.drop(while: { $0 != "]" }).dropFirst(2)) },
                       ["[INFO] visible", "[INFO] pending", "[WARNING] after"])
    }
}
