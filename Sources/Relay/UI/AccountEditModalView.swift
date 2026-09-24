import SwiftUI

/// Edits non-secret account metadata and optionally replaces the provider credential.
/// Existing secrets are never read into or displayed by the UI.
public struct AccountEditModalView: View {
    public let account: AccountModel
    public var onDismiss: () -> Void
    public var onSave: (String, Decimal?, ProviderCredential?, ManualExchangeRateUpdate, String?, OptionalStringUpdate) async throws -> Void

    @State private var displayName: String
    @State private var threshold: String
    @State private var manualRate: String
    @State private var replacementSecret = ""
    @State private var gatewayURL: String
    @State private var replacementUserID = ""
    @State private var replacementDeepSeekUserToken = ""
    @State private var clearDeepSeekUserToken = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    public init(
        account: AccountModel,
        onDismiss: @escaping () -> Void = {},
        onSave: @escaping (String, Decimal?, ProviderCredential?, ManualExchangeRateUpdate, String?, OptionalStringUpdate) async throws -> Void = { _, _, _, _, _, _ in }
    ) {
        self.account = account
        self.onDismiss = onDismiss
        self.onSave = onSave
        _manualRate = State(initialValue: account.manualUSDToCNY.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _displayName = State(initialValue: account.name)
        _gatewayURL = State(initialValue: account.baseURL)
        _threshold = State(initialValue: account.lowBalanceThreshold.map { NSDecimalNumber(decimal: $0).stringValue } ?? "20")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("编辑账号").font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("返回首页")
                    .accessibilityLabel("返回首页")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if account.kind == .workbuddy2api {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("网关地址").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            TextField("http://localhost:7863", text: $gatewayURL).textFieldStyle(.roundedBorder)
                        }
                    } else {
                        Text(account.baseURL).font(.system(size: 11)).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("显示名称").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        TextField("账号名称", text: $displayName).textFieldStyle(.roundedBorder)
                    }

                    if account.kind != .workbuddy2api { VStack(alignment: .leading, spacing: 6) {
                        Text("低余额阈值（账户原生币种）").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        TextField("20", text: $threshold).textFieldStyle(.roundedBorder)
                    } }

                    if account.kind != .workbuddy2api && (account.kind == .pipio || account.currency == .usd) {
                        Divider()
                        exchangeRateFields
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
                    if account.kind == .deepseek {
                        SecureField("新的平台 userToken（留空保持不变）", text: $replacementDeepSeekUserToken)
                            .textFieldStyle(.roundedBorder)
                        Toggle("清空已保存的 userToken", isOn: $clearDeepSeekUserToken)
                            .font(.system(size: 11))
                        Text("不填写且不勾选不会修改；填写后用于历史用量；勾选会清空并恢复为仅查询余额。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(2)
            }
            .disabled(isSaving)

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
        .frame(width: RelayVisualStyle.panelWidth)
        .frame(maxHeight: .infinity)
        .relayPanelSurface(cornerRadius: RelayVisualStyle.panelCornerRadius)
    }

    private var exchangeRateFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            if account.kind == .pipio {
                Text("额度换算参数（站点提供，只读）")
                    .font(.system(size: 12, weight: .semibold))
                Text("quota_per_unit：\(number(account.quotaPerUnit))")
                    .font(.system(size: 12, design: .monospaced))
                Text("原生金额 = 额度 ÷ quota_per_unit；此参数不是美元/人民币汇率。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("美元 / 人民币汇率")
                .font(.system(size: 12, weight: .semibold))
            Text("站点汇率：\(number(account.siteUSDToCNY))\(account.siteRateIsExpired ? "（已过期）" : "")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text("1 USD =")
                TextField("自动（可手动填写）", text: $manualRate)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("手动美元人民币汇率")
                Text("CNY")
            }
            .font(.system(size: 12))
            Text("手动值优先，自动刷新不会覆盖；留空恢复站点汇率。站点未提供且未填写时，不进行人民币换算。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func number(_ value: Decimal?) -> String {
        value.map { NSDecimalNumber(decimal: $0).stringValue } ?? "未获取"
    }

    private func save() {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "显示名称不能为空。"; return }
        let parsedThreshold = Decimal(string: threshold.trimmingCharacters(in: .whitespacesAndNewlines), locale: Locale(identifier: "en_US_POSIX"))
        guard account.kind == .workbuddy2api || parsedThreshold != nil else { errorMessage = "低余额阈值必须是数字。"; return }

        let rateUpdate: ManualExchangeRateUpdate
        do {
            rateUpdate = account.kind == .pipio || account.currency == .usd
                ? .set(try USDToCNYRate.parseOverride(manualRate)) : .unchanged
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let secret = replacementSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let userID = replacementUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential: ProviderCredential?
        if secret.isEmpty && userID.isEmpty {
            credential = nil
        } else {
            credential = ProviderCredential(secret: secret, pipioUserID: account.kind == .pipio ? userID : nil)
        }
        let tokenUpdate: OptionalStringUpdate
        if account.kind != .deepseek {
            tokenUpdate = .unchanged
        } else if clearDeepSeekUserToken {
            tokenUpdate = .set(nil)
        } else {
            let token = replacementDeepSeekUserToken.trimmingCharacters(in: .whitespacesAndNewlines)
            tokenUpdate = token.isEmpty ? .unchanged : .set(token)
        }

        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await onSave(name, account.kind == .workbuddy2api ? nil : parsedThreshold, credential, rateUpdate,
                    account.kind == .workbuddy2api && gatewayURL != account.baseURL ? gatewayURL : nil,
                    tokenUpdate)
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
