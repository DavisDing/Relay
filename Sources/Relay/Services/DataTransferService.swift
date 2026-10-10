import Foundation

public enum DataTransferService {
    public static let maximumFileBytes = 20 * 1_024 * 1_024
    public static let maximumAccounts = 1_000
    public static let maximumHistoryRecords = 200_000

    public static func exportConfiguration(_ data: RelaySyncData) throws -> Data {
        let archive = RelayConfigurationArchive(accounts: data.accounts, settings: data.settings, exportedAt: data.exportedAt)
        try validateAccounts(archive.accounts)
        try validateSettings(archive.settings)
        return try encoder().encode(archive)
    }

    public static func previewConfiguration(_ bytes: Data, existingAccountIDs: Set<UUID>) throws -> ConfigurationImportPreview {
        let object = try jsonObject(bytes)
        let allowed: Set<String> = ["format", "schemaVersion", "exportedAt", "accounts", "settings"]
        guard Set(object.keys).isSubset(of: allowed) else { throw DataTransferError.forbiddenField }
        guard object["format"] as? String == "relay-configuration" else { throw DataTransferError.invalidFormat }
        guard object["schemaVersion"] as? Int == RelayConfigurationArchive.currentSchemaVersion else {
            throw DataTransferError.unsupportedVersion
        }
        try rejectSensitiveFields(object)
        try validateConfigurationKeys(object)
        let decoded: RelayConfigurationArchive
        do { decoded = try decoder().decode(RelayConfigurationArchive.self, from: bytes) }
        catch { throw DataTransferError.invalidFormat }
        try validateAccounts(decoded.accounts)
        try validateSettings(decoded.settings)
        guard decoded.exportedAt.timeIntervalSince1970.isFinite else { throw DataTransferError.invalidFormat }
        let sanitized = RelayConfigurationArchive(accounts: decoded.accounts, settings: decoded.settings, exportedAt: decoded.exportedAt)
        return ConfigurationImportPreview(archive: sanitized, existingAccountIDs: existingAccountIDs)
    }

    public static func exportBackup(_ data: RelaySyncData) throws -> Data {
        let safe = RelaySyncDataSafety.sanitized(data)
        try validateBackup(safe)
        let bytes = try encoder().encode(safe)
        guard bytes.count <= maximumFileBytes else { throw DataTransferError.tooLarge }
        return bytes
    }

    public static func decodeBackup(_ bytes: Data) throws -> RelaySyncData {
        let object = try jsonObject(bytes)
        let allowed: Set<String> = ["schemaVersion", "exportedAt", "accounts", "snapshots", "dailyUsage", "settingsUpdatedAt", "settings", "deletedAccountIDs"]
        guard Set(object.keys).isSubset(of: allowed) else { throw DataTransferError.forbiddenField }
        guard object["schemaVersion"] as? Int == RelaySyncData.currentSchemaVersion else { throw DataTransferError.unsupportedVersion }
        try rejectSensitiveFields(object)
        let decoded: RelaySyncData
        do { decoded = try decoder().decode(RelaySyncData.self, from: bytes) }
        catch { throw DataTransferError.invalidFormat }
        try validateBackup(decoded)
        return RelaySyncDataSafety.sanitized(decoded)
    }

