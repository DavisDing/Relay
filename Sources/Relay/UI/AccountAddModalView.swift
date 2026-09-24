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
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    public var onDismiss: () -> Void
    public var onSave: (AccountDraft) async throws -> Void
    public var onProbe: (AccountDraft) async throws -> ProviderSnapshot

    public init(
        onDismiss: @escaping () -> Void = {},
        onSave: @escaping (AccountDraft) async throws -> Void = { _ in },
        onProbe: @escaping (AccountDraft) async throws -> ProviderSnapshot = { _ in
            throw ProviderError.unsupportedProvider
        }
    ) {
        self.onDismiss = onDismiss
        self.onSave = onSave
        self.onProbe = onProbe
    }

    public var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("添加服务商账号")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("返回首页")
                .accessibilityLabel("返回首页")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("账号显示名称")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        TextField("例如：主力生产、备用开发", text: $accountName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("服务商平台")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Picker("", selection: $selectedProvider) {
                            ForEach(ProviderKind.supportedCases, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                .padding(.horizontal, 20)
            }

            Divider().opacity(0.3)

            HStack {
                Button(action: testConnection) {
                    HStack(spacing: 4) {
                        if isTesting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "bolt.badge.checkmark") }
                        Text("测活与探测能力")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isTesting || isSaving)

                Spacer()

                Button("取消", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 8)

                Button(isSaving ? "保存中…" : "保存到本机", action: saveAccount)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isTesting || isSaving || accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: RelayVisualStyle.panelWidth, height: 500)
        .relayPanelSurface(cornerRadius: RelayVisualStyle.panelCornerRadius)
    }

    private var pipioFormSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("Pipio Base URL", text: $pipioBaseURL, placeholder: "https://pipio.io")
            Text("自动移除 /v1 及 /api；管理接口走 /api，模型接口走 /v1")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            labeledField("Pipio User ID（纯数字）", text: $pipioUserId, placeholder: "例如：10283")
            VStack(alignment: .leading, spacing: 4) {
                Text("Pipio 管理 Token（仅本机保存）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                SecureField("sk-••••••••••••••••", text: $pipioToken)
                    .textFieldStyle(.roundedBorder)
                Text("不使用 Keychain；仅写入 Relay 私有数据目录，文件权限 0600")
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
                SecureField("Bearer API Key", text: $workbuddyApiKey).textFieldStyle(.roundedBorder)
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
                    .textFieldStyle(.roundedBorder)
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
                    .textFieldStyle(.roundedBorder)
                Text("不使用 Keychain；仅写入 Relay 私有数据目录，文件权限 0600")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("DeepSeek 平台 userToken（可选）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                SecureField("填写后获取历史用量和消费", text: $deepseekUserToken)
                    .textFieldStyle(.roundedBorder)
                Text("不填写只获取余额；填写后首次回填最近 7 天。仅使用你手动输入的 token，不读取浏览器 Cookie；平台历史接口是内部接口，可能失效。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
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
        return AccountDraft(
            displayName: accountName,
            providerKind: selectedProvider,
            baseURL: baseURL,
            credential: credential,
            lowBalanceThreshold: selectedProvider == .workbuddy2api ? nil : Decimal(20)
        )
    }

    private func testConnection() {
        errorMessage = nil
        statusMessage = nil
        isTesting = true
        Task {
            do {
                let snapshot = try await onProbe(try makeDraft())
                statusMessage = probeDescription(snapshot)
            } catch {
                errorMessage = userFacingMessage(error)
            }
            isTesting = false
        }
    }

    private func saveAccount() {
        errorMessage = nil
        statusMessage = nil
        isSaving = true
        Task {
            do {
                try await onSave(try makeDraft())
                onDismiss()
            } catch {
                errorMessage = userFacingMessage(error)
                isSaving = false
            }
        }
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
