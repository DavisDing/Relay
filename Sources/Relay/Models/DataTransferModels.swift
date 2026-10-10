import Foundation

/// Deliberately contains only configuration. Usage, tombstones and credentials
/// have separate transfer boundaries.
public struct RelayConfigurationArchive: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public let format: String
    public let schemaVersion: Int
    public let exportedAt: Date
    public let accounts: [AccountConfiguration]
    public let settings: RelaySettings

    public init(accounts: [AccountConfiguration], settings: RelaySettings, exportedAt: Date = Date()) {
        self.format = "relay-configuration"
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        let source = RelaySyncData(accounts: accounts, snapshots: [], dailyUsage: [], settings: settings)
        self.accounts = RelaySyncDataSafety.sanitized(source).accounts
        self.settings = settings
    }
}

public struct ConfigurationImportPreview: Sendable, Equatable {
    public let archive: RelayConfigurationArchive
    public let addedAccountCount: Int
    public let updatedAccountCount: Int

    public init(archive: RelayConfigurationArchive, existingAccountIDs: Set<UUID>) {
        self.archive = archive
        addedAccountCount = archive.accounts.filter { !existingAccountIDs.contains($0.id) }.count
        updatedAccountCount = archive.accounts.count - addedAccountCount
    }
}

public struct LocalBackupEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let fileURL: URL
    public let accountCount: Int
    public let historyCount: Int
}

public struct LocalBackupPreview: Sendable, Equatable {
    public let entry: LocalBackupEntry
    public let data: RelaySyncData
}

public enum DataTransferError: Error, LocalizedError, Sendable, Equatable {
    case tooLarge
    case invalidFormat
    case unsupportedVersion
    case invalidAccounts
    case invalidSettings
    case invalidUsage
    case forbiddenField
    case backupUnavailable
    case stalePreview
    case operationInProgress
    case invalidDateRange

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "文件过大，无法安全导入。"
        case .invalidFormat: return "文件不是有效的 Relay 配置或备份。"
        case .unsupportedVersion: return "文件版本较新或不受支持，请升级 Relay 后重试。"
        case .invalidAccounts: return "账号配置包含重复账号、无效地址或超出范围的数值。"
        case .invalidSettings: return "设置包含无效或超出范围的数值。"
        case .invalidUsage: return "备份中的消费数据无效。"
        case .forbiddenField: return "文件包含不允许导入的字段或敏感凭据。"
        case .backupUnavailable: return "该备份不存在或无法读取。"
        case .stalePreview: return "本机数据已更新，请重新打开文件并预览后确认。"
        case .operationInProgress: return "账户或同步操作正在进行，请完成后重新预览。"
        case .invalidDateRange: return "开始日期不能晚于结束日期。"
        }
    }
}

/// The store supplies the transaction boundary; the panel owns file pickers,
/// format validation and preview. No credential read is exposed here.
@MainActor
struct DataTransferActions {
    let snapshot: () throws -> RelaySyncData
    let importConfiguration: (ConfigurationImportPreview, RelaySyncData) async throws -> Void
    let restoreBackup: (LocalBackupPreview, RelaySyncData) async throws -> Void
}
