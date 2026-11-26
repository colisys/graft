import XCTest
@testable import GraftCore

final class XQuartzInstallerTests: XCTestCase {
    func testExtractsPackageAssetFromReleaseJSON() {
        let json = """
        {
          "assets": [
            {"name": "XQuartz-2.8.6.dSYMS.tar.bz2", "browser_download_url": "https://example.com/dsyms"},
            {"name": "XQuartz-2.8.6.pkg", "browser_download_url": "https://example.com/XQuartz-2.8.6.pkg"}
          ]
        }
        """
        let url = XQuartzInstaller.packageURL(fromReleaseJSON: Data(json.utf8))
        XCTAssertEqual(url?.absoluteString, "https://example.com/XQuartz-2.8.6.pkg")
    }

    func testRejectsReleaseWithoutPackage() {
        let json = """
        {"assets": [{"name": "source.tar.gz", "browser_download_url": "https://example.com/source.tar.gz"}]}
        """
        XCTAssertNil(XQuartzInstaller.packageURL(fromReleaseJSON: Data(json.utf8)))
    }

    func testDestinationKeepsPackageFilename() {
        let url = URL(string: "https://github.com/XQuartz/XQuartz/releases/download/XQuartz-2.8.6/XQuartz-2.8.6.pkg")!
        let destination = XQuartzInstaller.destinationURL(for: url)
        XCTAssertEqual(destination.lastPathComponent, "XQuartz-2.8.6.pkg")
        XCTAssertEqual(destination.pathExtension, "pkg")
    }

    func testFallbackIsGitHubPackage() {
        XCTAssertEqual(XQuartzInstaller.fallbackPackageURL.pathExtension, "pkg")
        XCTAssertTrue(XQuartzInstaller.fallbackPackageURL.absoluteString.contains("github.com/XQuartz/XQuartz"))
    }
}
