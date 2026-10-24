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
        for (index, provider) in [ProviderKind.pipio, .deepseek].enumerated() {
            let account = AccountConfiguration(displayName: index == 0 ? "主力账户" : "开发账户",
                providerKind: provider, siteOrigin: URL(string: "https://example.invalid")!,
                groupName: "预览示例")
            try repository.upsertAccount(account)
            let rate = AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
            try repository.upsertSnapshot(ProviderSnapshot(accountID: account.id,
                balance: MoneyValue(amount: index == 0 ? 168 : 64, currency: .cny),
                todaySpend: MoneyValue(amount: index == 0 ? 12 : 3, currency: .cny),
                monthSpend: nil, requestCount: nil, capabilities: [.balance], freshness: .fresh, rate: rate))
        }
        let store = RelayStore(repository: repository, credentialStore: InMemoryCredentialStore(),
            adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 660),
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
    private let pages = ["首页", "添加账户", "编辑账户", "账户详情", "设置", "批量整理"]

    var body: some View {
        VStack(spacing: 16) {
            Text("真实 SwiftUI 页面 · 离线示例数据").font(.headline)
            Picker("预览页面", selection: $page) {
                ForEach(pages, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            HStack(alignment: .top, spacing: 24) {
                preview(colorScheme: .light, title: "浅色")
                preview(colorScheme: .dark, title: "深色")
            }
        }
        .padding(24)
        .frame(width: 800, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func preview(colorScheme: ColorScheme, title: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
                .id(page)
                .frame(width: RelayVisualStyle.panelWidth, height: 520)
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
            if let account = store.accounts.first {
                AccountDetailView(account: account, onClose: { page = "首页" })
            }
        case "设置":
            SettingsWindowView(initialSettings: store.settings, store: store, onClose: { page = "首页" })
        case "批量整理":
            SettingsAccountsPage(store: store, accountPendingDeletion: $deletion, onEditAccount: { _ in page = "编辑账户" })
                .frame(width: RelayVisualStyle.panelWidth, height: 520)
                .relayPanelSurface()
        default:
            MainPopoverView(store: store, onPresentAddAccount: { page = "添加账户" },
                onPresentSettings: { page = "设置" }, onPresentDetail: { _ in page = "账户详情" },
                onPresentEdit: { _ in page = "编辑账户" })
        }
    }
}
