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

    private let schemaVersion: Int
    private let syncStatus: SyncStatus
    private let syncConflictReport: SyncConflictReport?
    private let onResolveSyncConflict: ((SyncConflictDecision) -> String?)?
    private let initialGlobalShortcutConfiguration: GlobalShortcutConfiguration
    private let onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)?

    public var onClose: () -> Void
    public var onSave: (RelaySettings) -> Void
    
    public init(
        initialSettings: RelaySettings = RelaySettings(),
        initialGlobalShortcutConfiguration: GlobalShortcutConfiguration = GlobalShortcutConfigurationStore.load(),
        onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)? = nil,
        syncStatus: SyncStatus = .idle,
        syncConflictReport: SyncConflictReport? = nil,
        onResolveSyncConflict: ((SyncConflictDecision) -> String?)? = nil,
        onClose: @escaping () -> Void = {},
        onSave: @escaping (RelaySettings) -> Void = { _ in }
    ) {
        self.schemaVersion = initialSettings.schemaVersion
        self.initialGlobalShortcutConfiguration = initialGlobalShortcutConfiguration
        self.onApplyGlobalShortcut = onApplyGlobalShortcut
        self.syncStatus = syncStatus
        self.syncConflictReport = syncConflictReport
        self.onResolveSyncConflict = onResolveSyncConflict
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
    
    public var body: some View {
        VStack(spacing: 16) {
            // 标题
            HStack {
                Text("偏好设置 (Preferences)")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    // 1. 外观与磨砂透明度
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
                    
                    // 2. 菜单栏定宽与跑马灯滚动
                    VStack(alignment: .leading, spacing: 8) {
                        Text("macOS 菜单栏常驻显示")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        Toggle(isOn: $fixedMenuBarWidth) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("固定菜单栏最大宽度 (≤ 140pt)")
                                    .font(.system(size: 12, weight: .medium))
                                Text("若多币种或长数字溢出，启用双侧渐隐与平滑跑马灯微动滚动")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        
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

                        Picker("自动刷新频率", selection: $refreshIntervalMinutes) {
                            Text("1 分钟").tag(1)
                            Text("5 分钟").tag(5)
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                        }
                        .pickerStyle(.segmented)

                        Toggle("低余额系统通知", isOn: $lowBalanceNotificationsEnabled)
                            .toggleStyle(.checkbox)

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
                    
                    Divider().opacity(0.4)
                    
                    // 3. 基准币种与低额预警
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
                    
                    Divider().opacity(0.4)
                    
                    // 4. 历史数据保留
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
                    
                    if let onApplyGlobalShortcut {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("全局快捷键")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            Text("在后台快速显示/隐藏面板，或刷新全部账户。快捷键配置仅保存在本机。")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
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
                        }
                    }

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

                    // 5. iCloud 云盘普通文件同步
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
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 20)
            }
            
            Divider().opacity(0.3)
            
            // 底部完成按钮
            HStack {
                Spacer()
                Button("完成", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 460, minHeight: 460)
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
