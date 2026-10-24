import SwiftUI

@MainActor
struct SettingsAccountsPage: View {
    @ObservedObject var store: RelayStore
    @Binding var accountPendingDeletion: AccountModel?
    @State private var selected = Set<UUID>()
    @State private var groupName = ""
    @State private var batchMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onEditAccount: ((AccountModel) -> Void)?

    private var managedAccounts: [AccountModel] {
        store.accounts.filter { $0.parentAccountID == nil }
    }

    var body: some View {
        SettingsPageScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("账号管理")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("可删除、停用或隐藏已添加的服务商账号。隐藏只影响首页和汇总展示，不删除历史数据；WordBuddy2Api 网关账号也在这里管理。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !managedAccounts.isEmpty {
                    HStack {
                        Button("全选") { selected = Set(managedAccounts.compactMap { UUID(uuidString: $0.id) }) }
                        Button("取消选择") { selected.removeAll() }.disabled(selected.isEmpty)
                        Text("已选 \(selected.count) 项").font(.caption).foregroundStyle(.secondary)
                    }.buttonStyle(RelayTextButtonStyle())
                    if !selected.isEmpty {
                        HStack {
                            TextField("目标分组，留空取消", text: $groupName).relayFormField()
                            Button("移动分组") { applyBatch(group: groupName, changeGroup: true) }
                                .buttonStyle(RelayTextButtonStyle())
                        }
                    }
                    if let batchMessage { Text(batchMessage).font(.caption).foregroundStyle(.secondary) }
                }
                if let error = store.globalErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if managedAccounts.isEmpty {
                    Text("暂无已添加账号")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(managedAccounts) { account in
                        accountManagementRow(account)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selected.isEmpty {
                HStack(spacing: 0) {
                    batchAction("隐藏", icon: "eye.slash") { applyBatch(hidden: true) }
                    batchAction("显示", icon: "eye") { applyBatch(hidden: false) }
                    batchAction("停用", icon: "pause.circle") { applyBatch(enabled: false) }
                    batchAction("启用", icon: "play.circle") { applyBatch(enabled: true) }
                }
                .padding(4)
                .relayFloatingBarSurface()
                .padding(8)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: selected.isEmpty)
    }

    private func batchAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16, weight: .regular))
                Text(title).font(.system(size: 10))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(RelayCardButtonStyle())
        .accessibilityLabel("\(title)选中的 \(selected.count) 个账户")
    }

    @ViewBuilder
    private func accountManagementRow(_ account: AccountModel) -> some View {
        HStack(spacing: 9) {
            if let id = UUID(uuidString: account.id) {
                Toggle("选择\(account.name)", isOn: Binding(get: { selected.contains(id) }, set: {
                    if $0 { selected.insert(id) } else { selected.remove(id) }
                })).labelsHidden().toggleStyle(.checkbox)
            }
            Image(systemName: account.kind == .workbuddy2api ? "point.3.connected.trianglepath.dotted" : "person.crop.circle")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(account.kind.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                Text(account.isHidden ? "已隐藏 · \(account.baseURL)" : account.baseURL)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if !account.isEnabled {
                Text("已停用")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            }
            Menu {
                if let id = UUID(uuidString: account.id) {
                    if let onEditAccount {
                        Button("编辑账号") {
                            onEditAccount(account)
                        }
                    }
                    Button(account.isEnabled ? "停用账号" : "启用账号") {
                        store.setEnabled(accountID: id, enabled: !account.isEnabled)
                    }
                    Button(account.isHidden ? "取消隐藏" : "隐藏账号") {
                        store.setHidden(accountID: id, hidden: !account.isHidden)
                    }
                    Divider()
                    Button("删除账号", role: .destructive) {
                        accountPendingDeletion = account
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("账号操作")
            .accessibilityLabel("\(account.name)的账号操作")
            .accessibilityHint(UUID(uuidString: account.id).map { store.health(for: $0).detail } ?? "")
            .accessibilityValue(account.isEnabled ? (account.isHidden ? "已启用，已隐藏" : "已启用") : (account.isHidden ? "已停用，已隐藏" : "已停用"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .relayInsetSurface(cornerRadius: 9)
    }
    private func applyBatch(group: String? = nil, changeGroup: Bool = false, hidden: Bool? = nil, enabled: Bool? = nil) {
        do {
            try store.organizeAccounts(selected, group: group, changeGroup: changeGroup, hidden: hidden, enabled: enabled)
            batchMessage = "已更新 \(selected.count) 个账户。"; selected.removeAll()
        } catch { batchMessage = error.localizedDescription }
    }

}
