import Foundation

/// Organization only changes presentation; aggregate totals always use the
/// store's complete dashboard projection. Gateway children inherit metadata
/// from their top-level parent and remain attached to that parent.
public enum AccountOrganizationService {
    public static func normalizedGroup(_ group: String?) -> String? {
        guard let value = group?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public static func configuration(for account: AccountModel, in configurations: [AccountConfiguration]) -> AccountConfiguration? {
        guard let id = account.parentAccountID ?? UUID(uuidString: account.id) else { return nil }
        return configurations.first { $0.id == id }
    }

    public static func groups(in configurations: [AccountConfiguration]) -> [String] {
        Array(Set(configurations.compactMap { normalizedGroup($0.groupName) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func matches(
        _ account: AccountModel, configurations: [AccountConfiguration], query: String, group: String?
    ) -> Bool {
        let configuration = configuration(for: account, in: configurations)
        if let group, normalizedGroup(configuration?.groupName) != group { return false }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let values = [account.name, account.kind.displayName, account.baseURL, configuration?.displayName ?? "",
                      normalizedGroup(configuration?.groupName) ?? ""]
        return values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    public static func sorted(_ accounts: [AccountModel], configurations: [AccountConfiguration]) -> [AccountModel] {
        let indexed = Array(accounts.enumerated())
        return indexed.sorted { lhs, rhs in
            let left = configuration(for: lhs.element, in: configurations)
            let right = configuration(for: rhs.element, in: configurations)
            let leftPinned = left?.isPinned ?? false
            let rightPinned = right?.isPinned ?? false
            if leftPinned != rightPinned { return leftPinned }
            if left?.id == right?.id { return lhs.offset < rhs.offset }
            let leftOrder = left?.sortOrder ?? lhs.offset
            let rightOrder = right?.sortOrder ?? rhs.offset
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    public static func filtered(
        _ accounts: [AccountModel], configurations: [AccountConfiguration], query: String, group: String?
    ) -> [AccountModel] {
        sorted(accounts.filter { matches($0, configurations: configurations, query: query, group: group) },
               configurations: configurations)
    }
}
