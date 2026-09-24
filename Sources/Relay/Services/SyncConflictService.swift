import Foundation

/// The availability of the optional iCloud file-sync channel. Local business
/// data remains usable for every value of this enum.
public enum SyncAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

public enum SyncStatus: String, Sendable, Equatable {
    case idle
    case downloading
    case uploading
    case merged
    case conflicted
    case unavailable
    case failed

    public var title: String {
        switch self {
        case .idle: return "未同步"
        case .downloading: return "正在下载"
        case .uploading: return "正在上传"
        case .merged: return "已合并"
        case .conflicted: return "存在同步冲突"
        case .unavailable: return "同步不可用"
        case .failed: return "同步失败"
        }
    }
}

public enum SyncSource: Sendable, Equatable {
    case local
    case remote
    case conflictCopy(URL)

    public var label: String {
        switch self {
        case .local: return "本机"
        case .remote: return "iCloud"
        case .conflictCopy: return "冲突副本"
        }
    }
}

/// A candidate is the only data shape accepted by the conflict layer. Its
/// initializer normalizes account credential references to account UUIDs and
/// therefore never copies a token, user ID, API key, cookie, or credential map
/// key into the sync payload.
public struct SyncCandidate: Identifiable, Sendable, Equatable {
    public let id: String
    public let source: SyncSource
    public let fileURL: URL
    public let data: RelaySyncData
    public let modifiedAt: Date

    public init(source: SyncSource, fileURL: URL, data: RelaySyncData, modifiedAt: Date) {
        self.source = source
        self.fileURL = fileURL
        self.data = RelaySyncDataSafety.sanitized(data)
        self.modifiedAt = modifiedAt
        self.id = Self.makeID(source: source, fileURL: fileURL)
    }

    private static func makeID(source: SyncSource, fileURL: URL) -> String {
        let sourceKey: String
        switch source {
        case .local: sourceKey = "local"
        case .remote: sourceKey = "remote"
        case .conflictCopy: sourceKey = "conflict"
        }
        return "\(sourceKey):\(fileURL.standardizedFileURL.path)"
    }
}

public enum SyncConflictReason: String, Sendable, Equatable {
    case unresolvedVersions
    case mergeFailed

    public var title: String {
        switch self {
        case .unresolvedVersions: return "检测到多个 iCloud 版本"
        case .mergeFailed: return "自动合并失败"
        }
    }
}

public struct SyncConflictItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let candidate: SyncCandidate
    public let reason: SyncConflictReason

    public init(candidate: SyncCandidate, reason: SyncConflictReason) {
        self.id = candidate.id
        self.candidate = candidate
        self.reason = reason
    }
}

/// A report is deliberately immutable. While it is conflicted, all candidates
/// remain available to the caller and no resolution is produced.
public struct SyncConflictReport: Sendable, Equatable {
    public let status: SyncStatus
    public let local: SyncCandidate
    public let remoteCandidates: [SyncCandidate]
    public let conflicts: [SyncConflictItem]
    public let mergedData: RelaySyncData?
    public let requiresUserAction: Bool

    public init(
        status: SyncStatus,
        local: SyncCandidate,
        remoteCandidates: [SyncCandidate],
        conflicts: [SyncConflictItem],
        mergedData: RelaySyncData?,
        requiresUserAction: Bool
    ) {
        self.status = status
        self.local = local
        self.remoteCandidates = remoteCandidates
        self.conflicts = conflicts
        self.mergedData = mergedData.map(RelaySyncDataSafety.sanitized)
        self.requiresUserAction = requiresUserAction
    }
}

public enum SyncConflictDecision: Sendable, Equatable {
    case keepLocal
    case keepRemote
    case acceptMerged
}

public struct SyncResolutionResult: Sendable, Equatable {
    public let decision: SyncConflictDecision
    public let data: RelaySyncData
    /// Conflict candidates are intentionally retained for the caller to
    /// archive or delete later. Resolution itself never deletes a file.
    public let preservedCandidates: [SyncCandidate]
    public let selectedRemoteCandidate: SyncCandidate?
    public let resolvedAt: Date

