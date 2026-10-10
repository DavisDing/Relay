import SwiftUI
import AppKit

/// 偏好设置窗口：外观透明度、菜单栏定宽滚动、货币选择、低额预警、iCloud Drive 文件同步
public struct SettingsWindowView: View {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .followSystem
    @AppStorage("fixedMenuBarWidth") private var fixedMenuBarWidth: Bool = true
    @AppStorage("lowBalanceNotificationsEnabled") private var lowBalanceNotificationsEnabled: Bool = false
    @State private var showTodayInMenuBar: Bool
    @State private var baseCurrency: Currency
    @State private var lowBalanceThreshold: String
    @State private var refreshIntervalMinutes: String
    @State private var historyRetention: HistoryRetention
    @State private var enableICloudFileSync: Bool
    @State private var iCloudDirectoryURL: URL?
    @State private var iCloudDirectoryError: String?
    @State private var launchAtLoginEnabled: Bool
    @State private var launchAtLoginError: String?
    @State private var showGlobalShortcutSettings = false
    @State private var showSyncConflict = false
    @State private var syncConflictActionError: String?
    @State private var isDownloadingUpdate = false
    @State private var updateStatusMessage: String?
    @State private var downloadedUpdateURL: URL?
    @State private var showDownloadCompleteAlert = false
    @State private var selectedTab: SettingsTab = .general
    @ObservedObject private var store: RelayStore
    private let storageWasAvailableOnOpen: Bool
    @ObservedObject private var updateState: RelayUpdateState
    @State private var accountPendingDeletion: AccountModel?

