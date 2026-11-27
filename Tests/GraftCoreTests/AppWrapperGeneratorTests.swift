import XCTest
@testable import GraftCore

@MainActor
final class AppWrapperGeneratorTests: XCTestCase {
    func testUpgradeLauncherScriptRewritesLegacyScriptOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraftUpgrade-\(UUID().uuidString).app", isDirectory: true)
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = resources.appendingPathComponent("launch.sh")
        try """
        #!/bin/bash
        echo legacy launcher
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        let generator = AppWrapperGenerator(log: LogStore())
        let entry = DesktopEntry(filePath: "/tmp/x.desktop", name: "X", exec: "app")
        var tools = ToolLocations()
        tools.docker = "/usr/local/bin/docker"
        tools.colima = "/usr/local/bin/colima"
        let configuration = LauncherConfiguration(
            tools: tools,
            colimaStartArguments: [],
            containerRunArguments: ["run", "-d", "--name", "graft-runtime", "image", "sleep", "infinity"],
            containerName: "graft-runtime",
            display: GraftConstants.display,
            launchTokens: ["app"],
            processName: "app",
            xquartzAppPath: nil,
            sessionDirectory: "/tmp/sessions",
            logDirectory: "/tmp/logs"
        )

        XCTAssertTrue(
            generator.upgradeLauncherScript(at: root, entry: entry, configuration: configuration)
        )
        let updated = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("GRAFT_PID_FILE"))
        XCTAssertTrue(updated.contains("exec -u graft"))
        XCTAssertFalse(updated.contains("legacy launcher"))

        XCTAssertFalse(
            generator.upgradeLauncherScript(at: root, entry: entry, configuration: configuration)
        )
    }

    func testUpgradeLauncherScriptAppliesChangedConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraftUpgradeSettings-\(UUID().uuidString).app", isDirectory: true)
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = resources.appendingPathComponent("launch.sh")
        try """
        #!/bin/bash
        echo legacy launcher
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        let generator = AppWrapperGenerator(log: LogStore())
        let entry = DesktopEntry(filePath: "/tmp/x.desktop", name: "X", exec: "app")
        var tools = ToolLocations()
        tools.docker = "/usr/local/bin/docker"
        tools.colima = "/usr/local/bin/colima"
        var configuration = LauncherConfiguration(
            tools: tools,
            colimaStartArguments: [],
            containerRunArguments: ["run", "-d", "--name", "graft-runtime", "image", "sleep", "infinity"],
            containerName: "graft-runtime",
            display: GraftConstants.display,
            launchTokens: ["app"],
            processName: "app",
            xquartzAppPath: nil,
            sessionDirectory: "/tmp/sessions",
            logDirectory: "/tmp/logs"
        )

        XCTAssertTrue(
            generator.upgradeLauncherScript(at: root, entry: entry, configuration: configuration)
        )
        configuration.launchTokens = ["app", "--disable-gpu"]
        configuration.maxRefreshRate = 60
        XCTAssertTrue(
            generator.upgradeLauncherScript(at: root, entry: entry, configuration: configuration)
        )
        let updated = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("--disable-gpu"))
        XCTAssertTrue(updated.contains("MAX_REFRESH=60"))
        XCTAssertFalse(
            generator.upgradeLauncherScript(at: root, entry: entry, configuration: configuration)
        )
    }

}