    public init(
        decision: SyncConflictDecision,
        data: RelaySyncData,
        preservedCandidates: [SyncCandidate],
        selectedRemoteCandidate: SyncCandidate?,
        resolvedAt: Date = Date()
    ) {
        self.decision = decision
        self.data = RelaySyncDataSafety.sanitized(data)
        self.preservedCandidates = preservedCandidates
        self.selectedRemoteCandidate = selectedRemoteCandidate
        self.resolvedAt = resolvedAt
    }
}

public enum SyncConflictError: Error, LocalizedError, Sendable, Equatable {
    case invalidLocalCandidate
    case invalidRemoteCandidate
    case unsupportedSchema
    case mergeFailed
    case noPendingConflict
    case mergedDataUnavailable
    case remoteCandidateUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidLocalCandidate:
            return "本机同步候选无效。"
        case .invalidRemoteCandidate:
            return "远端同步候选无效。"
        case .unsupportedSchema:
            return "同步文件版本不受支持。"
        case .mergeFailed:
            return "同步数据无法自动合并。"
        case .noPendingConflict:
            return "当前没有等待用户决策的同步冲突。"
        case .mergedDataUnavailable:
            return "当前没有可供用户接受的合并结果。"
        case .remoteCandidateUnavailable:
            return "没有可用的远端冲突副本。"
        }
    }
}

public struct SyncConflictState: Sendable, Equatable {
    public let status: SyncStatus
    public let report: SyncConflictReport?
    public let resolution: SyncResolutionResult?
    public let error: SyncConflictError?
    public let availabilityMessage: String?
    public let localDataAvailable: Bool

    public init(
        status: SyncStatus,
        report: SyncConflictReport? = nil,
        resolution: SyncResolutionResult? = nil,
        error: SyncConflictError? = nil,
        availabilityMessage: String? = nil,
        localDataAvailable: Bool = true
    ) {
        self.status = status
        self.report = report
        self.resolution = resolution
        self.error = error
        self.availabilityMessage = availabilityMessage
        self.localDataAvailable = localDataAvailable
    }
}

/// This protocol isolates the conflict state machine from the existing file
/// transport. FileSyncService can adopt it later without changing this model.
public protocol SyncConflictHandling: Sendable {
    func inspect(
        local: SyncCandidate,
        remoteCandidates: [SyncCandidate],
        availability: SyncAvailability
    ) -> SyncConflictState

    func resolve(
        report: SyncConflictReport,
        decision: SyncConflictDecision
    ) throws -> SyncResolutionResult
}

/// Adapter seam for the current deterministic record merge. Tests and a
/// future UI integration can inject another implementation without touching
/// FileSyncService or SyncMerge.
public protocol SyncDataMerging: Sendable {
    func merge(_ local: RelaySyncData, _ remote: RelaySyncData) throws -> RelaySyncData
}

public struct RelaySyncDataMergeAdapter: SyncDataMerging, Sendable {
    public init() {}

    public func merge(_ local: RelaySyncData, _ remote: RelaySyncData) throws -> RelaySyncData {
        try SyncMerge.merge(local, remote)
    }
}

public struct SyncConflictService: SyncConflictHandling, Sendable {
    private let merger: any SyncDataMerging

    public init(merger: any SyncDataMerging = RelaySyncDataMergeAdapter()) {
        self.merger = merger
    }