    private let schemaVersion: Int
    private let syncStatus: SyncStatus
    private let syncConflictReport: SyncConflictReport?
    private let onResolveSyncConflict: ((SyncConflictDecision) async -> String?)?
    private let initialGlobalShortcutConfiguration: GlobalShortcutConfiguration
    private let onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)?
    private let onEditAccount: ((AccountModel) -> Void)?

    public var onClose: () -> Void
    public var onSave: (RelaySettings) -> Void

    @MainActor
    public init(
        initialSettings: RelaySettings = RelaySettings(),
        initialGlobalShortcutConfiguration: GlobalShortcutConfiguration = GlobalShortcutConfigurationStore.load(),
        onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)? = nil,
        syncStatus: SyncStatus = .idle,
        syncConflictReport: SyncConflictReport? = nil,
        onResolveSyncConflict: ((SyncConflictDecision) async -> String?)? = nil,
        onEditAccount: ((AccountModel) -> Void)? = nil,
        updateState: RelayUpdateState = RelayUpdateState(),
        store: RelayStore,
        onClose: @escaping () -> Void = {},
        onSave: @escaping (RelaySettings) -> Void = { _ in }
    ) {
        self.schemaVersion = initialSettings.schemaVersion
        self.initialGlobalShortcutConfiguration = initialGlobalShortcutConfiguration
        self.onApplyGlobalShortcut = onApplyGlobalShortcut
        self.syncStatus = syncStatus
        self.syncConflictReport = syncConflictReport
        self.onResolveSyncConflict = onResolveSyncConflict
        self.onEditAccount = onEditAccount
        self.store = store
        self.storageWasAvailableOnOpen = store.storageAvailability.isAvailable
        self._updateState = ObservedObject(wrappedValue: updateState)
        self.onClose = onClose
        self.onSave = onSave
        _showTodayInMenuBar = State(initialValue: initialSettings.showTodayInMenuBar)
        _baseCurrency = State(initialValue: initialSettings.baseCurrency)
        _lowBalanceThreshold = State(initialValue: NSDecimalNumber(decimal: initialSettings.defaultLowBalanceThreshold).stringValue)
        let initialMinutes = max(1, initialSettings.refreshIntervalSeconds / 60)
        _refreshIntervalMinutes = State(initialValue: String(initialMinutes))
        _historyRetention = State(initialValue: initialSettings.historyRetention)
        _enableICloudFileSync = State(initialValue: initialSettings.iCloudFileSyncEnabled)
        _iCloudDirectoryURL = State(initialValue: FileSyncService.configuredDirectoryURL())
        _launchAtLoginEnabled = State(initialValue: LaunchAtLoginService.isEnabled)
    }

    private var normalizedRefreshIntervalMinutes: Int {
        let value = Int(refreshIntervalMinutes.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5
        return max(1, value)
    }

    private var preferredColorScheme: ColorScheme? {
        RelayVisualStyle.preferredColorScheme(for: appearanceMode)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("设置")
                    .font(.system(size: 16, weight: .bold))

                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("返回首页")
                    .accessibilityLabel("返回首页")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            SettingsTabBar(selectedTab: $selectedTab)

            Divider().opacity(0.3)

            selectedSettingsPage
                .disabled(!store.storageAvailability.isAvailable)
                .frame(maxHeight: .infinity)
                .relayGlassTile(cornerRadius: 14)
                .padding(.horizontal, 16)

            Divider().opacity(0.3)

            HStack {
                Text(store.storageAvailability.isAvailable && storageWasAvailableOnOpen ? "设置会在关闭窗口时自动保存" : "本地数据未载入，本窗口不保存设置")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("完成", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }
        .frame(width: RelayVisualStyle.panelWidth, height: 520)
        .relayPanelSurface(cornerRadius: RelayVisualStyle.panelCornerRadius)
        .preferredColorScheme(preferredColorScheme)
        .alert("确认删除账号？", isPresented: Binding(
            get: { accountPendingDeletion != nil },
            set: { if !$0 { accountPendingDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { accountPendingDeletion = nil }
            Button("删除", role: .destructive) {
                guard let account = accountPendingDeletion,
                      let id = UUID(uuidString: account.id) else { return }
                accountPendingDeletion = nil
                Task { await store.deleteAccount(id: id) }
            }
        } message: {
            Text("将删除本机账户数据和凭据。已启用同步时，删除标记也会同步到其他设备；WordBuddy2Api 网关及其内部账号会一并从本机移除。")
        }
        .onChange(of: store.transferRevision) { _, _ in
            let settings = store.settings
            showTodayInMenuBar = settings.showTodayInMenuBar
            baseCurrency = settings.baseCurrency
            lowBalanceThreshold = NSDecimalNumber(decimal: settings.defaultLowBalanceThreshold).stringValue
            refreshIntervalMinutes = String(max(1, settings.refreshIntervalSeconds / 60))
            historyRetention = settings.historyRetention
            enableICloudFileSync = settings.iCloudFileSyncEnabled
        }
        .onDisappear {
            guard store.storageAvailability.isAvailable && storageWasAvailableOnOpen else { return }
            let parsedThreshold = Decimal(string: lowBalanceThreshold, locale: Locale(identifier: "en_US_POSIX")) ?? 20
            onSave(RelaySettings(
                schemaVersion: schemaVersion,
                refreshIntervalSeconds: max(60, normalizedRefreshIntervalMinutes * 60),
                showTodayInMenuBar: showTodayInMenuBar,
                baseCurrency: baseCurrency,
                defaultLowBalanceThreshold: parsedThreshold,
                historyRetention: historyRetention,
                iCloudFileSyncEnabled: enableICloudFileSync
            ))
        }
    }

    // Drafts and in-flight operation state stay at window scope so switching tabs
    // preserves unsaved values, errors and download progress. Pages own presentation.
    @ViewBuilder
    private var selectedSettingsPage: some View {
        switch selectedTab {
        case .general:
            SettingsGeneralPage(
                appearanceMode: $appearanceMode,
                fixedMenuBarWidth: $fixedMenuBarWidth,
                showTodayInMenuBar: $showTodayInMenuBar,
                baseCurrency: $baseCurrency,
                lowBalanceThreshold: $lowBalanceThreshold,
                lowBalanceNotificationsEnabled: $lowBalanceNotificationsEnabled,
                launchAtLoginEnabled: $launchAtLoginEnabled,
                launchAtLoginError: $launchAtLoginError
            )
        case .data:
            SettingsDataPage(
                refreshIntervalMinutes: $refreshIntervalMinutes,
                historyRetention: $historyRetention
            )
        case .shortcuts:
            SettingsShortcutsPage(
                showGlobalShortcutSettings: $showGlobalShortcutSettings,
                initialGlobalShortcutConfiguration: initialGlobalShortcutConfiguration,
                onApplyGlobalShortcut: onApplyGlobalShortcut
            )
        case .sync:
            SettingsSyncPage(
                enableICloudFileSync: $enableICloudFileSync,
                iCloudDirectoryURL: $iCloudDirectoryURL,
                iCloudDirectoryError: $iCloudDirectoryError,
                showSyncConflict: $showSyncConflict,
                syncConflictActionError: $syncConflictActionError,
                syncStatus: store.syncStatus,
                syncConflictReport: store.syncConflictReport,
                onResolveSyncConflict: onResolveSyncConflict,
                transferActions: DataTransferActions(
                    snapshot: { try store.transferSnapshot() },
                    importConfiguration: { preview, expected in try await store.importConfiguration(preview, expectedLocal: expected) },
                    restoreBackup: { preview, expected in try await store.restoreBackup(preview, expectedLocal: expected) }
                ),
                backupErrorMessage: store.backupErrorMessage
            )
        case .accountManagement:
            SettingsAccountsPage(
                store: store,
                accountPendingDeletion: $accountPendingDeletion,
                onEditAccount: onEditAccount
            )
        case .about:
            SettingsAboutPage(
                updateState: updateState,
                isDownloadingUpdate: $isDownloadingUpdate,
                updateStatusMessage: $updateStatusMessage,
                downloadedUpdateURL: $downloadedUpdateURL,
                showDownloadCompleteAlert: $showDownloadCompleteAlert
            )
        }
    }
}
