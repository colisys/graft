import Foundation
import XCTest
@testable import GraftCore

final class LauncherHotStartTests: XCTestCase {
    func testRunningContainerSkipsRedundantStatePoll() throws {
        let calls = try launch(scenario: "running")
        XCTAssertEqual(calls.filter { $0 == "inspect graft-test" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "inspect -f {{.State.Running}} graft-test" }.count, 1)
        XCTAssertFalse(calls.contains { $0.hasPrefix("start ") || $0.hasPrefix("run ") })
        XCTAssertTrue(calls.contains { $0.hasPrefix("exec -d -u graft -e DISPLAY=host.docker.internal:0") })
    }

    func testStoppedContainerStillStartsAndPolls() throws {
        let calls = try launch(scenario: "stopped")
        XCTAssertTrue(calls.contains("start graft-test"))
        XCTAssertEqual(calls.filter { $0 == "inspect -f {{.State.Running}} graft-test" }.count, 2)
        XCTAssertTrue(calls.contains { $0.hasPrefix("exec -d ") })
    }

    func testMissingContainerStillCreatesAndPolls() throws {
        let calls = try launch(scenario: "missing")
        XCTAssertTrue(calls.contains("run -d --name graft-test image sleep infinity"))
        XCTAssertEqual(calls.filter { $0 == "inspect -f {{.State.Running}} graft-test" }.count, 1)
        XCTAssertTrue(calls.contains { $0.hasPrefix("exec -d ") })
    }

    private func launch(scenario: String) throws -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("graft-hot-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let callsURL = directory.appendingPathComponent("calls")
        let stateURL = directory.appendingPathComponent("started")
        let dockerURL = directory.appendingPathComponent("docker")
        let colimaURL = directory.appendingPathComponent("colima")
        let docker = """
        #!/bin/bash
        printf '%s\\n' "$*" >> \(ShellQuote.quote(callsURL.path))
        case "$1" in
          inspect)
            if [ "$2" = "-f" ]; then
              if [ \(ShellQuote.quote(scenario)) = running ] || [ -f \(ShellQuote.quote(stateURL.path)) ]; then
                echo true
              else
                echo false
              fi
            elif [ \(ShellQuote.quote(scenario)) = missing ] && [ ! -f \(ShellQuote.quote(stateURL.path)) ]; then
              exit 1
            fi
            ;;
          start|run) touch \(ShellQuote.quote(stateURL.path)) ;;
        esac
        """
        try docker.write(to: dockerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dockerURL.path)
        try "#!/bin/bash\nexit 0\n".write(to: colimaURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: colimaURL.path)

        var tools = ToolLocations()
        tools.docker = dockerURL.path
        tools.colima = colimaURL.path
        let configuration = LauncherConfiguration(
            tools: tools,
            colimaStartArguments: [],
            containerRunArguments: ["run", "-d", "--name", "graft-test", "image", "sleep", "infinity"],
            containerName: "graft-test",
            display: "host.docker.internal:0",
            launchTokens: ["dbus-run-session", "--", "app"],
            processName: "",
            xquartzAppPath: nil,
            sessionDirectory: directory.appendingPathComponent("sessions").path,
            logDirectory: directory.appendingPathComponent("logs").path
        )
        let entry = DesktopEntry(filePath: "/tmp/test.desktop", name: "Test", exec: "app")
        let scriptURL = directory.appendingPathComponent("launch.sh")
        try LauncherScriptBuilder.build(entry: entry, configuration: configuration, sessionID: "test")
            .write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let calls = try String(contentsOf: callsURL, encoding: .utf8)
        return calls.split(separator: "\n").map(String.init)
    }
}
