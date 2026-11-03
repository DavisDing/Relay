import Foundation

/// Explicit window navigation may save or cancel work; hiding a window does neither.
@MainActor
public final class RelayPageCloseHandler {
    public var prepareToClose: (() -> Bool)?

    public init() {}

    public func requestClose() -> Bool { prepareToClose?() ?? true }
}
