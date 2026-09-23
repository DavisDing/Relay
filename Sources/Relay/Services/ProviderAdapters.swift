import Foundation

public extension ProviderAdapterRegistry {
    static func production(
        pipioRateRefreshInterval: RateRefreshInterval = .weekly,
        client: any HTTPClient = URLSessionHTTPClient()
    ) -> ProviderAdapterRegistry {
        ProviderAdapterRegistry(adapters: [
            PipioAdapter(client: client, rateRefreshInterval: pipioRateRefreshInterval),
            DeepSeekAdapter(client: client),
            WorkBuddy2APIAdapter(client: client)
        ])
    }
}
