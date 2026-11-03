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
    @State private var rateRefreshInterval: RateRefreshInterval
    @State private var settingsSaveError: String?
    @State private var discardChanges = false
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
    private let closeHandler: RelayPageCloseHandler?

    public var onClose: () -> Void
    public var onSave: (RelaySettings) -> String?

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
        closeHandler: RelayPageCloseHandler? = nil,
        onClose: @escaping () -> Void = {},
        onSave: @escaping (RelaySettings) -> String? = { _ in nil },
        initiallyManageAccounts: Bool = false
    ) {
        self.schemaVersion = initialSettings.schemaVersion
        self.initialGlobalShortcutConfiguration = initialGlobalShortcutConfiguration
        self.onApplyGlobalShortcut = onApplyGlobalShortcut
        self.syncStatus = syncStatus
        self.syncConflictReport = syncConflictReport
        self.onResolveSyncConflict = onResolveSyncConflict
        self.onEditAccount = onEditAccount
        self.store = store
        self.closeHandler = closeHandler
        self.storageWasAvailableOnOpen = store.storageAvailability.isAvailable
        self._updateState = ObservedObject(wrappedValue: updateState)
        self.onClose = onClose
        self.onSave = onSave
        _selectedTab = State(initialValue: initiallyManageAccounts ? .accountManagement : .general)
        _showTodayInMenuBar = State(initialValue: initialSettings.showTodayInMenuBar)
        _baseCurrency = State(initialValue: initialSettings.baseCurrency)
        _lowBalanceThreshold = State(initialValue: NSDecimalNumber(decimal: initialSettings.defaultLowBalanceThreshold).stringValue)
        let initialMinutes = max(1, initialSettings.refreshIntervalSeconds / 60)
        _refreshIntervalMinutes = State(initialValue: String(initialMinutes))
        _rateRefreshInterval = State(initialValue: initialSettings.rateRefreshInterval)
        _historyRetention = State(initialValue: initialSettings.historyRetention)
        _enableICloudFileSync = State(initialValue: initialSettings.iCloudFileSyncEnabled)
        _iCloudDirectoryURL = State(initialValue: FileSyncService.configuredDirectoryURL())
        _launchAtLoginEnabled = State(initialValue: LaunchAtLoginService.isEnabled)
    }

    private var preferredColorScheme: ColorScheme? {
        RelayVisualStyle.preferredColorScheme(for: appearanceMode)
    }

    public var body: some View {
        VStack(spacing: 0) {
            RelayPageHeader(title: "设置", onBack: closeSettings)

            SettingsTabBar(selectedTab: $selectedTab)

            selectedSettingsPage
                .background(RelayInitialFocus().id(selectedTab).frame(width: 0, height: 0).accessibilityHidden(true))
                .disabled(!store.storageAvailability.isAvailable && selectedTab != .about)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            if let settingsSaveError {
                Text(settingsSaveError).font(.system(size: 11)).foregroundStyle(.red)
                    .padding(.horizontal, 14).padding(.vertical, 4)
            }
            RelayPageFooter {
                Text(store.storageAvailability.isAvailable && storageWasAvailableOnOpen ? "关闭时自动保存" : "本地数据未载入，设置不保存")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if settingsSaveError != nil {
                    Button("放弃更改", action: discardAndClose)
                        .buttonStyle(RelayTextButtonStyle())
                }
                Button("完成", action: closeSettings)
                    .buttonStyle(RelayTextButtonStyle())
            }
        }
        .frame(width: RelayVisualStyle.settingsPanelWidth, height: RelayVisualStyle.settingsPanelHeight)
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
            rateRefreshInterval = settings.rateRefreshInterval
            historyRetention = settings.historyRetention
            enableICloudFileSync = settings.iCloudFileSyncEnabled
        }
        .onAppear {
            closeHandler?.prepareToClose = saveSettings
            closeHandler?.prepareToTerminate = { saveSettings() || confirmDiscard() }
        }
        .onDisappear {
            closeHandler?.prepareToClose = nil
            closeHandler?.prepareToTerminate = nil
        }
    }

    private func closeSettings() {
        if closeHandler != nil { onClose() }
        else if saveSettings() { onClose() }
    }

    private func saveSettings() -> Bool {
        guard !discardChanges, storageWasAvailableOnOpen else { return true }
        guard let minutes = Int(refreshIntervalMinutes.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...1440).contains(minutes) else {
            settingsSaveError = "自动刷新间隔须为 1～1440 分钟。"
            return false
        }
        guard let parsedThreshold = Decimal(string: lowBalanceThreshold.trimmingCharacters(in: .whitespacesAndNewlines), locale: Locale(identifier: "en_US_POSIX")),
              !parsedThreshold.isNaN, parsedThreshold >= 0 else {
            settingsSaveError = "低余额阈值须为非负数。"
            return false
        }
        settingsSaveError = onSave(RelaySettings(
                schemaVersion: schemaVersion,
                refreshIntervalSeconds: minutes * 60,
                rateRefreshInterval: rateRefreshInterval,
                showTodayInMenuBar: showTodayInMenuBar,
                baseCurrency: baseCurrency,
                defaultLowBalanceThreshold: parsedThreshold,
                historyRetention: historyRetention,
                iCloudFileSyncEnabled: enableICloudFileSync
            ))
        return settingsSaveError == nil
    }

    private func confirmDiscard() -> Bool {
        let confirm = closeHandler?.confirmDiscard ?? RelayPageCloseHandler.showDiscardConfirmation
        return confirm((settingsSaveError ?? "设置未保存。") + " 放弃仅丢弃尚未保存的设置；已立即生效的本机偏好和操作将保留。")
    }

    private func discardAndClose() {
        guard confirmDiscard() else { return }
        discardChanges = true
        onClose()
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
                lowBalanceNotificationsEnabled: $lowBalanceNotificationsEnabled
            )
        case .data:
            SettingsDataPage(
                refreshIntervalMinutes: $refreshIntervalMinutes,
                rateRefreshInterval: $rateRefreshInterval,
                historyRetention: $historyRetention
            )
        case .shortcuts:
            SettingsShortcutsPage(
                showGlobalShortcutSettings: $showGlobalShortcutSettings,
                launchAtLoginEnabled: $launchAtLoginEnabled,
                launchAtLoginError: $launchAtLoginError,
                enableICloudFileSync: $enableICloudFileSync,
                iCloudDirectoryURL: $iCloudDirectoryURL,
                iCloudDirectoryError: $iCloudDirectoryError,
                initialGlobalShortcutConfiguration: initialGlobalShortcutConfiguration,
                onApplyGlobalShortcut: onApplyGlobalShortcut
            )
        case .sync:
            SettingsSyncPage(
                enableICloudFileSync: $enableICloudFileSync,
                iCloudDirectoryURL: iCloudDirectoryURL,
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
                store: store,
                updateState: updateState,
                isDownloadingUpdate: $isDownloadingUpdate,
                updateStatusMessage: $updateStatusMessage,
                downloadedUpdateURL: $downloadedUpdateURL,
                showDownloadCompleteAlert: $showDownloadCompleteAlert
            )
        }
    }
}