    public func inspect(
        local: SyncCandidate,
        remoteCandidates: [SyncCandidate],
        availability: SyncAvailability = .available
    ) -> SyncConflictState {
        guard case .local = local.source else {
            return SyncConflictState(
                status: .failed,
                error: .invalidLocalCandidate,
                localDataAvailable: false
            )
        }

        if case let .unavailable(reason) = availability {
            return SyncConflictState(
                status: .unavailable,
                availabilityMessage: reason,
                localDataAvailable: true
            )
        }

        guard local.data.schemaVersion == RelaySyncData.currentSchemaVersion,
              local.data.settings.schemaVersion == RelaySettings.currentSchemaVersion else {
            return SyncConflictState(status: .failed, error: .unsupportedSchema)
        }

        guard remoteCandidates.allSatisfy({ candidate in
            switch candidate.source {
            case .remote, .conflictCopy:
                return candidate.data.schemaVersion == RelaySyncData.currentSchemaVersion &&
                    candidate.data.settings.schemaVersion == RelaySettings.currentSchemaVersion
            case .local:
                return false
            }
        }) else {
            return SyncConflictState(status: .failed, error: .invalidRemoteCandidate)
        }

        let orderedRemote = remoteCandidates.sorted(by: Self.candidateOrder)
        guard !orderedRemote.isEmpty else {
            let report = SyncConflictReport(
                status: .idle,
                local: local,
                remoteCandidates: [],
                conflicts: [],
                mergedData: local.data,
                requiresUserAction: false
            )
            return SyncConflictState(status: .idle, report: report)
        }

        do {
            var merged = local.data
            for candidate in orderedRemote {
                merged = try merger.merge(merged, candidate.data)
            }
            let hasUnresolvedVersions = orderedRemote.count > 1
            let status: SyncStatus = hasUnresolvedVersions ? .conflicted : .merged
            let conflicts = hasUnresolvedVersions
                ? orderedRemote.map { SyncConflictItem(candidate: $0, reason: .unresolvedVersions) }
                : []
            let report = SyncConflictReport(
                status: status,
                local: local,
                remoteCandidates: orderedRemote,
                conflicts: conflicts,
                mergedData: merged,
                requiresUserAction: hasUnresolvedVersions
            )
            return SyncConflictState(status: status, report: report)
        } catch {
            let conflicts = orderedRemote.map { SyncConflictItem(candidate: $0, reason: .mergeFailed) }
            let report = SyncConflictReport(
                status: .conflicted,
                local: local,
                remoteCandidates: orderedRemote,
                conflicts: conflicts,
                mergedData: nil,
                requiresUserAction: true
            )
            return SyncConflictState(status: .conflicted, report: report, error: .mergeFailed)
        }
    }

    public func resolve(
        report: SyncConflictReport,
        decision: SyncConflictDecision
    ) throws -> SyncResolutionResult {
        guard report.requiresUserAction, report.status == .conflicted else {
            throw SyncConflictError.noPendingConflict
        }

        switch decision {
        case .keepLocal:
            return SyncResolutionResult(
                decision: decision,
                data: report.local.data,
                preservedCandidates: report.remoteCandidates,
                selectedRemoteCandidate: nil
            )
        case .keepRemote:
            guard let selected = report.remoteCandidates.sorted(by: Self.candidateOrder).last else {
                throw SyncConflictError.remoteCandidateUnavailable
            }
            return SyncResolutionResult(
                decision: decision,
                data: selected.data,
                preservedCandidates: report.remoteCandidates,
                selectedRemoteCandidate: selected
            )
        case .acceptMerged:
            guard let mergedData = report.mergedData else {
                throw SyncConflictError.mergedDataUnavailable
            }
            return SyncResolutionResult(
                decision: decision,
                data: mergedData,
                preservedCandidates: report.remoteCandidates,
                selectedRemoteCandidate: nil
            )
        }
    }

    private static func candidateOrder(_ lhs: SyncCandidate, _ rhs: SyncCandidate) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        return lhs.id < rhs.id
    }
}

/// Safety boundary for all data entering the conflict layer. The current
/// AccountConfiguration contains a local credential reference for repository
/// use; the sync projection rewrites it to the account UUID and never copies
/// the original value. The actual ProviderCredential fields do not exist in
/// RelaySyncData and therefore cannot be serialized by this projection.
public enum RelaySyncDataSafety {
    public static func sanitized(_ data: RelaySyncData) -> RelaySyncData {
        let accounts = data.accounts.map { account in
            AccountConfiguration(
                id: account.id,
                displayName: account.displayName,
                providerKind: account.providerKind,
                siteOrigin: account.siteOrigin,
                credentialReference: nil,
                isEnabled: account.isEnabled,
                isHidden: account.isHidden,
                lowBalanceThreshold: account.lowBalanceThreshold,
                manualUSDToCNY: account.manualUSDToCNY,
                sortOrder: account.sortOrder,
                createdAt: account.createdAt,
                updatedAt: account.updatedAt
            )
        }
        return RelaySyncData(
            schemaVersion: data.schemaVersion,
            exportedAt: data.exportedAt,
            accounts: accounts,
            snapshots: data.snapshots,
            dailyUsage: data.dailyUsage,
            settings: data.settings,
            settingsUpdatedAt: data.settingsUpdatedAt,
            deletedAccountIDs: data.deletedAccountIDs
        )
    }

    public static func isSafe(_ data: RelaySyncData) -> Bool {
        data.accounts.allSatisfy { $0.credentialReference == $0.id.uuidString }
    }
}
