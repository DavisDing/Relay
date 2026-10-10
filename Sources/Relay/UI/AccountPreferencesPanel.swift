import SwiftUI

/// Account-level organization and budget editor. It writes metadata only and
/// never asks for credentials or makes a provider request.
public struct AccountPreferencesPanel: View {
    @ObservedObject private var store: RelayStore
    public let accountID: UUID
    @State private var amount = ""
    @State private var currency: Currency = .cny
    @State private var group = ""
    @State private var pinned = false
    @State private var error: String?
    @State private var saved = false

    public init(store: RelayStore, accountID: UUID) { self.store = store; self.accountID = accountID }

    public var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let configuration = store.accountConfiguration(id: accountID) {
                Text("\(configuration.displayName) · 分组与预算").font(.headline)
                TextField("分组名称（留空表示未分组）", text: $group)
                Toggle("置顶账号", isOn: $pinned)
                if configuration.providerKind != .workbuddy2api {
                    HStack {
                        TextField("每月预算（留空关闭）", text: $amount)
                        Picker("预算币种", selection: $currency) {
                            ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 90)
                    }
                    Text("以服务商月消费的原始币种比较；在数据设置开启预算提醒后，达到 80% 和 100% 时通知。消费未知或币种不同会显示无法判断。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("此网关尚无可靠的月消费，暂不支持月预算。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if saved { Label("已保存", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                HStack {
                    Spacer()
                    Button("保存") { save(configuration) }.buttonStyle(.borderedProminent)
                        .disabled(!store.storageAvailability.isAvailable)
                }
            } else {
                Text("账号已移除或暂时无法读取。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).onAppear(perform: load)
            .onChange(of: amount) { _, _ in saved = false }
            .onChange(of: group) { _, _ in saved = false }
            .onChange(of: pinned) { _, _ in saved = false }
            .onChange(of: currency) { _, _ in saved = false }
    }

    private func load() {
        guard let configuration = store.accountConfiguration(id: accountID) else { return }
        amount = configuration.monthlyBudget.map { NSDecimalNumber(decimal: $0.amount).stringValue } ?? ""
        currency = configuration.monthlyBudget?.currency ?? store.snapshots.first(where: { $0.accountID == accountID })?.monthSpend?.currency
            ?? store.snapshots.first(where: { $0.accountID == accountID })?.balance?.currency ?? .cny
        group = configuration.groupName ?? ""
        pinned = configuration.isPinned
    }

    private func save(_ configuration: AccountConfiguration) {
        do {
            let budget = configuration.providerKind == .workbuddy2api ? nil : try BudgetService.parseBudget(amount, currency: currency)
            error = store.updateAccountPreferences(id: accountID, monthlyBudget: budget,
                                                   groupName: AccountOrganizationService.normalizedGroup(group), isPinned: pinned)
            saved = error == nil
        } catch { self.error = error.localizedDescription; saved = false }
    }
}
