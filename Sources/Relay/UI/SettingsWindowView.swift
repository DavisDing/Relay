import SwiftUI
import AppKit

/// 偏好设置窗口：外观透明度、菜单栏定宽滚动、货币选择、低额预警、iCloud Drive 文件同步
public struct SettingsWindowView: View {
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case data
        case shortcuts
        case sync
        case updates
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "常规"
            case .data: return "数据"
            case .shortcuts: return "快捷键"
            case .sync: return "同步"
            case .updates: return "更新"
            case .about: return "关于"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .data: return "chart.bar.xaxis"
            case .shortcuts: return "keyboard"
            case .sync: return "icloud"
            case .updates: return "arrow.down.circle"
            case .about: return "info.circle"
            }
        }
    }

    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .followSystem
    @AppStorage("fixedMenuBarWidth") private var fixedMenuBarWidth: Bool = true
    @AppStorage("lowBalanceNotificationsEnabled") private var lowBalanceNotificationsEnabled: Bool = false
    @State private var showTodayInMenuBar: Bool
    @State private var baseCurrency: Currency
    @State private var lowBalanceThreshold: String
    @State private var refreshIntervalMinutes: Int
    @State private var historyRetention: HistoryRetention
    @State private var enableICloudFileSync: Bool
    @State private var iCloudDirectoryURL: URL?
    @State private var iCloudDirectoryError: String?
    @State private var launchAtLoginEnabled: Bool
    @State private var launchAtLoginError: String?
    @State private var showGlobalShortcutSettings = false
    @State private var showSyncConflict = false
    @State private var syncConflictActionError: String?
    @State private var isCheckingForUpdates = false
    @State private var isDownloadingUpdate = false
    @State private var updateStatusMessage: String?
    @State private var availableUpdate: RelayAppUpdate?
    @State private var downloadedUpdateURL: URL?
    @State private var showDownloadCompleteAlert = false
    @State private var selectedTab: SettingsTab = .general
    @ObservedObject private var store: RelayStore
    @State private var accountPendingDeletion: AccountModel?

    private var managedAccounts: [AccountModel] {
        store.accounts.filter { $0.parentAccountID == nil }
    }

    private let schemaVersion: Int
    private let syncStatus: SyncStatus
    private let syncConflictReport: SyncConflictReport?
    private let onResolveSyncConflict: ((SyncConflictDecision) -> String?)?
    private let initialGlobalShortcutConfiguration: GlobalShortcutConfiguration
    private let onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)?
    private let onCheckForUpdates: () async throws -> RelayUpdateCheckResult
    private let onDownloadUpdate: (RelayAppUpdate) async throws -> URL

    public var onClose: () -> Void
    public var onSave: (RelaySettings) -> Void
    
    public init(
        initialSettings: RelaySettings = RelaySettings(),
        initialGlobalShortcutConfiguration: GlobalShortcutConfiguration = GlobalShortcutConfigurationStore.load(),
        onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)? = nil,
        syncStatus: SyncStatus = .idle,
        syncConflictReport: SyncConflictReport? = nil,
        onResolveSyncConflict: ((SyncConflictDecision) -> String?)? = nil,
        onCheckForUpdates: @escaping () async throws -> RelayUpdateCheckResult = {
            try await UpdateService().checkForUpdates()
        },
        onDownloadUpdate: @escaping (RelayAppUpdate) async throws -> URL = { update in
            try await UpdateService().download(update)
        },
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
        self.onCheckForUpdates = onCheckForUpdates
        self.onDownloadUpdate = onDownloadUpdate
        self.store = store
        self.onClose = onClose
        self.onSave = onSave
        _showTodayInMenuBar = State(initialValue: initialSettings.showTodayInMenuBar)
        _baseCurrency = State(initialValue: initialSettings.baseCurrency)
        _lowBalanceThreshold = State(initialValue: NSDecimalNumber(decimal: initialSettings.defaultLowBalanceThreshold).stringValue)
        let initialMinutes = max(1, initialSettings.refreshIntervalSeconds / 60)
        _refreshIntervalMinutes = State(initialValue: [1, 5, 15, 30].contains(initialMinutes) ? initialMinutes : 5)
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

            settingsTabBar

            Divider().opacity(0.3)

            selectedSettingsPage
                .frame(maxHeight: .infinity)
                .relayGlassTile(cornerRadius: 14)
                .padding(.horizontal, 16)

            Divider().opacity(0.3)

            HStack {
                Text("设置会在关闭窗口时自动保存")
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
        .frame(width: 400, height: 520)
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
            Text("将删除本机账户数据和凭据。已启用同步时，删除标记也会同步到其他设备；workbuddy2api 网关及其内部账号会一并从本机移除。")
        }
        .onDisappear {
            let parsedThreshold = Decimal(string: lowBalanceThreshold, locale: Locale(identifier: "en_US_POSIX")) ?? 20
            onSave(RelaySettings(
                schemaVersion: schemaVersion,
                refreshIntervalSeconds: max(60, refreshIntervalMinutes * 60),
                showTodayInMenuBar: showTodayInMenuBar,
                baseCurrency: baseCurrency,
                defaultLowBalanceThreshold: parsedThreshold,
                historyRetention: historyRetention,
                iCloudFileSyncEnabled: enableICloudFileSync
            ))
        }
    }

    private var settingsTabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 16, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                    .background(
                        selectedTab == tab ? Color.accentColor.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    // 让整个分页单元格（包括图标和文字周围的空白）参与命中测试。
                    // 未选中项使用透明背景，若没有显式 contentShape，SwiftUI 可能只命中实际绘制内容。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityLabel(tab.title)
            }
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private var selectedSettingsPage: some View {
        switch selectedTab {
        case .general:
            generalSettingsPage
        case .data:
            dataSettingsPage
        case .shortcuts:
            shortcutSettingsPage
        case .sync:
            syncSettingsPage
        case .updates:
            updateSettingsPage
        case .about:
            aboutSettingsPage
        }
    }

    @ViewBuilder
    private func settingsScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16, content: content)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
        }
    }

    private var generalSettingsPage: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("外观质感 (Appearance & Vibrancy)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                Picker("", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("macOS 菜单栏常驻显示")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                Toggle(isOn: $fixedMenuBarWidth) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("固定菜单栏宽度 (70pt)")
                            .font(.system(size: 12, weight: .medium))
                        Text("仅显示今日消费数值，不含币种；长数字可在悬停提示中查看")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                Text("如果使用 Hidden Bar，请将 Relay 拖到右侧常驻区；Relay 会保持稳定的菜单栏身份，但第三方菜单栏工具仍可能按自己的分隔位置隐藏图标。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $showTodayInMenuBar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("常驻显示今日消耗 (若数据不全自动隐藏)")
                            .font(.system(size: 12, weight: .medium))
                        Text("严格遵循只读降级逻辑，不展示捏造数字")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("基准折算币种与低额预警")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack {
                    Text("基准币种:")
                        .font(.system(size: 12))
                    Picker("", selection: $baseCurrency) {
                        ForEach(Currency.allCases, id: \.self) { curr in
                            Text("\(curr.rawValue) (\(curr.symbol))").tag(curr)
                        }
                    }
                    .frame(width: 120)
                    Spacer()
                }

                HStack {
                    Text("当任一账号折算余额低于:")
                        .font(.system(size: 12))
                    TextField("20.00", text: $lowBalanceThreshold)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                    Text("时，在顶栏与卡片标红预警")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Toggle("低余额系统通知", isOn: $lowBalanceNotificationsEnabled)
                .toggleStyle(.checkbox)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { setLaunchAtLogin($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录时自动启动 Relay")
                            .font(.system(size: 12, weight: .medium))
                        Text("使用 macOS 系统登录项，不保存额外凭据")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }
        }
    }

    private var dataSettingsPage: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("数据刷新")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Picker("自动刷新频率", selection: $refreshIntervalMinutes) {
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                }
                .pickerStyle(.segmented)
                Text("刷新失败时保留上一份可用快照，不用 0 覆盖未知数据。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("历史数据")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Picker("保留策略", selection: $historyRetention) {
                    Text("保留 1 年").tag(HistoryRetention.oneYear)
                    Text("永久保留").tag(HistoryRetention.forever)
                }
                .pickerStyle(.segmented)
                Text("仅保存每日聚合数据，不长期保存原始请求日志。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("账号管理")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("可删除、停用或隐藏已添加的服务商账号。隐藏只影响首页和汇总展示，不删除历史数据；workbuddy2api 网关账号也在这里管理。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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
    }

    @ViewBuilder
    private func accountManagementRow(_ account: AccountModel) -> some View {
        HStack(spacing: 9) {
            Image(systemName: account.kind == .workbuddy2api ? "point.3.connected.trianglepath.dotted" : "person.crop.circle")
                .foregroundStyle(account.isHidden ? .secondary : Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(account.kind.rawValue)
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("账号操作")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .relayInsetSurface(cornerRadius: 9)
    }

    private var shortcutSettingsPage: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("全局快捷键")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("在后台快速显示/隐藏面板，或刷新全部账户。快捷键配置仅保存在本机。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if let onApplyGlobalShortcut {
                    Button("配置全局快捷键…") {
                        showGlobalShortcutSettings = true
                    }
                    .sheet(isPresented: $showGlobalShortcutSettings) {
                        GlobalShortcutSettingsView(
                            initialConfiguration: initialGlobalShortcutConfiguration,
                            onApply: { configuration in
                                let result = onApplyGlobalShortcut(configuration)
                                if result.isRegistered || configuration.isEmpty {
                                    try? GlobalShortcutConfigurationStore.save(configuration)
                                }
                                return result
                            },
                            onCancel: { showGlobalShortcutSettings = false }
                        )
                    }
                } else {
                    Text("当前运行环境未提供全局快捷键注册能力。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var syncSettingsPage: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("同步状态")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack {
                    Image(systemName: syncStatus == .failed || syncStatus == .conflicted ? "exclamationmark.triangle" : "checkmark.icloud")
                        .foregroundColor(syncStatus == .failed || syncStatus == .conflicted ? .orange : .secondary)
                    Text(syncStatus.title)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    if syncConflictReport != nil {
                        Button("查看详情…") { showSyncConflict = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                Text("同步异常不会阻断本机账号数据；冲突候选在用户决策前保留。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .sheet(isPresented: $showSyncConflict) {
                VStack(alignment: .leading, spacing: 8) {
                    SyncConflictView(
                        state: SyncConflictState(
                            status: syncStatus,
                            report: syncConflictReport,
                            localDataAvailable: true
                        ),
                        onDecision: { decision in
                            if let error = onResolveSyncConflict?(decision) {
                                syncConflictActionError = error
                            } else {
                                syncConflictActionError = nil
                                showSyncConflict = false
                            }
                        },
                        onDismiss: { showSyncConflict = false }
                    )
                    if let syncConflictActionError {
                        Text(syncConflictActionError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                    }
                }
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("多设备配置同步 (iCloud Drive 文件同步)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                Toggle(isOn: $enableICloudFileSync) {
                    Text("启用 iCloud Drive 文件同步")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.checkbox)
                .disabled(iCloudDirectoryURL == nil && !enableICloudFileSync)

                HStack(spacing: 8) {
                    Button(iCloudDirectoryURL == nil ? "选择同步文件夹…" : "更换同步文件夹…") {
                        chooseICloudDirectory()
                    }
                    if let iCloudDirectoryURL {
                        Text(iCloudDirectoryURL.lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("尚未选择")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("📁 请在系统目录选择器中确认 iCloud Drive/Documents/Relay 文件夹")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("🔒 安全承诺: 仅同步非敏感元数据与聚合快照，Token 绝不同步！")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                    if let iCloudDirectoryError {
                        Text(iCloudDirectoryError)
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .relayInsetSurface(cornerRadius: 8)
            }
        }
    }

    private var updateSettingsPage: some View {
        settingsScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("应用更新")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Button {
                        checkForUpdates()
                    } label: {
                        if isCheckingForUpdates {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("检查更新")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCheckingForUpdates || isDownloadingUpdate)

                    if let updateStatusMessage {
                        Text(updateStatusMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }

                Text("Relay 会从 GitHub Releases 检查 macOS Apple Silicon 版本。下载后放入“下载”文件夹，由你确认退出并替换旧版本。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .alert("发现 Relay 新版本", isPresented: Binding(
                get: { availableUpdate != nil },
                set: { if !$0 { availableUpdate = nil } }
            )) {
                Button("下载") {
                    if let update = availableUpdate {
                        availableUpdate = nil
                        download(update)
                    }
                }
                Button("稍后", role: .cancel) { availableUpdate = nil }
            } message: {
                if let update = availableUpdate {
                    Text("发现版本 \(update.version)。现在下载安装包吗？")
                }
            }
            .alert("更新包已下载", isPresented: $showDownloadCompleteAlert) {
                Button("在 Finder 中显示") {
                    if let downloadedUpdateURL {
                        NSWorkspace.shared.activateFileViewerSelecting([downloadedUpdateURL])
                    }
                }
                Button("知道了", role: .cancel) {}
            } message: {
                if let downloadedUpdateURL {
                    Text("安装包已保存到：\n\(downloadedUpdateURL.path)\n请退出 Relay 后，用新版本替换 Applications 文件夹中的旧版本。")
                }
            }
        }
    }

    private var aboutSettingsPage: some View {
        settingsScroll {
            VStack(alignment: .center, spacing: 10) {
                if let applicationIcon {
                    Image(nsImage: applicationIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 74, height: 74)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(.secondary)
                        .frame(height: 74)
                }

                Text("Relay")
                    .font(.system(size: 24, weight: .bold))
                Text("多账户 AI 服务消费与余额管理工具")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Text("集中查看账户余额、今日消费、模型 Token 与缓存命中情况。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 10) {
                aboutInfoRow(title: "版本", value: appVersionText, systemImage: "tag")
                aboutInfoRow(title: "系统要求", value: "macOS 27.0 或更高版本", systemImage: "laptopcomputer")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("GitHub")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 8)
                    Link("DavisDing/Relay", destination: repositoryURL)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
            .padding(12)
            .relayInsetSurface(cornerRadius: 12)

            Text("© 2026 Relay · 开源项目")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
        }
    }

    private var applicationIcon: NSImage? {
        NSImage(named: NSImage.applicationIconName) ?? NSImage(named: "AppIcon")
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty {
            return "\(version)（构建 \(build)）"
        }
        return version
    }

    private var repositoryURL: URL {
        URL(string: "https://github.com/DavisDing/Relay")!
    }

    @ViewBuilder
    private func aboutInfoRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateStatusMessage = nil
        Task {
            do {
                switch try await onCheckForUpdates() {
                case .upToDate(let currentVersion):
                    updateStatusMessage = "已是最新版本（\(currentVersion)）"
                case .available(let update):
                    availableUpdate = update
                }
            } catch {
                updateStatusMessage = "检查失败：\(error.localizedDescription)"
            }
            isCheckingForUpdates = false
        }
    }

    private func download(_ update: RelayAppUpdate) {
        guard !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        updateStatusMessage = "正在下载 \(update.version)…"
        Task {
            do {
                downloadedUpdateURL = try await onDownloadUpdate(update)
                updateStatusMessage = "已下载到“下载”文件夹"
                showDownloadCompleteAlert = true
            } catch {
                updateStatusMessage = "下载失败：\(error.localizedDescription)"
            }
            isDownloadingUpdate = false
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            launchAtLoginEnabled = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "无法更新登录项：\(error.localizedDescription)"
        }
    }

    private func chooseICloudDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Relay iCloud 同步文件夹"
        panel.message = "请选择 iCloud Drive/Documents/Relay 文件夹。Relay 只会在此文件夹中写入不含凭据的同步文件。"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try FileSyncService.setSyncDirectory(url)
            iCloudDirectoryURL = FileSyncService.configuredDirectoryURL()
            iCloudDirectoryError = nil
            if iCloudDirectoryURL != nil {
                enableICloudFileSync = true
            }
        } catch {
            iCloudDirectoryError = error.localizedDescription
        }
    }
}
