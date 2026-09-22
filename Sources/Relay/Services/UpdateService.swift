import Foundation

/// A release published by the Relay GitHub repository.
public struct RelayAppUpdate: Identifiable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let releaseURL: URL
    public let downloadURL: URL
    public let assetName: String

    public init(version: String, releaseURL: URL, downloadURL: URL, assetName: String) {
        self.id = version
        self.version = version
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.assetName = assetName
    }
}

public enum RelayUpdateCheckResult: Sendable, Equatable {
    case upToDate(currentVersion: String)
    case available(RelayAppUpdate)
}

public enum UpdateServiceError: LocalizedError, Sendable {
    case invalidReleaseResponse
    case noMacOSArm64Asset
    case unsupportedDownloadURL
    case downloadDirectoryUnavailable
    case downloadFailed

    public var errorDescription: String? {
        switch self {
        case .invalidReleaseResponse:
            return "更新服务器返回的数据无效。"
        case .noMacOSArm64Asset:
            return "该版本没有可用的 macOS Apple Silicon 安装包。"
        case .unsupportedDownloadURL:
            return "更新下载地址不受信任，已停止下载。"
        case .downloadDirectoryUnavailable:
            return "无法找到 macOS 下载目录。"
        case .downloadFailed:
            return "更新包下载失败。"
        }
    }
}

/// Checks GitHub Releases and downloads the signed release archive without
/// changing the currently running app. The downloaded archive is intentionally
/// left for the user to install, because Relay releases are currently ad-hoc
/// signed and cannot safely replace a running app in place.
public struct UpdateService: Sendable {
    public static let repository = "DavisDing/Relay"
    public static let releasesAPIURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let currentVersionFallback = "0.1.0"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Self.currentVersionFallback
    }

    public func checkForUpdates() async throws -> RelayUpdateCheckResult {
        var request = URLRequest(url: Self.releasesAPIURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Relay/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateServiceError.invalidReleaseResponse
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let latestVersion = RelaySemanticVersion(release.tagName),
              let currentVersion = RelaySemanticVersion(currentVersionString),
              let releaseURL = URL(string: release.htmlURL) else {
            throw UpdateServiceError.invalidReleaseResponse
        }
        let supportedAssets = release.assets.filter { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix("macos-arm64.dmg") || name.hasSuffix("macos-arm64.zip")
        }
        let asset = supportedAssets.first(where: { $0.name.lowercased().hasSuffix("macos-arm64.dmg") })
            ?? supportedAssets.first
        guard let asset, let downloadURL = URL(string: asset.browserDownloadURL) else {
            throw UpdateServiceError.noMacOSArm64Asset
        }

        guard latestVersion > currentVersion else {
            return .upToDate(currentVersion: currentVersionString)
        }
        return .available(RelayAppUpdate(
            version: latestVersion.description,
            releaseURL: releaseURL,
            downloadURL: downloadURL,
            assetName: asset.name
        ))
    }

    /// Downloads an update atomically into ~/Downloads and returns its final URL.
    /// DMG is preferred by the release parser; ZIP remains a compatibility fallback.
    public func download(_ update: RelayAppUpdate) async throws -> URL {
        guard let host = update.downloadURL.host?.lowercased(),
              host == "github.com" || host == "objects.githubusercontent.com" else {
            throw UpdateServiceError.unsupportedDownloadURL
        }
        guard let downloadsDirectory = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            throw UpdateServiceError.downloadDirectoryUnavailable
        }

        let (temporaryURL, response) = try await session.download(from: update.downloadURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateServiceError.downloadFailed
        }

        try FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let destinationURL = uniqueDestinationURL(
            in: downloadsDirectory,
            preferredName: update.assetName
        )
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            throw UpdateServiceError.downloadFailed
        }
        return destinationURL
    }

    private func uniqueDestinationURL(in directory: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let sanitizedName = preferredName.isEmpty ? "Relay-update.zip" : (preferredName as NSString).lastPathComponent
        let initialURL = directory.appendingPathComponent(sanitizedName)
        guard fileManager.fileExists(atPath: initialURL.path) else { return initialURL }

        let base = initialURL.deletingPathExtension().lastPathComponent
        let ext = initialURL.pathExtension
        for index in 1...999 {
            let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("Relay-update-\(UUID().uuidString).zip")
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

private struct RelaySemanticVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first
        guard let value else { return nil }
        let parts = value.split(separator: ".")
        guard (1...3).contains(parts.count), parts.allSatisfy({ Int($0) != nil }) else { return nil }
        major = Int(parts[0])!
        minor = parts.count > 1 ? Int(parts[1])! : 0
        patch = parts.count > 2 ? Int(parts[2])! : 0
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
