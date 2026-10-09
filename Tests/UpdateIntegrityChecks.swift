import Foundation
import CryptoKit

/// Offline callable checks. Parent runner: compile this file and call
/// `try await UpdateIntegrityChecks.run()` from its async entry point.
/// Independent entry point: scripts/test-update-integrity.sh.
enum UpdateIntegrityChecks {
    private static let version = "9.8.7"
    private static let tag = "v9.8.7"
    private static let dmg = "Relay-9.8.7-macos-arm64.dmg"
    private static let zip = "Relay-9.8.7-macos-arm64.zip"
    private static let checksums = "Relay-9.8.7-sha256.txt"
    private static let bytes = Data("offline release fixture, not an app".utf8)
    private static let metadataURL = URL(string: "https://api.github.com/repos/DavisDing/Relay/releases/tags/v9.8.7")!
    private static let releaseURL = URL(string: "https://github.com/DavisDing/Relay/releases/tag/v9.8.7")!

    private static func url(_ name: String) -> URL {
        URL(string: "https://github.com/DavisDing/Relay/releases/download/\(tag)/\(name)")!
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func asset(_ name: String, digest: String? = nil, size: Int? = nil,
                              downloadURL: String? = nil) -> [String: Any] {
        var asset: [String: Any] = ["name": name, "browser_download_url": downloadURL ?? url(name).absoluteString]
        if let digest { asset["digest"] = digest }
        if let size { asset["size"] = size }
        return asset
    }

    private static func metadata(_ assets: [[String: Any]], tagName: String = tag,
                                 htmlURL: String = releaseURL.absoluteString,
                                 prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": tagName, "html_url": htmlURL,
                                                   "draft": false, "prerelease": prerelease, "assets": assets])
    }

    private static func verify(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "UpdateIntegrityChecks", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor private static func rejects(_ expected: UpdateServiceError, _ message: String,
                                          _ body: () async throws -> Void) async throws {
        do { try await body() }
        catch let error as UpdateServiceError {
            try verify(error == expected, "\(message): expected \(expected), got \(error)")
            return
        }
        throw NSError(domain: "UpdateIntegrityChecks", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Did not reject: \(message)"])
    }

    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateIntegrityURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UpdateIntegrityURLProtocol.install([:]) }
        let directory = root.appendingPathComponent("downloads")
        let service = UpdateService(session: session, downloadsDirectory: directory)
        let update = RelayAppUpdate(version: version, releaseURL: releaseURL, downloadURL: url(dmg), assetName: dmg)
        let digest = "sha256:" + hash(bytes)
        let goodAsset = asset(dmg, digest: digest, size: bytes.count)
        let goodMetadata = try metadata([asset(zip, digest: digest), goodAsset])

        func install(_ data: Data, body: Data = bytes, status: Int = 200, finalURL: URL? = nil,
                     extra: [URL: UpdateIntegrityFixture] = [:]) {
            var routes = extra
            routes[metadataURL] = UpdateIntegrityFixture(data: data)
            routes[UpdateService.releasesAPIURL] = UpdateIntegrityFixture(data: data)
            routes[url(dmg)] = UpdateIntegrityFixture(data: body, status: status, finalURL: finalURL)
            UpdateIntegrityURLProtocol.install(routes)
        }

        // Real URLSession operations, but every request is intercepted offline.
        install(goodMetadata)
        guard case .available(let selected) = try await service.checkForUpdates() else {
            throw NSError(domain: "UpdateIntegrityChecks", code: 3)
        }
        try verify(selected == update, "Select exact versioned DMG and retain the original tag")
        let destination = try await service.download(selected)
        try verify(try Data(contentsOf: destination) == bytes, "Digest-verified bytes are exposed only after validation")
        try verify(destination.lastPathComponent == dmg, "Preserve manual DMG installation")
        try verify(UpdateIntegrityURLProtocol.requestedURLs == [UpdateService.releasesAPIURL, metadataURL, url(dmg)],
                   "Re-read exact tag; valid digest needs no checksum fetch")
        let collision = try await service.download(update)
        try verify(collision != destination && collision.pathExtension == "dmg", "Existing file is not overwritten")
        try verify(try Data(contentsOf: destination) == bytes, "Existing download remains unchanged")
        try FileManager.default.removeItem(at: directory)

        let zipMetadata = try metadata([asset(zip, digest: digest)])
        install(zipMetadata, extra: [url(zip): UpdateIntegrityFixture(data: bytes)])
        guard case .available(let zipUpdate) = try await service.checkForUpdates() else {
            throw NSError(domain: "UpdateIntegrityChecks", code: 4)
        }
        try verify(zipUpdate.assetName == zip, "ZIP compatibility fallback")
        let zipDestination = try await service.download(zipUpdate)
        try verify(zipDestination.pathExtension == "zip", "ZIP verified without DMG")
        try FileManager.default.removeItem(at: directory)

        // A tag without the v prefix remains correctly pinned on later download.
        let bareTagURL = URL(string: "https://api.github.com/repos/DavisDing/Relay/releases/tags/9.8.7")!
        let bareReleaseURL = URL(string: "https://github.com/DavisDing/Relay/releases/tag/9.8.7")!
        let bareAssetURL = URL(string: "https://github.com/DavisDing/Relay/releases/download/9.8.7/\(dmg)")!
        let bareMetadata = try metadata([asset(dmg, digest: digest, downloadURL: bareAssetURL.absoluteString)],
                                        tagName: version, htmlURL: bareReleaseURL.absoluteString)
        UpdateIntegrityURLProtocol.install([
            UpdateService.releasesAPIURL: UpdateIntegrityFixture(data: bareMetadata),
            bareTagURL: UpdateIntegrityFixture(data: bareMetadata), bareAssetURL: UpdateIntegrityFixture(data: bytes)
        ])
        guard case .available(let bareUpdate) = try await service.checkForUpdates() else {
            throw NSError(domain: "UpdateIntegrityChecks", code: 5)
        }
        try verify(bareUpdate.releaseTag == version, "Do not invent a v prefix for a selected bare tag")
        _ = try await service.download(bareUpdate)
        try FileManager.default.removeItem(at: directory)

        let checksumText = "\(hash(bytes))  \(dmg)\n\(hash(bytes)) *\(zip)\n"
        let checksumData = Data(checksumText.utf8)
        let fallbackMetadata = try metadata([
            asset(dmg, size: bytes.count), asset(checksums, digest: "sha256:" + hash(checksumData))
        ])
        install(fallbackMetadata, extra: [url(checksums): UpdateIntegrityFixture(data: checksumData)])
        _ = try await service.download(update)
        try verify(UpdateIntegrityURLProtocol.requestedURLs == [metadataURL, url(checksums), url(dmg)],
                   "Missing digest resolves checksums from the same release before package download")
        try FileManager.default.removeItem(at: directory)

        // Historical checksum assets may themselves lack GitHub's optional digest.
        install(try metadata([asset(dmg), asset(checksums)]),
                extra: [url(checksums): UpdateIntegrityFixture(data: checksumData)])
        _ = try await service.download(update)
        try FileManager.default.removeItem(at: directory)

        install(try metadata([asset(dmg)]))
        try await rejects(.integrityUnavailable, "missing both digest and checksums") { _ = try await service.download(update) }
        try verify(UpdateIntegrityURLProtocol.requestedURLs == [metadataURL], "Missing integrity fails before requesting package")
        for badDigest in ["", "sha256:123", "sha512:" + hash(bytes), "sha256:" + String(repeating: "g", count: 64)] {
            install(try metadata([asset(dmg, digest: badDigest), asset(checksums)]),
                    extra: [url(checksums): UpdateIntegrityFixture(data: checksumData)])
            try await rejects(.integrityUnavailable, "invalid digest must not downgrade") { _ = try await service.download(update) }
            try verify(UpdateIntegrityURLProtocol.requestedURLs == [metadataURL], "Malformed digest stops fallback")
        }
        install(goodMetadata, body: Data("tampered".utf8))
        try await rejects(.integrityMismatch, "asset size mismatch") { _ = try await service.download(update) }
        install(try metadata([asset(dmg, digest: digest)]), body: Data("tampered".utf8))
        try await rejects(.integrityMismatch, "digest mismatch without length metadata") { _ = try await service.download(update) }
        install(goodMetadata, body: Data(repeating: 65, count: bytes.count))
        try await rejects(.integrityMismatch, "same-size tampering") { _ = try await service.download(update) }
        let largeBytes = Data(repeating: 65, count: 2 * 1024 * 1024 + 3)
        install(try metadata([asset(dmg, digest: "sha256:" + hash(largeBytes), size: largeBytes.count)]), body: largeBytes)
        let largeDestination = try await service.download(update)
        try verify(try Data(contentsOf: largeDestination) == largeBytes, "Streamed SHA-256 across multiple file chunks")
        try FileManager.default.removeItem(at: directory)
        install(try metadata([asset(dmg, digest: digest, size: -1)]))
        try await rejects(.integrityMismatch, "negative size") { _ = try await service.download(update) }
        install(try metadata([asset(dmg, digest: "sha256:" + hash(bytes).uppercased())]))
        _ = try await service.download(update)
        try FileManager.default.removeItem(at: directory)

        install(fallbackMetadata, extra: [url(checksums): UpdateIntegrityFixture(data: Data((checksumText + "\n").utf8))])
        try await rejects(.integrityMismatch, "checksum asset's own digest mismatch") { _ = try await service.download(update) }
        install(try metadata([asset(dmg), asset(checksums, digest: "sha256:no")]),
                extra: [url(checksums): UpdateIntegrityFixture(data: checksumData)])
        try await rejects(.integrityUnavailable, "malformed checksum asset digest") { _ = try await service.download(update) }
        install(try metadata([asset(dmg), asset(checksums)]), extra: [url(checksums): UpdateIntegrityFixture(data: Data(repeating: 65, count: 128 * 1024 + 1))])
        try await rejects(.integrityUnavailable, "oversized checksums") { _ = try await service.download(update) }

        install(try metadata([asset(dmg), asset(checksums, size: checksumData.count + 1)]),
                extra: [url(checksums): UpdateIntegrityFixture(data: checksumData)])
        try await rejects(.integrityMismatch, "checksum asset length mismatch") { _ = try await service.download(update) }
        install(try metadata([asset(dmg), asset(checksums, size: 128 * 1024 + 1)]))
        try await rejects(.integrityUnavailable, "declared checksum size bound") { _ = try await service.download(update) }
        try verify(UpdateIntegrityURLProtocol.requestedURLs == [metadataURL], "Reject oversized checksum metadata before download")

        let invalidChecksums: [Data] = [
            Data(), Data([0xff]), Data("\(hash(bytes))  \(zip)\n".utf8),
            Data("\(hash(bytes))  ../\(dmg)\n".utf8),
            Data("\(hash(bytes))  Relay-1.2.3-macos-arm64.dmg\n".utf8),
            Data((checksumText + "\(hash(bytes))  \(dmg)\n").utf8),
            Data("\(String(repeating: "g", count: 64))  \(dmg)\n".utf8),
            Data("\(hash(bytes)) \(dmg)\n".utf8),
            Data("\(hash(bytes))  \(dmg) trailing\n".utf8)
        ]
        for bad in invalidChecksums {
            install(try metadata([asset(dmg), asset(checksums)]), extra: [url(checksums): UpdateIntegrityFixture(data: bad)])
            try await rejects(.integrityUnavailable, "malformed/unbound checksum record") { _ = try await service.download(update) }
            try verify(!UpdateIntegrityURLProtocol.requestedURLs.contains(url(dmg)), "Invalid checksum cannot expose or request package")
        }

        // URLs must match this repository, tag and exact asset, with no extras.
        let unsafeURLs = [
            "http://github.com/DavisDing/Relay/releases/download/\(tag)/\(dmg)",
            "https://github.com:444/DavisDing/Relay/releases/download/\(tag)/\(dmg)",
            "https://user@github.com/DavisDing/Relay/releases/download/\(tag)/\(dmg)",
            "https://github.com/Other/Relay/releases/download/\(tag)/\(dmg)",
            "https://github.com/DavisDing/Relay/releases/download/v1.2.3/\(dmg)",
            "https://github.com/DavisDing/Relay/releases/download/\(tag)/\(zip)",
            "https://github.com/DavisDing/Relay/releases/download/\(tag)/\(dmg)?download=1",
            "https://github.com/DavisDing/Relay/releases/download/\(tag)/\(dmg)#fragment",
            "https://github.com/DavisDing/Relay/releases/download/\(tag)/%2e%2e/\(dmg)",
            "https://release-assets.githubusercontent.com/github-production-release-asset/123/fixture",
            "https://github.com.evil.invalid/DavisDing/Relay/releases/download/\(tag)/\(dmg)"
        ]
        for raw in unsafeURLs {
            UpdateIntegrityURLProtocol.install([:])
            let malicious = RelayAppUpdate(version: version, releaseURL: releaseURL,
                                           downloadURL: URL(string: raw)!, assetName: dmg)
            try await rejects(.unsupportedDownloadURL, "unbound initial URL") { _ = try await service.download(malicious) }
            try verify(UpdateIntegrityURLProtocol.requestedURLs.isEmpty, "Do not send an untrusted initial request")
            install(try metadata([asset(dmg, digest: digest, downloadURL: raw)]))
            try await rejects(.unsupportedDownloadURL, "unbound URL in server metadata") { _ = try await service.checkForUpdates() }
        }
        install(try metadata([goodAsset], htmlURL: "https://github.com/Other/Relay/releases/tag/\(tag)"))
        try await rejects(.invalidReleaseResponse, "wrong release page source") { _ = try await service.checkForUpdates() }
        install(try metadata([goodAsset, goodAsset]))
        try await rejects(.invalidReleaseResponse, "duplicate assets") { _ = try await service.download(update) }
        install(try metadata([goodAsset], tagName: "v1.2.3", htmlURL: "https://github.com/DavisDing/Relay/releases/tag/v1.2.3"))
        try await rejects(.invalidReleaseResponse, "tag metadata substitution") { _ = try await service.download(update) }
        install(try metadata([goodAsset], prerelease: true))
        try await rejects(.invalidReleaseResponse, "prerelease") { _ = try await service.checkForUpdates() }
        install(try metadata([asset("Relay-1.2.3-macos-arm64.dmg", digest: digest)]))
        try await rejects(.noMacOSArm64Asset, "wrong version filename") { _ = try await service.checkForUpdates() }

        // A response cannot bypass the final destination/status checks, even when
        // delivered by URLProtocol without a normal HTTP redirect callback.
        let allowedCDN = URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123/fixture?sig=offline")!
        install(goodMetadata, finalURL: allowedCDN)
        _ = try await service.download(update)
        try FileManager.default.removeItem(at: directory)
        for raw in ["http://objects.githubusercontent.com/github-production-release-asset/123/fixture",
                    "https://evil.invalid/file", "https://github.com/Other/Relay/file",
                    "https://release-assets.githubusercontent.com/not-a-release/file",
                    "https://release-assets.githubusercontent.com:444/github-production-release-asset/123/file",
                    "https://user@objects.githubusercontent.com/github-production-release-asset/123/file",
                    "https://objects.githubusercontent.com/github-production-release-asset/../file"] {
            install(goodMetadata, finalURL: URL(string: raw)!)
            try await rejects(.unsupportedDownloadURL, "unsafe final destination") { _ = try await service.download(update) }
        }
        for status in [206, 302, 404, 500] {
            install(goodMetadata, status: status)
            try await rejects(.downloadFailed, "non-complete HTTP download") { _ = try await service.download(update) }
        }
        UpdateIntegrityURLProtocol.install([metadataURL: UpdateIntegrityFixture(data: goodMetadata, status: 500)])
        try await rejects(.invalidReleaseResponse, "metadata HTTP error") { _ = try await service.download(update) }
        UpdateIntegrityURLProtocol.install([metadataURL: UpdateIntegrityFixture(data: goodMetadata, finalURL: allowedCDN)])
        try await rejects(.unsupportedDownloadURL, "metadata may not redirect to CDN") { _ = try await service.download(update) }
        UpdateIntegrityURLProtocol.install([metadataURL: UpdateIntegrityFixture(data: bytes)])
        try await rejects(.invalidReleaseResponse, "invalid metadata JSON") { _ = try await service.download(update) }
        UpdateIntegrityURLProtocol.install([url(dmg): UpdateIntegrityFixture(data: bytes), metadataURL: UpdateIntegrityFixture(data: goodMetadata),
                                            url(checksums): UpdateIntegrityFixture(data: Data())])
        try verify(!FileManager.default.fileExists(atPath: directory.path), "Failure paths never create Downloads")

        try verifyRedirectPolicy(session: session, origin: url(dmg), allowedCDN: allowedCDN)
        try await verifyCleanup(service: service, update: update, root: root)
        print("PASSED: offline update integrity, digest/checksum fallback, version/source binding, URL/redirect policy, cleanup and manual DMG/ZIP downloads")
    }

    private static func verifyRedirectPolicy(session: URLSession, origin: URL, allowedCDN: URL) throws {
        let policy = UpdateRedirectPolicy(origin: origin, allowsAssetCDN: true)
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = session.dataTask(with: origin) // Never resumed; no request/network.
        defer { task.cancel() }
        for (target, allowed) in [
            (allowedCDN, true), (origin, true),
            (URL(string: "https://objects.githubusercontent.com/github-production-release-asset/123/fixture")!, true),
            (URL(string: "https://objects.githubusercontent.com/github-production-release-asset-2e65be/123/fixture")!, true),
            (URL(string: "https://evil.invalid/file")!, false),
            (URL(string: "http://release-assets.githubusercontent.com/github-production-release-asset/123/fixture")!, false),
            (URL(string: "https://github.com/DavisDing/Relay/releases/download/v0.1.0/old.dmg")!, false)
        ] {
            var followed: URLRequest?
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: target)) { followed = $0 }
            try verify((followed != nil) == allowed, "Reject unsafe redirect before it is followed")
        }
        let metadataPolicy = UpdateRedirectPolicy(origin: metadataURL, allowsAssetCDN: false)
        var followed: URLRequest?
        metadataPolicy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                  newRequest: URLRequest(url: allowedCDN)) { followed = $0 }
        try verify(followed == nil, "Metadata must stay on the exact GitHub API path")
    }

    @MainActor private static func verifyCleanup(service: UpdateService, update: RelayAppUpdate, root: URL) async throws {
        let staging = root.appendingPathComponent("known-download.tmp")
        let directory = root.appendingPathComponent("cleanup-downloads")
        let goodResponse = HTTPURLResponse(url: update.downloadURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        for (response, expectedHash, expectedSize, error) in [
            (goodResponse, String(repeating: "0", count: 64), nil as Int64?, UpdateServiceError.integrityMismatch),
            (goodResponse, hash(bytes), Int64(bytes.count + 1), UpdateServiceError.integrityMismatch),
            (HTTPURLResponse(url: update.downloadURL, statusCode: 500, httpVersion: nil, headerFields: nil)!, hash(bytes), nil, UpdateServiceError.downloadFailed),
            (HTTPURLResponse(url: URL(string: "https://evil.invalid/file")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, hash(bytes), nil, UpdateServiceError.unsupportedDownloadURL)
        ] {
            try bytes.write(to: staging)
            try await rejects(error, "known temporary file is removed on verification failure") {
                _ = try service.completeDownload(temporaryURL: staging, response: response, update: update,
                                                 expectedHash: expectedHash, expectedSize: expectedSize, directory: directory)
            }
            try verify(!FileManager.default.fileExists(atPath: staging.path), "Remove failed temporary file")
            try verify(!FileManager.default.fileExists(atPath: directory.path), "Never expose unverified file")
        }
        // Destination failures must also remove a successfully verified staging file.
        let blockedDirectory = root.appendingPathComponent("not-a-directory")
        try bytes.write(to: blockedDirectory)
        try bytes.write(to: staging)
        var destinationFailed = false
        do {
            _ = try service.completeDownload(temporaryURL: staging, response: goodResponse, update: update,
                                             expectedHash: hash(bytes), expectedSize: nil, directory: blockedDirectory)
        } catch { destinationFailed = true }
        try verify(destinationFailed, "Reject unavailable destination")
        try verify(!FileManager.default.fileExists(atPath: staging.path), "Clean temporary file after destination failure")
        try bytes.write(to: staging)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try service.completeDownload(temporaryURL: staging, response: goodResponse, update: update,
                                                expectedHash: hash(bytes), expectedSize: nil, directory: directory)
        }
        do { _ = try await task.value; throw NSError(domain: "Expected cancellation", code: 1) }
        catch is CancellationError {}
        try verify(!FileManager.default.fileExists(atPath: staging.path), "Cancellation removes staging file")
        try verify(!FileManager.default.fileExists(atPath: directory.path), "Cancellation never exposes file")
    }
}

private struct UpdateIntegrityFixture {
    let data: Data
    var status: Int = 200
    var finalURL: URL? = nil
}

/// All URLSession requests, including unexpected ones, are handled here. No live
/// GitHub/vendor API, credentials, external network or user Downloads are accessed.
private final class UpdateIntegrityURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var routes: [URL: UpdateIntegrityFixture] = [:]
    private static var requests: [URL] = []

    static func install(_ fixtures: [URL: UpdateIntegrityFixture]) {
        lock.lock(); defer { lock.unlock() }
        routes = fixtures
        requests = []
    }

    static var requestedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requests.append(url)
        let fixture = Self.routes[url]
        Self.lock.unlock()
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(url: fixture.finalURL ?? url, statusCode: fixture.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(fixture.data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
