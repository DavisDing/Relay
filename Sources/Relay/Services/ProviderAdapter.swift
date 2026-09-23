import Foundation

public struct NormalizedProviderURLs: Sendable, Equatable {
    public let origin: URL
    public let managementBaseURL: URL
    public let modelBaseURL: URL
}

public enum ProviderURLNormalizer {
    public static func pipio(from input: URL) throws -> NormalizedProviderURLs {
        guard var components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil else {
            if input.scheme?.lowercased() != "https" { throw ProviderError.insecureBaseURL }
            throw ProviderError.invalidBaseURL
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url,
              let management = URL(string: "/api", relativeTo: origin)?.absoluteURL,
              let model = URL(string: "/v1", relativeTo: origin)?.absoluteURL else {
            throw ProviderError.invalidBaseURL
        }
        return .init(origin: origin, managementBaseURL: management, modelBaseURL: model)
    }

    /// WorkBuddy permits plaintext only on a loopback address. Ignore any
    /// supplied path/query so bearer credentials never go to an arbitrary path.
    public static func workbuddyOrigin(from input: URL) throws -> URL {
        guard var components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw ProviderError.invalidBaseURL
        }
        guard scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw ProviderError.insecureBaseURL
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let result = components.url else { throw ProviderError.invalidBaseURL }
        return result
    }

    public static func secureOrigin(from input: URL) throws -> URL {
        guard var components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil else {
            if input.scheme?.lowercased() != "https" { throw ProviderError.insecureBaseURL }
            throw ProviderError.invalidBaseURL
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let result = components.url else { throw ProviderError.invalidBaseURL }
        return result
    }
}

public protocol ProviderAdapter: Sendable {
    var kind: ProviderKind { get }
    func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate
    func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws
    func fetchSnapshot(
        for account: AccountConfiguration,
        credential: ProviderCredential,
        rate: AccountRate,
        now: Date,
        calendar: Calendar
    ) async throws -> ProviderSnapshot

    func performSubAccountAction(
        _ action: ProviderSubAccountAction,
        for account: AccountConfiguration,
        credential: ProviderCredential,
        externalID: String
    ) async throws

    func fetchDailyUsage(
        for account: AccountConfiguration,
        credential: ProviderCredential,
        rate: AccountRate,
        endingAt: Date,
        days: Int,
        calendar: Calendar
    ) async throws -> [DailyUsageRecord]
}

public extension ProviderAdapter {
    func performSubAccountAction(
        _ action: ProviderSubAccountAction,
        for account: AccountConfiguration,
        credential: ProviderCredential,
        externalID: String
    ) async throws {
        throw ProviderError.unsupportedProvider
    }

    func fetchDailyUsage(
        for account: AccountConfiguration,
        credential: ProviderCredential,
        rate: AccountRate,
        endingAt: Date,
        days: Int,
        calendar: Calendar
    ) async throws -> [DailyUsageRecord] {
        []
    }
}

public struct ProviderAdapterRegistry: Sendable {
    private let adapters: [ProviderKind: any ProviderAdapter]

    public init(adapters: [any ProviderAdapter]) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.kind, $0) })
    }

    public func adapter(for kind: ProviderKind) throws -> any ProviderAdapter {
        guard let adapter = adapters[kind] else { throw ProviderError.unsupportedProvider }
        return adapter
    }
}
