import Foundation

/// Serial file work owns only immutable, non-secret snapshots. It never receives
/// a MainActor repository or UI state, and never applies data to the local store.
actor SyncFileWorker {
    struct Prepared: Sendable {
        let data: RelaySyncData
        let candidates: [SyncCandidate]
        let signatures: [URL: Data]
        let conflict: SyncConflictReport?
        var diagnostics: SyncPerformanceDiagnostics
    }

    struct Written: Sendable {
        let remoteChanged: Bool
        let diagnostics: SyncPerformanceDiagnostics
    }

    private func coordinated<T>(_ file: URL, writing: Bool,
                                fixture: FileSyncService.Coordination?, metrics: inout SyncPerformanceDiagnostics,
                                body: @escaping (URL) throws -> T) throws -> T {
        let started = RepositoryPerformanceClock.now()
        var workMilliseconds: Double = 0
        defer {
            metrics.coordinationMilliseconds += max(0, RepositoryPerformanceClock.elapsedMilliseconds(since: started) - workMilliseconds)
        }
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { url in
            let start = RepositoryPerformanceClock.now()
            result = Result { try body(url) }
            workMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: start)
        }
        if let fixture { try fixture(file, writing, accessor) }
        else {
            var error: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            if writing {
                if FileManager.default.fileExists(atPath: file.path) {
                    coordinator.coordinate(writingItemAt: file, options: [], error: &error, byAccessor: accessor)
                } else {
                    coordinator.coordinate(writingItemAt: file.deletingLastPathComponent(), options: [], error: &error) { directory in
                        accessor(directory.appendingPathComponent(file.lastPathComponent))
                    }
                }
            }
            else { coordinator.coordinate(readingItemAt: file, options: [], error: &error, byAccessor: accessor) }
            guard error == nil else { throw FileSyncError.coordinationFailed }
        }
        guard let result else { throw FileSyncError.coordinationFailed }
        return try result.get()
    }

    private func signatures(at file: URL, versions: [NSFileVersion]) throws -> [URL: Data] {
        var result: [URL: Data] = [:]
        for url in [file] + versions.map(\.url) {
            do { result[url] = try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                guard url == file else { throw FileSyncError.unreadableConflict }
            }
        }
        return result
    }

    func prepare(local: RelaySyncData, directory: URL,
                 coordination: FileSyncService.Coordination? = nil) throws -> Prepared {
        try Task.checkCancellation()
        var metrics = SyncPerformanceDiagnostics()
        let start = RepositoryPerformanceClock.now()
        return try FileSyncService.withSecurityScopedAccess(directory) {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw FileSyncError.invalidDirectory }
            let file = directory.appendingPathComponent(FileSyncService.fileName)
            let value = try coordinated(file, writing: true, fixture: coordination, metrics: &metrics) { url in
                try Task.checkCancellation()
                let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
                let hashes = try self.signatures(at: url, versions: versions)
                var candidates: [SyncCandidate] = []
                if let data = try FileSyncService.readPayloadIfPresent(at: url) {
                    candidates.append(SyncCandidate(source: .remote, fileURL: url, data: data,
                        modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
                }
                for version in versions {
                    guard let data = try FileSyncService.readPayloadIfPresent(at: version.url) else { throw FileSyncError.unreadableConflict }
                    candidates.append(SyncCandidate(source: .conflictCopy(version.url), fileURL: version.url,
                                                    data: data, modifiedAt: version.modificationDate ?? .distantPast))
                }
                let localCandidate = SyncCandidate(source: .local, fileURL: URL(fileURLWithPath: "relay-local-repository"),
                                                   data: local, modifiedAt: Date())
                let conflict = candidates.count > 1 ? SyncConflictService().inspect(local: localCandidate, remoteCandidates: candidates).report : nil
                var merged = local
                for candidate in candidates { merged = try SyncMerge.merge(merged, candidate.data) }
                return (merged, candidates, hashes, conflict)
            }
            metrics.readMergeMilliseconds = max(0, RepositoryPerformanceClock.elapsedMilliseconds(since: start) - metrics.coordinationMilliseconds)
            return Prepared(data: value.0, candidates: value.1, signatures: value.2, conflict: value.3, diagnostics: metrics)
        }
    }

    func resolve(report: SyncConflictReport, decision: SyncConflictDecision, current: RelaySyncData,
                 prepared: Prepared) throws -> RelaySyncData {
        guard prepared.candidates.count == report.remoteCandidates.count,
              prepared.candidates.allSatisfy({ candidate in
                  report.remoteCandidates.contains { $0.fileURL == candidate.fileURL && $0.data.hasSameContent(as: candidate.data) }
              }) else { throw FileSyncError.dataChanged }
        let refreshed = SyncConflictReport(status: report.status,
            local: SyncCandidate(source: .local, fileURL: report.local.fileURL, data: current, modifiedAt: Date()),
            remoteCandidates: prepared.candidates, conflicts: report.conflicts,
            mergedData: report.mergedData == nil ? nil : prepared.data, requiresUserAction: report.requiresUserAction)
        let resolution = try SyncConflictService().resolve(report: refreshed, decision: decision)
        return try SyncMerge.merge(current, resolution.data)
    }

    func write(local: RelaySyncData, prepared: Prepared, directory: URL,
               coordination: FileSyncService.Coordination? = nil,
               write: ((Data, URL) throws -> Void)? = nil) throws -> Written {
        try Task.checkCancellation()
        var metrics = prepared.diagnostics
        let start = RepositoryPerformanceClock.now()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(RelaySyncDataSafety.sanitized(local))
        metrics.encodeMilliseconds += RepositoryPerformanceClock.elapsedMilliseconds(since: start)
        metrics.payloadBytes = bytes.count
        let changed = try FileSyncService.withSecurityScopedAccess(directory) {
            try coordinated(directory.appendingPathComponent(FileSyncService.fileName), writing: true,
                            fixture: coordination, metrics: &metrics) { url in
                let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
                // Remote edits between read and write require a fresh merge. No
                // stale replacement or conflict-version resolution is allowed.
                guard try self.signatures(at: url, versions: versions) == prepared.signatures else { return (true, 0.0) }
                try Task.checkCancellation()
                let writeStarted = RepositoryPerformanceClock.now()
                try (write ?? FileSyncService.writeAtomically)(bytes, url)
                let duration = RepositoryPerformanceClock.elapsedMilliseconds(since: writeStarted)
                for version in versions { version.isResolved = true }
                return (false, duration)
            }
        }
        metrics.writeMilliseconds += changed.1
        return Written(remoteChanged: changed.0, diagnostics: metrics)
    }
}