    /// Rows reflect recorded provider days only. Missing monetary values are
    /// blank and explicitly labelled unknown, never fabricated as zero.
    public static func exportUsageCSV(
        _ data: RelaySyncData,
        accountIDs: Set<UUID>? = nil,
        from start: Date,
        through end: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> Data {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last else { throw DataTransferError.invalidDateRange }
        let accounts = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.id, $0) })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let rows = data.dailyUsage.filter { record in
            let day = calendar.startOfDay(for: record.day)
            return day >= first && day <= last && accounts[record.accountID] != nil && (accountIDs?.contains(record.accountID) ?? true)
        }.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.accountID.uuidString < $1.accountID.uuidString
        }
        var lines = ["account_id,account_name,provider,date,amount,currency,status"]
        for row in rows {
            guard let account = accounts[row.accountID] else { continue }
            let amount = row.spend.map { NSDecimalNumber(decimal: $0.amount).stringValue } ?? ""
            let fields = [row.accountID.uuidString, account.displayName, account.providerKind.rawValue,
                          formatter.string(from: row.day), amount, row.spend?.currency.rawValue ?? "",
                          row.spend == nil ? "unknown" : "recorded"]
            lines.append(fields.enumerated().map { index, field in csvField(field, protectFormula: index != 4) }.joined(separator: ","))
        }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func csvField(_ value: String, protectFormula: Bool) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let first = trimmed.first
        let dangerous = first.map { "=+-@\t\r\n".contains($0) } ?? false
        let text = protectFormula && dangerous ? "'" + value : value
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumFileBytes else { throw DataTransferError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DataTransferError.invalidFormat }
        return object
    }

    private static func rejectSensitiveFields(_ value: Any) throws {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let normalized = key.lowercased().replacingOccurrences(of: "_", with: "")
                if ["secret", "token", "apikey", "authorization", "cookie", "password", "credentials", "pipiouserid", "deepseekusertoken"].contains(normalized) {
                    throw DataTransferError.forbiddenField
                }
                try rejectSensitiveFields(child)
            }
        } else if let array = value as? [Any] {
            for child in array { try rejectSensitiveFields(child) }
        }
    }

    private static func validateConfigurationKeys(_ object: [String: Any]) throws {
        guard let accounts = object["accounts"] as? [[String: Any]], let settings = object["settings"] as? [String: Any] else {
            throw DataTransferError.invalidFormat
        }
        let accountKeys: Set<String> = ["id", "displayName", "providerKind", "siteOrigin", "credentialReference", "isEnabled", "isHidden",
            "lowBalanceThreshold", "manualUSDToCNY", "monthlyBudget", "groupName", "isPinned", "sortOrder", "createdAt", "updatedAt"]
        let settingKeys: Set<String> = ["schemaVersion", "refreshIntervalSeconds", "showTodayInMenuBar", "baseCurrency",
            "defaultLowBalanceThreshold", "historyRetention", "iCloudFileSyncEnabled"]
        guard Set(settings.keys).isSubset(of: settingKeys), accounts.allSatisfy({ Set($0.keys).isSubset(of: accountKeys) }) else {
            throw DataTransferError.forbiddenField
        }
        for account in accounts {
            if let budget = account["monthlyBudget"] as? [String: Any], !Set(budget.keys).isSubset(of: ["amount", "currency"]) {
                throw DataTransferError.forbiddenField
            }
        }
    }

    private static func validateAccounts(_ accounts: [AccountConfiguration]) throws {
        guard accounts.count <= maximumAccounts, Set(accounts.map(\.id)).count == accounts.count else { throw DataTransferError.invalidAccounts }
        for account in accounts {
            guard !account.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  account.displayName.count <= 200,
                  let components = URLComponents(url: account.siteOrigin, resolvingAgainstBaseURL: false),
                  (components.scheme?.lowercased() == "https" ||
                    (account.providerKind == .workbuddy2api && components.scheme?.lowercased() == "http" &&
                      ["localhost", "127.0.0.1", "::1", "[::1]"].contains(components.host?.lowercased() ?? ""))),
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  components.path.isEmpty || components.path == "/",
                  account.sortOrder >= 0, account.sortOrder <= 1_000_000,
                  account.createdAt.timeIntervalSince1970.isFinite,
                  account.updatedAt.timeIntervalSince1970.isFinite,
                  account.lowBalanceThreshold.map({ validMoney($0) }) ?? true,
                  account.manualUSDToCNY.map({ validMoney($0) && $0 > 0 }) ?? true,
                  account.monthlyBudget.map({ validMoney($0.amount) && $0.amount > 0 }) ?? true,
                  account.groupName.map({ $0.count <= 40 && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true
            else { throw DataTransferError.invalidAccounts }
        }
    }

    private static func validateSettings(_ settings: RelaySettings) throws {
        guard settings.schemaVersion == RelaySettings.currentSchemaVersion else { throw DataTransferError.unsupportedVersion }
        guard settings.refreshIntervalSeconds >= 60, settings.refreshIntervalSeconds <= 86_400,
              validMoney(settings.defaultLowBalanceThreshold) else { throw DataTransferError.invalidSettings }
    }

    private static func validateBackup(_ data: RelaySyncData) throws {
        guard data.schemaVersion == RelaySyncData.currentSchemaVersion else { throw DataTransferError.unsupportedVersion }
        try validateAccounts(data.accounts)
        try validateSettings(data.settings)
        let ids = Set(data.accounts.map(\.id))
        guard data.dailyUsage.count <= maximumHistoryRecords, data.snapshots.count <= maximumAccounts,
              Set(data.dailyUsage.map(\.id)).count == data.dailyUsage.count,
              Set(data.snapshots.map(\.accountID)).count == data.snapshots.count,
              data.deletedAccountIDs.count <= maximumAccounts,
              data.exportedAt.timeIntervalSince1970.isFinite else { throw DataTransferError.invalidUsage }
        for record in data.dailyUsage {
            guard ids.contains(record.accountID), record.day.timeIntervalSince1970.isFinite,
                  record.updatedAt.timeIntervalSince1970.isFinite,
                  record.spend.map({ validMoney($0.amount) }) ?? true else { throw DataTransferError.invalidUsage }
        }
        for snapshot in data.snapshots {
            guard ids.contains(snapshot.accountID), snapshot.rate.accountID == snapshot.accountID,
                  snapshot.fetchedAt.timeIntervalSince1970.isFinite,
                  [snapshot.balance, snapshot.todaySpend, snapshot.monthSpend].compactMap({ $0 }).allSatisfy({ validMoney($0.amount) })
            else { throw DataTransferError.invalidUsage }
        }
    }

    private static func validMoney(_ value: Decimal) -> Bool { !value.isNaN && value >= 0 && value <= Decimal(1_000_000_000_000) }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
