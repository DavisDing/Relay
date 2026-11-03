import SwiftUI

/// 添加服务商账号。所有“测活”与保存动作都走真实业务层，不在 UI 中伪造余额。
public struct AccountAddModalView: View {
    @State private var accountName = ""
    @State private var selectedProvider: ProviderKind = .pipio
    @State private var pipioBaseURL = "https://pipio.io"
    @State private var pipioUserId = ""
    @State private var pipioToken = ""
    @State private var deepseekBaseURL = "https://api.deepseek.com"
    @State private var deepseekApiKey = ""
    @State private var deepseekUserToken = ""
    @State private var workbuddyBaseURL = "http://localhost:7863"
    @State private var workbuddyApiKey = ""
    @State private var monthlyBudget = ""
    @State private var budgetCurrency: Currency = .cny
    @State private var groupName = ""
    @State private var isPinned = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var activeOperation: Task<Void, Never>?
    @State private var initialFormValues: [String]?
    @State private var didSave = false
    private let closeHandler: RelayPageCloseHandler?

    public var onDismiss: () -> Void
    public var onSave: (AccountDraft) async throws -> Void
    public var onProbe: (AccountDraft) async throws -> ProviderSnapshot

    public init(
        closeHandler: RelayPageCloseHandler? = nil,
        onDismiss: @escaping () -> Void = {},
        onSave: @escaping (AccountDraft) async throws -> Void = { _ in },
        onProbe: @escaping (AccountDraft) async throws -> ProviderSnapshot = { _ in
            throw ProviderError.unsupportedProvider
        }
    ) {
        self.closeHandler = closeHandler
        self.onDismiss = onDismiss
        self.onSave = onSave
        self.onProbe = onProbe
    }

