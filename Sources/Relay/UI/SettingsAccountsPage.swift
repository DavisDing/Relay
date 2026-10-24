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
        let parents = Dictionary(uniqueKeysWithValues: store.accounts.filter { $0.parentAccountID == nil }.map { ($0.id, $0) })
        return AccountOrganizationService.manualOrder(store.accountConfigurations).compactMap { parents[$0.id.uuidString] }
    }

    var body: some View {
        let accounts = managedAccounts
        return SettingsPageScroll {
            SettingsSection("账号顺序与管理") {
                SettingsHint("使用 ↑ ↓ 调整并立即保存顺序；首页仍置顶优先、按服务商分组。网关子账户跟随父账户。")

                if !accounts.isEmpty {
                    HStack {
                        Text("已选 \(selected.count) 项").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("全选") { selected = Set(managedAccounts.compactMap { UUID(uuidString: $0.id) }) }
                        Button("取消选择") { selected.removeAll() }.disabled(selected.isEmpty)
                    }.buttonStyle(RelayTextButtonStyle())
                    if !selected.isEmpty {
                        HStack {
                            TextField("目标分组，留空取消", text: $groupName).relayFormField()
                            Button("移动分组") { applyBatch(group: groupName, changeGroup: true) }
                                .buttonStyle(RelaySecondaryCapsuleButtonStyle())
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

                if accounts.isEmpty {
                    Text("暂无已添加账号")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { item in
                        accountManagementRow(item.element, index: item.offset, count: accounts.count)
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
        .onChange(of: store.accounts.map(\.id)) { _, _ in
            selected.formIntersection(Set(managedAccounts.compactMap { UUID(uuidString: $0.id) }))
        }
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
    private func accountManagementRow(_ account: AccountModel, index: Int, count: Int) -> some View {
        HStack(spacing: 9) {
            if let id = UUID(uuidString: account.id) {
                Toggle("选择\(account.name)", isOn: Binding(get: { selected.contains(id) }, set: {
                    if $0 { selected.insert(id) } else { selected.remove(id) }
                })).labelsHidden().toggleStyle(.checkbox)
            }
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
                Text([account.isHidden ? "已隐藏" : nil, account.isEnabled ? nil : "已停用", account.baseURL].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                orderButton(account, index: index, count: count, offset: -1, icon: "arrow.up", title: "上移")
                orderButton(account, index: index, count: count, offset: 1, icon: "arrow.down", title: "下移")
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

    private func orderButton(_ account: AccountModel, index: Int, count: Int, offset: Int, icon: String, title: String) -> some View {
        Button { move(account, offset: offset) } label: { Image(systemName: icon) }
            .buttonStyle(RelayCircularIconButtonStyle())
            .disabled(!(0..<count).contains(index + offset))
            .help(title)
            .accessibilityLabel("\(title)\(account.name)")
            .accessibilityValue("第 \(index + 1) 项，共 \(count) 项")
    }

    private func move(_ account: AccountModel, offset: Int) {
        var ids = managedAccounts.compactMap { UUID(uuidString: $0.id) }
        guard let id = UUID(uuidString: account.id), let index = ids.firstIndex(of: id),
              ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        do {
            try store.reorderAccounts(ids)
            batchMessage = "账号顺序已保存。"
        } catch { batchMessage = error.localizedDescription }
    }
    private func applyBatch(group: String? = nil, changeGroup: Bool = false, hidden: Bool? = nil, enabled: Bool? = nil) {
        do {
            try store.organizeAccounts(selected, group: group, changeGroup: changeGroup, hidden: hidden, enabled: enabled)
            batchMessage = "已更新 \(selected.count) 个账户。"; selected.removeAll()
        } catch { batchMessage = error.localizedDescription }
    }

}
