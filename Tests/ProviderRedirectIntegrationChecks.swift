import Foundation

@main
struct ProviderRedirectIntegrationChecks {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3,
                  let first = URL(string: CommandLine.arguments[1]),
                  let second = URL(string: CommandLine.arguments[2]) else { throw ProviderError.transport }
            let client = URLSessionHTTPClient()
            func request(_ base: URL, _ path: String) -> URLRequest {
                var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 5)
                request.setValue("fixture-token-only", forHTTPHeaderField: "Authorization")
                request.setValue("fixture-id-only", forHTTPHeaderField: "Pipio-User")
                return request
            }
            let (sameBody, sameResponse) = try await client.data(for: request(first, "same"))
            guard sameResponse.statusCode == 200, String(decoding: sameBody, as: UTF8.self) == "authenticated" else { throw ProviderError.transport }
            for path in ["cross", "multi"] {
                let (_, response) = try await client.data(for: request(first, path))
                guard response.statusCode == 302 else { throw ProviderError.transport }
            }
            var post = request(first, "method"); post.httpMethod = "POST"; post.httpBody = Data("fixture-body".utf8)
            let (_, methodResponse) = try await client.data(for: post)
            guard methodResponse.statusCode == 303 else { throw ProviderError.transport }
            let (counter, _) = try await client.data(for: URLRequest(url: second.appendingPathComponent("count"), timeoutInterval: 5))
            guard String(decoding: counter, as: UTF8.self) == "0" else { throw ProviderError.transport }
            print("PASSED: production URLSession delegate follows authenticated same-origin redirect; cross-port, multi-hop escape and POST-to-GET redirect rejected; other-origin received zero requests")
        } catch {
            fputs("FAILED: provider redirect integration fixture\n", stderr)
            exit(1)
        }
    }
}
