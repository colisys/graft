import Foundation
import XCTest
@testable import GraftCore

final class SourceInstallCommandTests: XCTestCase {
    func testWrapperKeepsCommandAndAddsNonInteractiveSettings() {
        let wrapped = SourceInstallCommand.nonInteractiveScript(
            for: "sudo pacman -Sy chromium"
        )
        XCTAssertTrue(wrapped.contains("yes | bash -lc"))
        XCTAssertTrue(wrapped.contains("DEBIAN_FRONTEND=noninteractive"))
        XCTAssertTrue(wrapped.contains("sudo pacman -Sy chromium"))
    }

    func testWrapperAnswersConfirmationPrompt() throws {
        let wrapped = SourceInstallCommand.nonInteractiveScript(
            for: #"read -p "Proceed with installation? [Y/n] " answer; echo "answer=$answer""#
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", wrapped]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("answer=y"), output)
    }
}
