import Foundation

public enum ProviderError: Error, Sendable, Equatable, LocalizedError {
    case invalidBaseURL
    case insecureBaseURL
    case invalidCredential
    case missingPipioUserID
    case invalidPipioUserID
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case server(statusCode: Int)
    case transport
    case incompatibleResponse
    case missingRate
    case unsupportedProvider

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "站点地址无效。"
        case .insecureBaseURL: return "仅允许使用 HTTPS 站点。"
        case .invalidCredential: return "凭据不能为空。"
        case .missingPipioUserID: return "Pipio-User 为必填项。"
        case .invalidPipioUserID: return "Pipio-User 必须是正整数。"
        case .unauthorized: return "凭据无效或凭据类型不匹配。"
        case .forbidden: return "当前凭据没有访问权限。"
        case .rateLimited: return "请求过于频繁，请稍后重试。"
        case .server(let code): return "供应商服务暂时不可用（HTTP \(code)）。"
        case .transport: return "网络请求失败。"
        case .incompatibleResponse: return "供应商响应格式不兼容。"
        case .missingRate: return "账户缺少可靠的汇率或配额换算参数。"
        case .unsupportedProvider: return "当前供应商暂未实现。"
        }
    }
}
