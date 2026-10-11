import Foundation

public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Provider redirects stay inside the original origin. Copy authentication only
/// after checking scheme, host and normalized port, never onto another origin.
enum ProviderRedirectPolicy {
    static func redirectedRequest(original: URLRequest, proposed: URLRequest) -> URLRequest? {
        guard original.httpMethod == proposed.httpMethod, let from = original.url, let to = proposed.url,
              let a = URLComponents(url: from, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: to, resolvingAgainstBaseURL: false),
              a.user == nil, a.password == nil, b.user == nil, b.password == nil,
              a.scheme?.lowercased() == b.scheme?.lowercased(), a.host?.lowercased() == b.host?.lowercased(),
              (a.port ?? (a.scheme?.lowercased() == "https" ? 443 : 80)) == (b.port ?? (b.scheme?.lowercased() == "https" ? 443 : 80)),
              b.scheme?.lowercased() == "https" || (b.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(b.host?.lowercased() ?? ""))
        else { return nil }
        var safe = proposed
        for header in ["Authorization", "Pipio-User", "Cookie", "X-API-Key"] {
            safe.setValue(original.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
        }
        return safe
    }
}

private final class ProviderRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(task.originalRequest.flatMap { ProviderRedirectPolicy.redirectedRequest(original: $0, proposed: request) })
    }
}

public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: configuration, delegate: ProviderRedirectDelegate(), delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.transport
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport
        }
    }
}

public enum HTTPResponseValidator {
    static func retryAfterInterval(_ raw: String, now: Date = Date()) -> TimeInterval? {
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw).map { max(0, $0.timeIntervalSince(now)) }
    }

    public static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw ProviderError.unauthorized
        case 403:
            throw ProviderError.forbidden
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { retryAfterInterval($0) }
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        case 500..<600:
            throw ProviderError.server(statusCode: response.statusCode)
        default:
            throw ProviderError.server(statusCode: response.statusCode)
        }
    }
}
