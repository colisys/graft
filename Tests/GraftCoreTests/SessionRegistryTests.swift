import XCTest
@testable import GraftCore

final class SessionRegistryTests: XCTestCase {
    func testLiveMarkerSurvivesAge() throws {
        let file = try writeMarker(pid: getpid())
        defer { try? FileManager.default.removeItem(at: file) }

        let active = SessionRegistry.activeSessions()
        XCTAssertTrue(active.contains { $0.id == file.lastPathComponent })
    }

    func testMarkerCarriesContainerAndPIDFile() throws {
        let file = try writeMarker(
            pid: getpid(),
            container: "graft-runtime-debian",
            pidFile: "/tmp/graft-session-test-123.pid"
        )
        defer { try? FileManager.default.removeItem(at: file) }

        let session = SessionRegistry.activeSessions()
            .first { $0.id == file.lastPathComponent }
        XCTAssertEqual(session?.containerName, "graft-runtime-debian")
        XCTAssertEqual(session?.pidFile, "/tmp/graft-session-test-123.pid")
    }

    func testDeadMarkerIsReportedStaleAndRemoved() throws {
        let file = try writeMarker(
            pid: 999_999,
            container: "graft-runtime",
            pidFile: "/tmp/graft-session-dead.pid"
        )

        XCTAssertFalse(
            SessionRegistry.activeSessions().contains { $0.id == file.lastPathComponent }
        )
        let stale = SessionRegistry.takeStaleSessions()
        XCTAssertTrue(stale.contains { $0.id == file.lastPathComponent })
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private func writeMarker(
        pid: Int32,
        container: String = "graft-runtime",
        pidFile: String = "/tmp/graft-session.pid"
    ) throws -> URL {
        SessionRegistry.prepare()
        let file = SessionRegistry.sessionsDirectory
            .appendingPathComponent("test-\(UUID().uuidString).session")
        let timestamp = Int(Date().timeIntervalSince1970) - 8 * 24 * 60 * 60
        let contents = "\(pid)\t\(timestamp)\tOld\t\(container)\t\(pidFile)\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
