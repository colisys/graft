import Foundation

/// Resolves and locates the official XQuartz `.pkg` published on GitHub.
///
/// Graft never bundles XQuartz. The package is downloaded directly from the
/// XQuartz GitHub release after the user accepts the license notice, then
/// installed with the system `installer` tool.
public enum XQuartzInstaller {
    public static let releasesAPI = URL(string: "https://api.github.com/repos/XQuartz/XQuartz/releases/latest")!

    /// Used when the GitHub API is rate limited or offline. The API is the
    /// primary source so newer releases are picked up automatically.
    public static let fallbackPackageURL = URL(
        string: "https://github.com/XQuartz/XQuartz/releases/download/XQuartz-2.8.6/XQuartz-2.8.6.pkg"
    )!

    /// Extracts the first `.pkg` asset from a GitHub release JSON payload.
    public static func packageURL(fromReleaseJSON data: Data) -> URL? {
        struct Release: Decodable {
            let assets: [Asset]
        }
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return nil
        }
        return release.assets
            .first { $0.name.lowercased().hasSuffix(".pkg") }?
            .browserDownloadURL
    }

    public static func latestPackageURL() async -> URL {
        var request = URLRequest(url: releasesAPI)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Graft/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return fallbackPackageURL
            }
            return packageURL(fromReleaseJSON: data) ?? fallbackPackageURL
        } catch {
            return fallbackPackageURL
        }
    }

    /// Downloads land in ~/Downloads so the user can inspect or reinstall the
    /// package manually. Falls back to the temporary directory when Downloads
    /// is unavailable.
    public static func destinationURL(for packageURL: URL) -> URL {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let filename = packageURL.lastPathComponent.isEmpty
            ? "XQuartz.pkg"
            : packageURL.lastPathComponent
        return directory.appendingPathComponent(filename)
    }
}
