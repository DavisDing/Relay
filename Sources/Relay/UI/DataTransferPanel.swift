import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct DataTransferPanel: View {
    let actions: DataTransferActions
    private let backups: LocalBackupService
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var selectedAccountID: UUID?
    @State private var configurations: [AccountConfiguration] = []
    @State private var backupEntries: [LocalBackupEntry] = []
    @State private var backupSummary: BackupSummary?
    @State private var pendingMigration = false
    @State private var backupDirectoryPath: String?
    @State private var importPreview: ConfigurationImportPreview?
    @State private var backupPreview: LocalBackupPreview?
    @State private var expectedImportData: RelaySyncData?
    @State private var expectedBackupData: RelaySyncData?
    @State private var isBusy = false
    @State private var message: String?
    @State private var isError = false

    init(actions: DataTransferActions, backups: LocalBackupService = .shared) {
        self.actions = actions
        self.backups = backups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider().opacity(0.4)
            SettingsSection("本机备份") {
                if let summary = backupSummary {
                    Text("\(summary.count) 份有效备份 · \(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))")
                        .font(.system(size: 11, weight: .medium))
                    SettingsHint(summary.latestDate.map { "最近成功：" + backupDateText($0, format: "yyyyMMdd HH:mm:ss") } ?? "尚无成功备份")
                }
                SettingsHint("运行期间每日自动备份，保留最近 5 份。含配置与消费记录，不含凭据；恢复前先备份当前数据。")
                SettingsActionRow {
                    Button("刷新列表") { reloadBackups() }
                    Button("立即备份") { createBackup() }
                }
                if pendingMigration {
                    Text("搬移待处理，有效副本已保留。")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    SettingsActionRow {
                        Button("重试搬移") { retryMigration() }
                    }
                }
                DisclosureGroup("备份列表与目录") {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsHint(backupDirectoryPath ?? "目录不可用，请前往「快捷键」重新授权。")
                            .textSelection(.enabled)
                        SettingsActionRow {
                            Button("打开目录") { openBackupDirectory() }
                                .disabled(backupDirectoryPath == nil)
                        }
                        if backupEntries.isEmpty { SettingsHint("尚无可用备份。") }
                        ForEach(backupEntries) { entry in
                            Divider().opacity(0.4)
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(backupDateText(entry.createdAt, format: "yyyyMMdd")).font(.system(size: 11))
                                    SettingsHint("\(backupDateText(entry.createdAt, format: "HH:mm:ss")) · \(entry.accountCount) 个账号")
                                    SettingsHint("\(entry.historyCount) 条记录")
                                }
                                Spacer(minLength: 0)
                                Button("预览恢复…") { previewBackup(entry) }
                            }
                        }
                    }.padding(.top, 8)
                }
                .font(.system(size: 11, weight: .medium))
            }

            Divider().opacity(0.4)
            SettingsSection("配置迁移") {
                SettingsHint("仅迁移账户配置和设置，不含凭据或消费历史；导入前可预览差异。")
                SettingsActionRow {
                    Button("导出配置…") { exportConfiguration() }
                    Button("导入配置…") { chooseConfiguration() }
                }
            }

            Divider().opacity(0.4)
            SettingsSection("消费记录") {
                DisclosureGroup("导出 CSV") {
                    VStack(alignment: .leading, spacing: 8) {
                        DatePicker("开始", selection: $startDate, displayedComponents: .date)
                        DatePicker("结束", selection: $endDate, displayedComponents: .date)
                        Picker("账号", selection: $selectedAccountID) {
                            Text("全部账号").tag(Optional<UUID>.none)
                            ForEach(configurations) { account in Text(account.displayName).tag(Optional(account.id)) }
                        }
                        SettingsHint("仅导出已有记录，未知留空，不同币种不合并。")
                        SettingsActionRow {
                            Button("导出 CSV…") { exportUsage() }
                        }
                    }.padding(.top, 8)
                }
                .font(.system(size: 11, weight: .medium))
            }
            if isBusy { ProgressView().controlSize(.small) }
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(isError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
        }
        .controlSize(.small)
        .disabled(isBusy)
        .task { refreshAccounts(); await loadBackups() }
        .sheet(isPresented: Binding(get: { importPreview != nil }, set: { if !$0 { importPreview = nil } })) {
            if let preview = importPreview { configurationSheet(preview) }
        }
        .sheet(isPresented: Binding(get: { backupPreview != nil }, set: { if !$0 { backupPreview = nil } })) {
            if let preview = backupPreview { backupSheet(preview) }
        }
    }

    private func configurationSheet(_ preview: ConfigurationImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认导入配置").font(.headline)
            Text("新增 \(preview.addedAccountCount) 个账号，更新 \(preview.updatedAccountCount) 个已有账号。未包含的本机账号保留。")
            Text("将采用文件中的设置；相同服务商和地址的已有凭据保留；新增或地址变更的账号需要重新填写凭据。")
                .font(.footnote).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading) {
                    if let current = expectedImportData {
                        ForEach(ConfigurationDiffService.accounts(preview, current: current)) { diff in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(diff.name + (diff.isNew ? " · 新增" : " · 已有账号")).fontWeight(.semibold)
                                ForEach(diff.changes) { change in
                                    Text("\(change.title)：\(change.before) → \(change.after)").font(.caption)
                                }
                                if diff.changes.isEmpty { Text("配置字段无变化").font(.caption).foregroundStyle(.secondary) }
                                if diff.clearsHistory { Text("供应商或站点改变：将清除原快照与历史").font(.caption).foregroundStyle(.orange) }
                                if diff.needsCredential { Text("需要重新填写本机凭据").font(.caption).foregroundStyle(.orange) }
                            }.padding(.bottom, 8)
                        }
                        ForEach(ConfigurationDiffService.settings(preview, current: current)) { change in
                            Text("\(change.title)：\(change.before) → \(change.after)").font(.caption)
                        }
                        Text("同步开关保留本机设置；目录授权、通知与快捷键不导入。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140)
            if isBusy { ProgressView("正在导入…") }
            if isError, let message { Text(message).font(.footnote).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { importPreview = nil }.disabled(isBusy).buttonStyle(RelaySecondaryCapsuleButtonStyle())
                Button("确认导入") { confirmImport(preview) }
                    .disabled(isBusy).buttonStyle(RelayPrimaryCapsuleButtonStyle(isLoading: isBusy))
            }
        }.padding(20).frame(width: 420).relayInitialFocus()
    }

    private func backupDateText(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func backupSheet(_ preview: LocalBackupPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认恢复备份").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(backupDateText(preview.entry.createdAt, format: "yyyyMMdd"))
                Text(backupDateText(preview.entry.createdAt, format: "HH:mm:ss"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("备份包含 \(preview.data.accounts.count) 个账号、\(preview.data.snapshots.count) 份快照和 \(preview.data.dailyUsage.count) 条历史记录。")
            Text("恢复将替换本机非敏感数据，并先保存当前数据备份。Token 不在备份中；本机已有凭据保留，其余账号需重新填写。")
                .font(.footnote).foregroundStyle(.secondary)
            if isBusy { ProgressView("正在恢复…") }
            if isError, let message { Text(message).font(.footnote).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { backupPreview = nil }.disabled(isBusy).buttonStyle(RelaySecondaryCapsuleButtonStyle())
                Button("确认恢复") { restore(preview) }.disabled(isBusy).buttonStyle(RelayPrimaryCapsuleButtonStyle(isLoading: isBusy))
            }
        }.padding(20).frame(width: 420).relayInitialFocus()
    }

    private func exportUsage() {
        perform {
            let data = try actions.snapshot()
            let bytes = try DataTransferService.exportUsageCSV(data,
                accountIDs: selectedAccountID.map { Set([$0]) }, from: startDate, through: endDate)
            guard let url = saveURL(name: "Relay-consumption.csv", type: .commaSeparatedText) else { return nil }
            try bytes.write(to: url, options: .atomic)
            return "消费记录已导出。"
        }
    }

    private func exportConfiguration() {
        perform {
            let bytes = try DataTransferService.exportConfiguration(actions.snapshot())
            guard let url = saveURL(name: "Relay-configuration.json", type: .json) else { return nil }
            try bytes.write(to: url, options: .atomic)
            return "配置已导出，不含凭据。"
        }
    }

    private func chooseConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.title = "导入 Relay 配置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= DataTransferService.maximumFileBytes else {
                throw DataTransferError.tooLarge
            }
            let current = try actions.snapshot()
            importPreview = try DataTransferService.previewConfiguration(Data(contentsOf: url), existingAccountIDs: Set(current.accounts.map(\.id)))
            expectedImportData = current
            message = nil; isError = false
            return nil
        }
    }

    private func createBackup() {
        do {
            let snapshot = try actions.snapshot()
            isBusy = true
            Task {
                do { _ = try await backups.create(snapshot); message = "本机备份已保存。"; isError = false; await loadBackups() }
                catch { report(error) }
                isBusy = false
            }
        } catch { report(error) }
    }

    private func previewBackup(_ entry: LocalBackupEntry) {
        do {
            let current = try actions.snapshot()
            isBusy = true
            Task {
                do { backupPreview = try await backups.preview(entry); expectedBackupData = current; message = nil; isError = false }
                catch { report(error) }
                isBusy = false
            }
        } catch { report(error) }
    }

    private func confirmImport(_ preview: ConfigurationImportPreview) {
        guard let expected = expectedImportData else { report(DataTransferError.invalidFormat); return }
        isBusy = true
        Task {
            do {
                try await actions.importConfiguration(preview, expected)
                importPreview = nil; refreshAccounts()
                message = "配置已导入；请为新账号填写凭据。"; isError = false
                await loadBackups()
            } catch { report(error) }
            isBusy = false
        }
    }

    private func restore(_ preview: LocalBackupPreview) {
        do {
            guard let expected = expectedBackupData else { throw DataTransferError.invalidFormat }
            isBusy = true
            Task {
                do {
                    try await actions.restoreBackup(preview, expected)
                    backupPreview = nil; refreshAccounts()
                    message = "备份已恢复；恢复前的数据已保留为新备份。"; isError = false
                    await loadBackups()
                } catch { report(error) }
                isBusy = false
            }
        } catch { report(error) }
    }

    private func openBackupDirectory() {
        Task {
            do {
                let url = try await backups.currentDirectoryURL()
                guard NSWorkspace.shared.open(url) else { throw BackupDirectoryError.invalidDirectory }
            } catch { report(error) }
        }
    }
    private func retryMigration() {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let warning = try await backups.retryPendingMigration()
                message = warning ?? "未完成的备份搬移已处理。"; isError = warning != nil
                await loadBackups()
            } catch { report(error); await loadBackups() }
        }
    }
    private func reloadBackups() { Task { await loadBackups() } }
    private func loadBackups() async {
        pendingMigration = await backups.hasPendingMigration()
        do {
            backupDirectoryPath = try await backups.currentDirectoryURL().path
            backupEntries = try await backups.list()
            backupSummary = try await backups.summary()
        } catch {
            backupEntries = []; backupDirectoryPath = nil; backupSummary = nil
            report(error)
        }
    }
    private func refreshAccounts() {
        do { configurations = try actions.snapshot().accounts }
        catch { report(error) }
    }
    private func saveURL(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]; panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func perform(_ action: () throws -> String?) {
        do { if let result = try action() { message = result; isError = false } }
        catch { report(error) }
    }
    private func report(_ error: Error) { message = error.localizedDescription; isError = true }
}
