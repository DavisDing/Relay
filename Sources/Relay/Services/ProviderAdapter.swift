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