    public var body: some View {
        VStack(spacing: 0) {
            RelayPageHeader(title: "添加账户", onBack: cancelForm)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        labeledField("账户名称", text: $accountName, placeholder: "例如：个人、工作")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("供应商").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Picker("供应商", selection: $selectedProvider) {
                                ForEach(ProviderKind.supportedCases, id: \.self) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .labelsHidden().pickerStyle(.menu).controlSize(.small)
                            .frame(height: RelayVisualStyle.inputHeight)
                        }
                        .frame(width: 132, alignment: .leading)
                    }

                    Divider().opacity(0.4)

                    switch selectedProvider {
                    case .pipio:
                        pipioFormSection
                    case .deepseek:
                        deepseekFormSection
                    case .workbuddy2api:
                        workbuddyFormSection
                    case .custom:
                        Text("自定义兼容端点属于后续扩展，当前版本未启用。")
                            .foregroundColor(.secondary)
                    }

                    Divider().opacity(0.4)
                    AccountPreferencesFields(monthlyBudget: $monthlyBudget, budgetCurrency: $budgetCurrency,
                                             groupName: $groupName, isPinned: $isPinned, provider: selectedProvider)

                    if let statusMessage {
                        Label(statusMessage, systemImage: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            }

            .disabled(isSaving || isTesting)

            RelayPageFooter {
                Button(action: testConnection) {
                    HStack(spacing: 5) {
                        if isTesting { ProgressView().controlSize(.mini) }
                        Text(isTesting ? "测试中…" : "测试连接")
                    }
                }
                .buttonStyle(RelayTextButtonStyle())
                .disabled(isTesting || isSaving)

                Spacer(minLength: 4)

                Button("取消", action: cancelForm)
                    .buttonStyle(RelayTextButtonStyle())
                    .keyboardShortcut(.cancelAction)

                Button("保存", action: saveAccount)
                    .buttonStyle(RelayPrimaryCapsuleButtonStyle(isLoading: isSaving))
                    .disabled(isTesting || isSaving || accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: RelayVisualStyle.formPanelWidth, height: RelayVisualStyle.formPanelHeight)
        .relayPanelSurface(cornerRadius: RelayVisualStyle.panelCornerRadius)
        .onAppear {
            if initialFormValues == nil { initialFormValues = formValues }
            closeHandler?.prepareToClose = prepareToClose
        }
        .onDisappear {
            activeOperation?.cancel()
            closeHandler?.prepareToClose = nil
        }
    }

    private var pipioFormSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                labeledField("站点地址", text: $pipioBaseURL, placeholder: "https://pipio.io")
                labeledField("User ID（数字）", text: $pipioUserId, placeholder: "10283").frame(width: 104)
            }
            Text("填写站点地址即可，无需添加接口路径。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Pipio 管理 Token（仅本机保存）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                SecureField("sk-••••••••••••••••", text: $pipioToken)
                    .relayFormField()
                Text("凭据仅保存在此 Mac，不参与同步或导出。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
    }

    private var workbuddyFormSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("网关地址（本机 HTTP 或远端 HTTPS）", text: $workbuddyBaseURL, placeholder: "http://localhost:7863")
            VStack(alignment: .leading, spacing: 4) {
                Text("网关 API Key（仅本机保存）").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                SecureField("Bearer API Key", text: $workbuddyApiKey).relayFormField()
            }
            Text("从 /status 读取内部账号积分；管理操作需要网关启用 admin.enabled。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var deepseekFormSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DeepSeek API Base URL")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("https://api.deepseek.com", text: $deepseekBaseURL)
                    .relayFormField()
                    .disabled(true)
                Text("余额使用官方接口返回的真实人民币，不套用 Pipio 汇率")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("DeepSeek API Key（仅本机保存）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                SecureField("sk-••••••••••••••••", text: $deepseekApiKey)
                    .relayFormField()
                Text("凭据仅保存在此 Mac，不参与同步或导出。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("DeepSeek 平台 userToken（可选）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                SecureField("填写后获取历史用量和消费", text: $deepseekUserToken)
                    .relayFormField()
                Text("不填写只获取余额；填写后首次回填最近 7 天。仅使用你手动输入的 token，不读取浏览器 Cookie；平台历史接口是内部接口，可能失效。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .relayFormField()
        }
    }

    private func makeDraft() throws -> AccountDraft {
        let credential: ProviderCredential
        let baseURL: String
        switch selectedProvider {
        case .pipio:
            baseURL = pipioBaseURL
            credential = ProviderCredential(
                secret: pipioToken,
                pipioUserID: pipioUserId.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .deepseek:
            baseURL = deepseekBaseURL
            credential = ProviderCredential(
                secret: deepseekApiKey,
                deepSeekUserToken: deepseekUserToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : deepseekUserToken.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .workbuddy2api:
            baseURL = workbuddyBaseURL
            credential = ProviderCredential(secret: workbuddyApiKey)
        case .custom:
            throw ProviderError.unsupportedProvider
        }
        let parsedBudget = selectedProvider == .workbuddy2api ? nil : try BudgetService.parseBudget(monthlyBudget, currency: budgetCurrency)
        try AccountPreferencesValidation.validate(monthlyBudget: parsedBudget, groupName: groupName, provider: selectedProvider)
        return AccountDraft(
            displayName: accountName,
            providerKind: selectedProvider,
            baseURL: baseURL,
            credential: credential,
            lowBalanceThreshold: selectedProvider == .workbuddy2api ? nil : Decimal(20),
            monthlyBudget: parsedBudget,
            groupName: AccountOrganizationService.normalizedGroup(groupName),
            isPinned: isPinned
        )
    }

    private func testConnection() {
        errorMessage = nil
        statusMessage = nil
        isTesting = true
        activeOperation?.cancel()
        activeOperation = Task { @MainActor in
            do {
                let snapshot = try await onProbe(try makeDraft())
                try Task.checkCancellation()
                statusMessage = probeDescription(snapshot)
            } catch {
                if Task.isCancelled { return }
                errorMessage = userFacingMessage(error)
            }
            isTesting = false
            activeOperation = nil
        }
    }

    private func saveAccount() {
        errorMessage = nil
        statusMessage = nil
        isSaving = true
        activeOperation?.cancel()
        activeOperation = Task { @MainActor in
            do {
                try await onSave(try makeDraft())
                guard !Task.isCancelled else { return }
                activeOperation = nil
                didSave = true
                onDismiss()
            } catch {
                if Task.isCancelled { return }
                errorMessage = userFacingMessage(error)
                isSaving = false
                activeOperation = nil
            }
        }
    }

    private func cancelForm() {
        if closeHandler != nil { onDismiss() }
        else if prepareToClose() { onDismiss() }
    }

    private var formValues: [String] {
        [accountName, selectedProvider.rawValue, pipioBaseURL, pipioUserId, pipioToken,
         deepseekBaseURL, deepseekApiKey, deepseekUserToken, workbuddyBaseURL, workbuddyApiKey,
         monthlyBudget, budgetCurrency.rawValue, groupName, String(isPinned)]
    }

    private func prepareToClose() -> Bool {
        if !didSave && (formValues != initialFormValues || isTesting || isSaving) {
            let confirm = closeHandler?.confirmDiscard ?? RelayPageCloseHandler.showDiscardConfirmation
            guard confirm("账户尚未保存。放弃后将取消在途操作并丢弃输入。") || didSave else { return false }
        }
        activeOperation?.cancel()
        return true
    }

    private func probeDescription(_ snapshot: ProviderSnapshot) -> String {
        if let children = snapshot.subAccounts {
            let points = snapshot.creditMetrics?.available.map { RelayNumberFormatter.decimal($0) } ?? "--"
            return "网关连接成功：\(children.count) 个内部账号，可用积分 \(points)"
        }
        let balance = snapshot.balance.map { "余额 \(RelayNumberFormatter.money($0.amount, currency: $0.currency))" } ?? "余额 --"
        let today = snapshot.todaySpend.map { "今日消耗 \(RelayNumberFormatter.money($0.amount, currency: $0.currency))" } ?? "今日消耗未支持"
        return "端点验证成功：\(balance)，\(today)"
    }

    private func userFacingMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "请求失败，请检查网络和凭据。"
    }
}
