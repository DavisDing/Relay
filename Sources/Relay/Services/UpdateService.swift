import Foundation
import Combine
import CryptoKit

/// A release published by the Relay GitHub repository.
public struct RelayAppUpdate: Identifiable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let releaseURL: URL
    public let downloadURL: URL
    public let assetName: String
    public let releaseTag: String

    public init(version: String, releaseURL: URL, downloadURL: URL, assetName: String, releaseTag: String? = nil) {
        self.id = version
        self.version = version
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.assetName = assetName
        self.releaseTag = releaseTag ?? "v\(version)"
    }
}

public enum RelayUpdateCheckResult: Sendable, Equatable {
    case upToDate(currentVersion: String)
    case available(RelayAppUpdate)
}

public enum RelayUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case available(RelayAppUpdate)
    case failed(message: String)

    public var availableUpdate: RelayAppUpdate? {
        guard case .available(let update) = self else { return nil }
        return update
    }
}

/// Shared update state so the launch check and the Settings/About page show the
/// same result without issuing duplicate requests.
public final class RelayUpdateState: ObservableObject {
    @Published public private(set) var status: RelayUpdateStatus = .idle

    private let service: UpdateService

    public init(service: UpdateService = UpdateService()) {
        self.service = service
    }

    @MainActor
    @discardableResult
    public func checkForUpdates() async -> RelayUpdateCheckResult? {
        guard status != .checking else { return nil }
        status = .checking
        do {
            let result = try await service.checkForUpdates()
            switch result {
            case .upToDate(let currentVersion):
                status = .upToDate(currentVersion: currentVersion)
            case .available(let update):
                status = .available(update)
            }
            return result
        } catch {
            status = .failed(message: error.localizedDescription)
            return nil
        }
    }

    @MainActor
    public func download(_ update: RelayAppUpdate) async throws -> URL {
        try await service.download(update)
    }
}

public enum UpdateServiceError: LocalizedError, Sendable, Equatable {
    case invalidReleaseResponse
    case noMacOSArm64Asset
    case unsupportedDownloadURL
    case downloadDirectoryUnavailable
    case downloadFailed
    case integrityUnavailable
    case integrityMismatch

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
        case .integrityUnavailable:
            return "该版本缺少有效的 SHA-256 校验信息，已停止下载。可前往发布页面手动安装。"
        case .integrityMismatch:
            return "更新包完整性校验失败，文件已丢弃。请稍后重试。"
        }
    }
}

/// Checks release metadata and verifies downloaded bytes before exposing a file.
/// Same-source unsigned SHA-256 detects corruption/mix-ups, NOT publisher identity.
/// Releases remain ad-hoc signed; installation is deliberately manual.
public struct UpdateService: Sendable {
    public static let repository = "DavisDing/Relay"
    public static let releasesAPIURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let currentVersionFallback = "0.1.0"

    private let session: URLSession
    private let downloadsDirectory: URL?

    // The directory override lets offline checks avoid the user's real Downloads.
    public init(session: URLSession = .shared, downloadsDirectory: URL? = nil) {
        self.session = session
        self.downloadsDirectory = downloadsDirectory
    }

