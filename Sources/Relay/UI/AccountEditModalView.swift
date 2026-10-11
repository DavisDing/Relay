import SwiftUI

@MainActor
struct AccountEditContainerView: View {
    @ObservedObject var store: RelayStore
    let account: AccountModel
    let onDismiss: () -> Void
    let onSave: (String, Decimal?, ProviderCredential?, ManualExchangeRateUpdate, String?, OptionalStringUpdate, AccountPreferencesUpdate) async throws -> Void
    var body: some View {
        let id = UUID(uuidString: account.id)
        AccountEditModalView(account: account,
            accountConfiguration: id.flatMap { store.accountConfiguration(id: $0) },
            historyBackfillState: id.flatMap { store.historyBackfillStates[$0] },
            onHistoryBackfill: { days in
                guard let id else { return }
                store.startHistoryBackfill(accountID: id, days: days)
            },
            onCancelHistoryBackfill: {
                guard let id else { return }
                store.cancelHistoryBackfill(accountID: id)
            }, onDismiss: onDismiss, onSave: onSave)
    }
}


/// Edits non-secret account metadata and optionally replaces the provider credential.
/// Existing secrets are never read into or displayed by the UI.
public struct AccountEditModalView: View {
    public let account: AccountModel
    public var onDismiss: () -> Void
    public var onSave: (String, Decimal?, ProviderCredential?, ManualExchangeRateUpdate, String?, OptionalStringUpdate, AccountPreferencesUpdate) async throws -> Void

    public let historyBackfillState: HistoryBackfillState?
    public var onHistoryBackfill: (Int) -> Void
    public var onCancelHistoryBackfill: () -> Void
    private let hasPreferencesConfiguration: Bool
    @State private var monthlyBudget: String
    @State private var budgetCurrency: Currency
    @State private var groupName: String
    @State private var isPinned: Bool
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
        accountConfiguration: AccountConfiguration? = nil,
        historyBackfillState: HistoryBackfillState? = nil,
        onHistoryBackfill: @escaping (Int) -> Void = { _ in },
        onCancelHistoryBackfill: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {},
        onSave: @escaping (String, Decimal?, ProviderCredential?, ManualExchangeRateUpdate, String?, OptionalStringUpdate, AccountPreferencesUpdate) async throws -> Void = { _, _, _, _, _, _, _ in }
    ) {
        self.account = account
        self.historyBackfillState = historyBackfillState
        self.onHistoryBackfill = onHistoryBackfill
        self.onCancelHistoryBackfill = onCancelHistoryBackfill
        let configuration = accountConfiguration.flatMap { $0.id.uuidString == account.id ? $0 : nil }
        self.hasPreferencesConfiguration = configuration != nil
        _monthlyBudget = State(initialValue: configuration?.monthlyBudget.map { NSDecimalNumber(decimal: $0.amount).stringValue } ?? "")
        _budgetCurrency = State(initialValue: configuration?.monthlyBudget?.currency ?? account.currency)
        _groupName = State(initialValue: configuration?.groupName ?? "")
        _isPinned = State(initialValue: configuration?.isPinned ?? false)
        self.onDismiss = onDismiss
        self.onSave = onSave
        _manualRate = State(initialValue: account.manualUSDToCNY.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _displayName = State(initialValue: account.name)
        _gatewayURL = State(initialValue: account.baseURL)
        _threshold = State(initialValue: account.lowBalanceThreshold.map { NSDecimalNumber(decimal: $0).stringValue } ?? "20")
    }

    /// Existing six-argument callers edit unrelated metadata without clearing preferences.
    public init(
        account: AccountModel,
        onDismiss: @escaping () -> Void = {},
        onSave: @escaping (String, Decimal?, ProviderCredential?, ManualExchangeRateUpdate, String?, OptionalStringUpdate) async throws -> Void
    ) {
        self.init(account: account, accountConfiguration: nil, onDismiss: onDismiss,
                  onSave: { name, threshold, credential, rate, baseURL, token, _ in
                      try await onSave(name, threshold, credential, rate, baseURL, token)
                  })
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

                    if hasPreferencesConfiguration {
                        Divider()
                        AccountPreferencesFields(monthlyBudget: $monthlyBudget, budgetCurrency: $budgetCurrency,
                                                 groupName: $groupName, isPinned: $isPinned, provider: account.kind)
                    }

                    if hasPreferencesConfiguration && account.kind != .workbuddy2api {
                        Divider()
                        historyBackfillControls
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

    private var hasUnsavedHistoryConfiguration: Bool {
        !replacementSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !replacementUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !replacementDeepSeekUserToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || clearDeepSeekUserToken
    }

    private var historyBackfillControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("历史回填").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                Button("回填近 7 日") { onHistoryBackfill(7) }
                Button("回填近 30 日") { onHistoryBackfill(30) }
            }.buttonStyle(.bordered).controlSize(.small)
                .disabled(!account.isEnabled || historyBackfillState?.isActive == true || hasUnsavedHistoryConfiguration)
            Text(hasUnsavedHistoryConfiguration ? "请先保存凭据变更，再打开编辑账户进行回填。" : account.isEnabled
                ? "仅补齐今天以前的记录；使用已保存的凭据，今天由正常刷新更新。"
                : "账户已停用，启用后可回填历史。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let state = historyBackfillState {
                if state.isActive {
                    HStack {
                        ProgressView(value: state.progress).frame(maxWidth: .infinity)
                        Button("取消回填", action: onCancelHistoryBackfill).controlSize(.small)
                            .disabled(state.phase == .cancelling)
                    }
                }
                Text(state.message).font(.system(size: 10))
                    .foregroundStyle(state.phase == .failed ? Color.red : Color.secondary)
            }
        }
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

        let preferences: AccountPreferencesUpdate
        do {
            if hasPreferencesConfiguration {
                let budget = account.kind == .workbuddy2api ? nil : try BudgetService.parseBudget(monthlyBudget, currency: budgetCurrency)
                try AccountPreferencesValidation.validate(monthlyBudget: budget, groupName: groupName, provider: account.kind)
                preferences = .set(monthlyBudget: budget, groupName: AccountOrganizationService.normalizedGroup(groupName), isPinned: isPinned)
            } else { preferences = .unchanged }
        } catch { errorMessage = error.localizedDescription; return }

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
                    tokenUpdate, preferences)
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
