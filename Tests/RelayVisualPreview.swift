import AppKit
import SwiftUI

/// Offline visual fixture hosting the production views. Its separate bundle ID
/// isolates preferences; accounts and credentials exist only in memory.
@main
struct RelayVisualPreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let delegate = PreviewAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        let repository = InMemoryLocalRepository()
        let now = Date()
        for (index, provider) in [ProviderKind.deepseek, .deepseek, .pipio].enumerated() {
            let names = ["个人账户", "实验账户", "工作账户"]
            let account = AccountConfiguration(displayName: names[index], providerKind: provider,
                siteOrigin: URL(string: provider == .deepseek ? "https://api.deepseek.com" : "https://pipio.io")!,
                monthlyBudget: MoneyValue(amount: 200, currency: .cny),
                groupName: "预览示例", isPinned: index == 0, sortOrder: index)
            try repository.upsertAccount(account)
            let todayAmounts: [Decimal] = [Decimal(string: "12.80")!, Decimal(string: "6.42")!, Decimal(string: "23.64")!]
            let balances: [Decimal] = [Decimal(string: "128.40")!, Decimal(string: "38.17")!, Decimal(string: "151.83")!]
            let rate = AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
            let models = [ModelUsageSummary(modelName: "deepseek-chat", tokenCount: 1_420_000, requestCount: 824,
                cacheHitRate: Decimal(string: "0.68"), spend: MoneyValue(amount: todayAmounts[index], currency: .cny))]
            try repository.upsertSnapshot(ProviderSnapshot(accountID: account.id,
                balance: MoneyValue(amount: balances[index], currency: .cny),
                todaySpend: MoneyValue(amount: todayAmounts[index], currency: .cny),
                monthSpend: MoneyValue(amount: Decimal(string: "86.40")!, currency: .cny), requestCount: 824,
                modelUsages: models, capabilities: [.balance, .todayUsage, .monthlyUsage, .modelUsage],
                freshness: .fresh, rate: rate))
            let calendar = BudgetService.calendar(for: provider)
            for offset in -6...0 {
                let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
                try repository.upsertDailyUsage(DailyUsageRecord(accountID: account.id, day: day,
                    spend: MoneyValue(amount: todayAmounts[index] + Decimal(offset % 3), currency: .cny), modelUsages: models))
            }
        }
        let gateway = AccountConfiguration(displayName: "本地网关", providerKind: .workbuddy2api,
            siteOrigin: URL(string: "http://localhost:7863")!, sortOrder: 3)
        try repository.upsertAccount(gateway)
        try repository.upsertSnapshot(ProviderSnapshot(accountID: gateway.id, balance: nil,
            todaySpend: nil, monthSpend: nil, requestCount: nil, capabilities: [.creditBalance], freshness: .fresh,
            rate: AccountRate(accountID: gateway.id, source: .providerNativeCurrency, nativeCurrency: .cny),
            subAccounts: [
                ProviderSubAccountSnapshot(parentAccountID: gateway.id, externalID: "preview-1", displayName: "开发子账户",
                    availablePoints: 10_000, consecutiveFailures: 0),
                ProviderSubAccountSnapshot(parentAccountID: gateway.id, externalID: "preview-2", displayName: "测试子账户",
                    availablePoints: 2480, consecutiveFailures: 2)
            ]))
        let store = RelayStore(repository: repository, credentialStore: InMemoryCredentialStore(),
            adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 840),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Relay UI 预览 · 离线示例"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RelayPreviewGallery(store: store))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct RelayPreviewGallery: View {
    @ObservedObject var store: RelayStore
    @State private var page = "首页"
    @State private var deletion: AccountModel?
    @State private var selectedAccountID: String?
    private let pages = ["首页", "添加账户", "编辑账户", "账户详情", "设置", "批量整理"]

    var body: some View {
        VStack(spacing: 16) {
            Text("真实 SwiftUI 页面 · 离线示例数据").font(.headline)
            Picker("预览页面", selection: $page) {
                ForEach(pages, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 24) {
                    preview(colorScheme: .light, title: "浅色")
                    preview(colorScheme: .dark, title: "深色")
                }.padding(8)
            }
        }
        .padding(24)
        .frame(width: 1100, height: 840)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var previewSize: CGSize {
        switch page {
        case "账户详情": return CGSize(width: RelayVisualStyle.detailPanelWidth, height: RelayVisualStyle.detailPanelHeight)
        case "添加账户", "编辑账户": return CGSize(width: RelayVisualStyle.formPanelWidth, height: RelayVisualStyle.formPanelHeight)
        case "设置", "批量整理": return CGSize(width: RelayVisualStyle.settingsPanelWidth, height: RelayVisualStyle.settingsPanelHeight)
        default: return CGSize(width: RelayVisualStyle.panelWidth, height: RelayVisualStyle.panelHeight)
        }
    }

    private func preview(colorScheme: ColorScheme, title: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
                .id(page)
                .frame(width: previewSize.width, height: previewSize.height)
                .environment(\.colorScheme, colorScheme)
                .preferredColorScheme(colorScheme)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case "添加账户":
            AccountAddModalView(onDismiss: { page = "首页" }, onSave: { _ in
                throw ProviderError.unsupportedProvider
            })
        case "编辑账户":
            if let account = store.accounts.first {
                AccountEditModalView(account: account,
                    accountConfiguration: UUID(uuidString: account.id).flatMap { store.accountConfiguration(id: $0) },
                    onDismiss: { page = "首页" }, onSave: { _, _, _, _, _, _, _ in
                        throw ProviderError.unsupportedProvider
                    })
            }
        case "账户详情":
            if let id = selectedAccountID ?? store.accounts.first?.id {
                AccountDetailContainerView(store: store, accountID: id,
                    onClose: { page = "首页" }, onSubAccountAction: { _, _, _ in
                        throw ProviderError.unsupportedProvider
                    })
            }
        case "设置":
            SettingsWindowView(initialSettings: store.settings, store: store, onClose: { page = "首页" })
        case "批量整理":
            SettingsAccountsPage(store: store, accountPendingDeletion: $deletion, onEditAccount: { _ in page = "编辑账户" })
                .frame(width: previewSize.width, height: previewSize.height)
                .relayPanelSurface()
        default:
            MainPopoverView(store: store, onPresentAddAccount: { page = "添加账户" },
                onPresentSettings: { page = "设置" }, onPresentDetail: { selectedAccountID = $0.id; page = "账户详情" },
                onPresentEdit: { _ in page = "编辑账户" })
        }
    }
}
