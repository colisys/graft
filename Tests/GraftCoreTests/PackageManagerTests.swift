import XCTest
@testable import GraftCore

final class PackageManagerInstallerTests: XCTestCase {
    private func makeTools(brew: Bool, port: Bool) -> ToolLocations {
        var tools = ToolLocations()
        if brew { tools.brew = "/opt/homebrew/bin/brew" }
        if port { tools.port = "/opt/local/bin/port" }
        return tools
    }

    func testAutomaticPrefersMacPorts() {
        let tools = makeTools(brew: true, port: true)
        XCTAssertEqual(
            PackageManagerInstaller.resolve(preference: .automatic, tools: tools),
            .macports
        )
    }

    func testAutomaticFallsBackToHomebrew() {
        let tools = makeTools(brew: true, port: false)
        XCTAssertEqual(
            PackageManagerInstaller.resolve(preference: .automatic, tools: tools),
            .homebrew
        )
    }

    func testExplicitSelectionRequiresTheTool() {
        XCTAssertNil(
            PackageManagerInstaller.resolve(
                preference: .macports,
                tools: makeTools(brew: true, port: false)
            )
        )
        XCTAssertNil(
            PackageManagerInstaller.resolve(
                preference: .homebrew,
                tools: makeTools(brew: false, port: true)
            )
        )
    }

    func testHomebrewColimaPlan() throws {
        let tools = makeTools(brew: true, port: false)
        let plan = PackageManagerInstaller.plan(for: .colima, manager: .homebrew, tools: tools)
        guard case .command(let executable, let arguments) = plan else {
            return XCTFail("Expected a direct command, got \(plan)")
        }
        XCTAssertEqual(executable, tools.brew)
        XCTAssertEqual(arguments, ["install", "colima"])
        XCTAssertFalse(plan.requiresAdministrator)
    }

    func testMacPortsColimaPlanIsPrivileged() {
        let tools = makeTools(brew: false, port: true)
        let plan = PackageManagerInstaller.plan(for: .colima, manager: .macports, tools: tools)
        guard case .privilegedShell(let command) = plan else {
            return XCTFail("Expected privileged shell, got \(plan)")
        }
        XCTAssertTrue(plan.requiresAdministrator)
        XCTAssertTrue(command.contains("export PATH="))
        XCTAssertTrue(command.contains("/opt/local/bin/port"))
        XCTAssertTrue(command.contains("install colima"))
    }

    func testXQuartzPlanUsesGitHubReleases() {
        for manager in [PackageManagerKind.homebrew, .macports] {
            let tools = manager == .homebrew
                ? makeTools(brew: true, port: false)
                : makeTools(brew: false, port: true)
            let plan = PackageManagerInstaller.plan(for: .xquartz, manager: manager, tools: tools)
            guard case .openURL(let url, _) = plan else {
                return XCTFail("Expected an URL plan, got \(plan)")
            }
            XCTAssertEqual(url, "https://github.com/XQuartz/XQuartz/releases")
        }
    }

    func testNoManagerAvailable() {
        let plan = PackageManagerInstaller.plan(
            for: .docker,
            manager: .automatic,
            tools: makeTools(brew: false, port: false)
        )
        guard case .unavailable = plan else {
            return XCTFail("Expected unavailable, got \(plan)")
        }
    }

    func testPackageManagerKindsHaveUniqueIDs() {
        let ids = PackageManagerKind.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
