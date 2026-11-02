import Foundation

/// Presentation only: membership follows the provider and canonical origin, never
/// a display name. Paths, queries and credentials are not part of site identity.
public struct SiteAccountGroup: Identifiable, Sendable {
    public let id: String
    public let kind: ProviderKind
    public let address: String
    public let parents: [AccountModel]
    public let accounts: [AccountModel]
    public let matchingAccounts: [AccountModel]

    public var enabledParentIDs: Set<UUID> {
        Set(parents.filter { $0.isEnabled }.compactMap { UUID(uuidString: $0.id) })
    }
    public var warningCount: Int {
        accounts.filter { if case .ok = $0.status { return false }; return true }.count
    }

    public static func groups(
        parents: [AccountModel], dashboardAccounts: [AccountModel],
        configurations: [AccountConfiguration], query: String = "", group: String? = nil
    ) -> [SiteAccountGroup] {
        let visible = AccountOrganizationService.sorted(parents.filter { !$0.isHidden }, configurations: configurations)
        var order: [String] = []
        var buckets: [String: [AccountModel]] = [:]
        for parent in visible {
            let key = identity(for: parent)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(parent)
        }
        return order.compactMap { key in
            guard let members = buckets[key], let first = members.first else { return nil }
            let rows = members.flatMap { parent -> [AccountModel] in
                guard parent.kind == .workbuddy2api, let id = UUID(uuidString: parent.id) else { return [parent] }
                let children = dashboardAccounts.filter { $0.parentAccountID == id }
                // Missing/empty gateway data must leave a visible route to diagnostics,
                // refresh and editing instead of making that site disappear.
                return children.isEmpty ? [parent] : children
            }
            let matches = AccountOrganizationService.filtered(rows, configurations: configurations, query: query, group: group)
            guard !matches.isEmpty else { return nil }
            return SiteAccountGroup(id: key, kind: first.kind, address: displayAddress(for: first),
                                    parents: members, accounts: rows, matchingAccounts: matches)
        }
    }

    public static func identity(for account: AccountModel) -> String {
        guard let origin = normalizedOrigin(account.baseURL) else {
            return account.kind.rawValue + "|invalid:" + account.id
        }
        return account.kind.rawValue + "|" + origin
    }

    public static func displayAddress(for account: AccountModel) -> String {
        guard let origin = normalizedOrigin(account.baseURL), let url = URL(string: origin), let host = url.host else {
            return "站点地址不可用"
        }
        return host + (url.port.map { ":\($0)" } ?? "")
    }

    private static func normalizedOrigin(_ string: String) -> String? {
        guard let input = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = input.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = input.host?.lowercased(), !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        let defaultPort = scheme == "https" ? 443 : 80
        origin.port = input.port == defaultPort ? nil : input.port
        return origin.string
    }
}
