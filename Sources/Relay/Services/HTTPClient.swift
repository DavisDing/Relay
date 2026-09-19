import Foundation

public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.transport
            }
            return (data, httpResponse)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport
        }
    }
}

public enum HTTPResponseValidator {
    public static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw ProviderError.unauthorized
        case 403:
            throw ProviderError.forbidden
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        case 500..<600:
            throw ProviderError.server(statusCode: response.statusCode)
        default:
            throw ProviderError.server(statusCode: response.statusCode)
        }
    }
}
