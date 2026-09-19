import SwiftUI

/// Edits non-secret account metadata and optionally replaces the provider credential.
/// Existing secrets are never read into or displayed by the UI.
public struct AccountEditModalView: View {
    public let account: AccountModel
    public var onDismiss: () -> Void
    public var onSave: (String, Decimal?, ProviderCredential?) async throws -> Void

    @State private var displayName: String
    @State private var threshold: String
    @State private var replacementSecret = ""
    @State private var replacementUserID = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    public init(
        account: AccountModel,
        onDismiss: @escaping () -> Void = {},
        onSave: @escaping (String, Decimal?, ProviderCredential?) async throws -> Void = { _, _, _ in }
    ) {
        self.account = account
        self.onDismiss = onDismiss
        self.onSave = onSave
        _displayName = State(initialValue: account.name)
        _threshold = State(initialValue: account.lowBalanceThreshold.map { NSDecimalNumber(decimal: $0).stringValue } ?? "20")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("编辑账号").font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }

            Text(account.baseURL).font(.system(size: 11)).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("显示名称").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("账号名称", text: $displayName).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("低余额阈值（账户原生币种）").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("20", text: $threshold).textFieldStyle(.roundedBorder)
            }

            Divider()
            Text("替换凭据（可选，留空保持不变）")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            SecureField(account.kind == .pipio ? "新的管理令牌" : "新的 API Key", text: $replacementSecret)
                .textFieldStyle(.roundedBorder)
            if account.kind == .pipio {
                TextField("新的 Pipio-User 数值 ID", text: $replacementUserID)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", action: onDismiss).keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("保存") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "显示名称不能为空。"; return }
        let parsedThreshold = Decimal(string: threshold.trimmingCharacters(in: .whitespacesAndNewlines), locale: Locale(identifier: "en_US_POSIX"))
        guard parsedThreshold != nil else { errorMessage = "低余额阈值必须是数字。"; return }

        let secret = replacementSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let userID = replacementUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential: ProviderCredential?
        if secret.isEmpty && userID.isEmpty {
            credential = nil
        } else {
            credential = ProviderCredential(secret: secret, pipioUserID: account.kind == .pipio ? userID : nil)
        }

        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await onSave(name, parsedThreshold, credential)
                isSaving = false
                onDismiss()
            } catch {
                isSaving = false
                if let localized = error as? LocalizedError, let message = localized.errorDescription {
                    errorMessage = message
                } else {
                    errorMessage = "保存失败，请稍后重试。"
                }
            }
        }
    }
}
