import AppKit

/// Explicit window navigation may save or cancel work; hiding a window does neither.
@MainActor
public final class RelayPageCloseHandler {
    public var prepareToClose: (() -> Bool)?
    public var prepareToTerminate: (() -> Bool)?
    public var confirmDiscard: @MainActor (String) -> Bool
    private var isPreparing = false

    public init(confirmDiscard: (@MainActor (String) -> Bool)? = nil) {
        self.confirmDiscard = confirmDiscard ?? Self.showDiscardConfirmation
    }

    public func requestClose() -> Bool { prepare(prepareToClose) }
    public func requestTermination() -> Bool { prepare(prepareToTerminate ?? prepareToClose) }

    private func prepare(_ action: (() -> Bool)?) -> Bool {
        guard !isPreparing else { return false }
        isPreparing = true
        defer { isPreparing = false }
        return action?() ?? true
    }

    public static func showDiscardConfirmation(_ message: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "放弃未保存的更改？"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃更改")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
