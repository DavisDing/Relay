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
        VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.4)
            Text("消费记录导出").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            HStack {
                DatePicker("开始", selection: $startDate, displayedComponents: .date)
                DatePicker("结束", selection: $endDate, displayedComponents: .date)
            }
            Picker("账号", selection: $selectedAccountID) {
                Text("全部账号").tag(Optional<UUID>.none)
                ForEach(configurations) { account in Text(account.displayName).tag(Optional(account.id)) }
            }
            Button("导出 CSV…") { exportUsage() }
            Text("仅导出已有记录；未知消费留空。不同币种分别保留，不合并金额。")
                .font(.system(size: 10)).foregroundStyle(.secondary)

            Divider().opacity(0.4)
            Text("配置导入与导出").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            HStack {
                Button("导出配置…") { exportConfiguration() }
                Button("导入配置…") { chooseConfiguration() }
            }
            Text("包含账号配置和设置，不含 Token、Cookie、用户凭据或消费历史。已有账号凭据保留，新账号需重新填写。")
                .font(.system(size: 10)).foregroundStyle(.secondary)

            Divider().opacity(0.4)
            HStack {
                Text("本机数据备份").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("立即备份") { createBackup() }
                Button("刷新") { reloadBackups() }
            }
            Text("运行期间每日自动备份一次，可随时手动备份；保留最近 5 份，包括账号、设置和消费记录。恢复前会先备份当前数据，并保留本机凭据。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(backupDirectoryPath ?? "备份目录不可用，请重新选择或恢复默认目录")
                    .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("选择备份目录…") { chooseBackupDirectory() }
                    Button("恢复默认目录") { resetBackupDirectory() }
                }
                Text("目录设置仅保存在本机。切换时会搬移旧备份，校验成功后删除旧目录原文件。所选文件夹中使用 RelayBackups 子目录。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if backupEntries.isEmpty {
                Text("尚无可用备份").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(backupEntries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backupDateText(entry.createdAt, format: "yyyyMMdd")).font(.system(size: 11))
                        Text("\(backupDateText(entry.createdAt, format: "HH:mm:ss")) · \(entry.accountCount) 个账号 · \(entry.historyCount) 条记录")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("预览恢复…") { previewBackup(entry) }
                }
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
                    ForEach(preview.archive.accounts) { account in
                        Text("\(account.displayName) · \(account.providerKind.rawValue)")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140)
            if isBusy { ProgressView("正在导入…") }
            if isError, let message { Text(message).font(.footnote).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { importPreview = nil }.disabled(isBusy)
                Button("确认导入") { confirmImport(preview) }
                    .disabled(isBusy).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 420)
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
                Button("取消") { backupPreview = nil }.disabled(isBusy)
                Button("确认恢复") { restore(preview) }.disabled(isBusy).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 420)
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

    private func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Relay 备份文件夹"
        panel.message = "Relay 将在此文件夹中建立 RelayBackups 子目录。现有备份将搬移到新目录，校验成功后清理原文件。"
        panel.prompt = "选择"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        isBusy = true
        Task {
            do {
                let warning = try await backups.selectDirectory(parent)
                backupPreview = nil; expectedBackupData = nil
                message = warning ?? "备份已搬移，目录已切换。"; isError = warning != nil
                await loadBackups()
            } catch { report(error) }
            isBusy = false
        }
    }

    private func resetBackupDirectory() {
        isBusy = true
        Task {
            do {
                let warning = try await backups.resetDirectory()
                backupPreview = nil; expectedBackupData = nil
                message = warning ?? "备份已搬移到默认目录。"; isError = warning != nil
                await loadBackups()
            } catch { report(error) }
            isBusy = false
        }
    }

    private func reloadBackups() { Task { await loadBackups() } }
    private func loadBackups() async {
        do {
            backupDirectoryPath = try await backups.currentDirectoryURL().path
            backupEntries = try await backups.list()
        } catch {
            backupEntries = []; backupDirectoryPath = nil
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
