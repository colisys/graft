import XCTest
@testable import GraftCore

final class SessionRegistryTests: XCTestCase {
    func testLiveMarkerSurvivesAge() throws {
        let file = try writeMarker(pid: getpid())
        defer { try? FileManager.default.removeItem(at: file) }

        let active = SessionRegistry.activeSessions()
        XCTAssertTrue(active.contains { $0.id == file.lastPathComponent })
    }

    func testDeadMarkerIsRemoved() throws {
        let file = try writeMarker(pid: 999_999)

        _ = SessionRegistry.activeSessions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private func writeMarker(pid: Int32) throws -> URL {
        SessionRegistry.prepare()
        let file = SessionRegistry.sessionsDirectory
            .appendingPathComponent("test-\(UUID().uuidString).session")
        let timestamp = Int(Date().timeIntervalSince1970) - 8 * 24 * 60 * 60
        try "\(pid)\t\(timestamp)\tOld\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