    public var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Self.currentVersionFallback
    }

    public func checkForUpdates() async throws -> RelayUpdateCheckResult {
        let release = try await fetchRelease(at: Self.releasesAPIURL)
        guard let currentVersion = RelaySemanticVersion(currentVersionString),
              let latestVersion = RelaySemanticVersion(release.version) else {
            throw UpdateServiceError.invalidReleaseResponse
        }
        guard latestVersion > currentVersion else {
            return .upToDate(currentVersion: currentVersionString)
        }
        // Exact versioned filenames, not an arbitrary suffix from another release.
        let asset = release.assets.first { $0.name == "Relay-\(release.version)-macos-arm64.dmg" }
            ?? release.assets.first { $0.name == "Relay-\(release.version)-macos-arm64.zip" }
        guard let asset else { throw UpdateServiceError.noMacOSArm64Asset }
        let downloadURL = try release.assetURL(asset)
        return .available(RelayAppUpdate(
            version: release.version, releaseURL: release.releaseURL,
            downloadURL: downloadURL, assetName: asset.name, releaseTag: release.tagName
        ))
    }

    /// Downloads into a URLSession temporary file, verifies it, then moves it into
    /// Downloads without replacing an existing file. No extraction or app replacement.
    public func download(_ update: RelayAppUpdate) async throws -> URL {
        guard Self.version(for: update.releaseTag) == update.version,
              ["Relay-\(update.version)-macos-arm64.dmg", "Relay-\(update.version)-macos-arm64.zip"].contains(update.assetName),
              update.releaseURL == Self.releaseURL(tag: update.releaseTag),
              update.downloadURL == Self.assetURL(tag: update.releaseTag, name: update.assetName),
              Self.isSafeHTTPS(update.downloadURL) else {
            throw UpdateServiceError.unsupportedDownloadURL
        }
        // Do not trust a caller-provided hash, or stale latest-release metadata.
        // Re-resolve this exact tag, asset and browser URL on the fixed repository.
        let metadataURL = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/tags/\(update.releaseTag)")!
        let release = try await fetchRelease(at: metadataURL)
        guard release.tagName == update.releaseTag, release.releaseURL == update.releaseURL,
              let asset = release.assets.first(where: { $0.name == update.assetName }),
              try release.assetURL(asset) == update.downloadURL else {
            throw UpdateServiceError.invalidReleaseResponse
        }
        let expectedHash = try await expectedSHA256(for: asset, release: release)
        guard let directory = downloadsDirectory ?? FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first else { throw UpdateServiceError.downloadDirectoryUnavailable }

        let (temporaryURL, response) = try await session.download(
            for: request(update.downloadURL), delegate: UpdateRedirectPolicy(origin: update.downloadURL, allowsAssetCDN: true)
        )
        return try completeDownload(temporaryURL: temporaryURL, response: response, update: update,
                                    expectedHash: expectedHash, expectedSize: asset.size, directory: directory)
    }

    // Internal seam also lets offline checks assert cleanup of a known staging file.
    func completeDownload(temporaryURL: URL, response: URLResponse, update: RelayAppUpdate,
                          expectedHash: String, expectedSize: Int64?, directory: URL) throws -> URL {
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try validate(response, origin: update.downloadURL, allowsAssetCDN: true, error: .downloadFailed)
        if let size = expectedSize {
            let actualSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size >= 0, actualSize.map(Int64.init) == size else {
                throw UpdateServiceError.integrityMismatch
            }
        }
        guard try Self.sha256(file: temporaryURL) == expectedHash else {
            throw UpdateServiceError.integrityMismatch
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestinationURL(in: directory, preferredName: update.assetName)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw UpdateServiceError.downloadFailed
        }
        return destination
    }

    private func fetchRelease(at url: URL) async throws -> GitHubRelease {
        let (data, response) = try await session.data(
            for: request(url, accept: "application/vnd.github+json"),
            delegate: UpdateRedirectPolicy(origin: url, allowsAssetCDN: false)
        )
        try validate(response, origin: url, allowsAssetCDN: false, error: .invalidReleaseResponse)
        let release: GitHubRelease
        do { release = try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw UpdateServiceError.invalidReleaseResponse }
        guard Self.version(for: release.tagName) != nil,
              release.draft != true, release.prerelease != true,
              URL(string: release.htmlURL) == Self.releaseURL(tag: release.tagName),
              Set(release.assets.map(\.name)).count == release.assets.count else {
            throw UpdateServiceError.invalidReleaseResponse
        }
        return release
    }

    private func expectedSHA256(for asset: GitHubAsset, release: GitHubRelease) async throws -> String {
        if let digest = asset.digest {
            // A present but malformed digest is an error, not a reason to downgrade.
            guard digest.hasPrefix("sha256:"), let hash = Self.normalizedHash(String(digest.dropFirst(7))) else {
                throw UpdateServiceError.integrityUnavailable
            }
            return hash
        }
        let checksumName = "Relay-\(release.version)-sha256.txt"
        guard let checksums = release.assets.first(where: { $0.name == checksumName }) else {
            throw UpdateServiceError.integrityUnavailable
        }
        if let declaredSize = checksums.size, !(0...Int64(128 * 1024)).contains(declaredSize) {
            throw UpdateServiceError.integrityUnavailable
        }
        let url = try release.assetURL(checksums)
        let (temporaryURL, response) = try await session.download(
            for: request(url), delegate: UpdateRedirectPolicy(origin: url, allowsAssetCDN: true)
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try validate(response, origin: url, allowsAssetCDN: true, error: .downloadFailed)
        guard let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 128 * 1024 else { throw UpdateServiceError.integrityUnavailable }
        if let declaredSize = checksums.size, declaredSize != Int64(size) {
            throw UpdateServiceError.integrityMismatch
        }
        let data = try Data(contentsOf: temporaryURL)
        if let digest = checksums.digest {
            guard digest.hasPrefix("sha256:"), let hash = Self.normalizedHash(String(digest.dropFirst(7))) else {
                throw UpdateServiceError.integrityUnavailable
            }
            guard Self.hash(data) == hash else { throw UpdateServiceError.integrityMismatch }
        }
        return try Self.checksum(in: data, assetName: asset.name, version: release.version)
    }

    // Accept only the bounded shasum -a 256 format emitted by package-app.sh.
    // Reject paths, wrong versions, malformed lines and duplicates (even identical).
    static func checksum(in data: Data, assetName: String, version: String) throws -> String {
        guard data.count <= 128 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw UpdateServiceError.integrityUnavailable
        }
        let allowedNames = Set(["Relay-\(version)-macos-arm64.dmg", "Relay-\(version)-macos-arm64.zip"])
        var hashes: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard line.count > 66 else { throw UpdateServiceError.integrityUnavailable }
            let hashText = String(line.prefix(64))
            let separator = String(line.dropFirst(64).prefix(2))
            let name = String(line.dropFirst(66))
            guard let hash = normalizedHash(hashText), separator == "  " || separator == " *",
                  allowedNames.contains(name), hashes[name] == nil else {
                throw UpdateServiceError.integrityUnavailable
            }
            hashes[name] = hash
        }
        guard let hash = hashes[assetName] else { throw UpdateServiceError.integrityUnavailable }
        return hash
    }

    private static func normalizedHash(_ value: String) -> String? {
        guard value.utf8.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return value.lowercased()
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func request(_ url: URL, accept: String = "application/octet-stream") -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Relay/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validate(_ response: URLResponse, origin: URL, allowsAssetCDN: Bool, error: UpdateServiceError) throws {
        guard let finalURL = response.url,
              Self.isAllowedDestination(finalURL, origin: origin, allowsAssetCDN: allowsAssetCDN) else {
            throw UpdateServiceError.unsupportedDownloadURL
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw error }
    }

    static func isSafeHTTPS(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.user == nil && parts.password == nil
            && (parts.port == nil || parts.port == 443) && parts.fragment == nil
    }

    // CDN repository identity is not encoded in its path; binding comes from the
    // validated origin/tag/asset metadata plus the verified digest, not the hostname.
    static func isAllowedDestination(_ url: URL, origin: URL, allowsAssetCDN: Bool) -> Bool {
        guard isSafeHTTPS(url) else { return false }
        if url == origin { return true }
        guard allowsAssetCDN, let host = url.host?.lowercased(),
              ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return url.path.hasPrefix("/github-production-release-asset/")
            || (host == "objects.githubusercontent.com"
                && url.path.hasPrefix("/github-production-release-asset-2e65be/"))
    }

    private static func version(for tag: String) -> String? {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard value.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              let version = RelaySemanticVersion(value), version.description == value else { return nil }
        return value
    }

    private static func releaseURL(tag: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")!
    }

    private static func assetURL(tag: String, name: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(name)")!
    }

    private func uniqueDestinationURL(in directory: URL, preferredName: String) -> URL {
        let initial = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
        return directory.appendingPathComponent(
            "\(initial.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).\(initial.pathExtension)"
        )
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [GitHubAsset]
        let draft: Bool?
        let prerelease: Bool?
        var version: String { UpdateService.version(for: tagName)! }
        var releaseURL: URL { UpdateService.releaseURL(tag: tagName) }

        func assetURL(_ asset: GitHubAsset) throws -> URL {
            guard let url = URL(string: asset.browserDownloadURL), UpdateService.isSafeHTTPS(url),
                  url == UpdateService.assetURL(tag: tagName, name: asset.name) else {
                throw UpdateServiceError.unsupportedDownloadURL
            }
            return url
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets, draft, prerelease
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String
        let digest: String?
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case name, digest, size
            case browserDownloadURL = "browser_download_url"
        }
    }
}

/// Task-local policy: reject an unsafe redirect BEFORE following it. The final
/// response is checked separately as defense against injected/protocol responses.
final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: URL
    let allowsAssetCDN: Bool

    init(origin: URL, allowsAssetCDN: Bool) {
        self.origin = origin
        self.allowsAssetCDN = allowsAssetCDN
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              UpdateService.isAllowedDestination(url, origin: origin, allowsAssetCDN: allowsAssetCDN) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
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
