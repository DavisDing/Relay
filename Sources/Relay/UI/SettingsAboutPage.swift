import SwiftUI
import AppKit

@MainActor
struct SettingsAboutPage: View {
    @ObservedObject var updateState: RelayUpdateState
    @Binding var isDownloadingUpdate: Bool
    @Binding var updateStatusMessage: String?
    @Binding var downloadedUpdateURL: URL?
    @Binding var showDownloadCompleteAlert: Bool

    var body: some View {
        SettingsPageScroll {
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
                latestVersionRow
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

            VStack(alignment: .leading, spacing: 8) {
                Text("应用更新")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                if case .failed(let message) = updateState.status {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let updateStatusMessage {
                    Text(updateStatusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Relay 会从 GitHub Releases 检查 macOS Apple Silicon 版本。发现新版本后，点击“最新版本”即可下载；下载后放入“下载”文件夹，由你确认退出并替换旧版本。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .relayInsetSurface(cornerRadius: 12)

            Text("© 2026 Relay · 开源项目")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
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
                Text("SHA-256 完整性已核对；未经过 Developer ID 或公证验证。\n安装包已保存到：\n\(downloadedUpdateURL.path)\n请退出 Relay 后，用新版本替换 Applications 文件夹中的旧版本。")
            }
        }
    }

    @ViewBuilder
    private var latestVersionRow: some View {
        Button {
            switch updateState.status {
            case .available(let update):
                download(update)
            case .checking:
                break
            case .idle, .upToDate, .failed:
                checkForUpdates()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("最新版本")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                latestVersionValue
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(updateState.status == .checking || isDownloadingUpdate)
        .help(latestVersionHelp)
        .accessibilityLabel("最新版本")
        .accessibilityValue(latestVersionAccessibilityValue)
        .accessibilityHint(latestVersionHelp)
    }

    @ViewBuilder
    private var latestVersionValue: some View {
        switch updateState.status {
        case .idle:
            Text("点击检测")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .upToDate:
            Text("无更新")
                .foregroundStyle(.secondary)
        case .available(let update):
            Text(update.version)
                .foregroundStyle(Color.accentColor)
                .fontWeight(.semibold)
        case .failed:
            Text("检查失败")
                .foregroundStyle(.red)
        }
    }

    private var latestVersionAccessibilityValue: String {
        if isDownloadingUpdate { return updateStatusMessage ?? "正在下载" }
        switch updateState.status {
        case .idle: return "尚未检测"
        case .checking: return "正在检测更新"
        case .upToDate: return "无更新"
        case .available(let update): return "可下载 \(update.version)"
        case .failed: return "检查失败"
        }
    }

    private var latestVersionHelp: String {
        if case .available = updateState.status {
            return "点击下载最新版本"
        }
        return "点击检测更新"
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
        Task { @MainActor in
            _ = await updateState.checkForUpdates()
        }
    }

    private func download(_ update: RelayAppUpdate) {
        guard !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        updateStatusMessage = "正在下载 \(update.version)…"
        Task { @MainActor in
            do {
                downloadedUpdateURL = try await updateState.download(update)
                updateStatusMessage = "下载完成，SHA-256 完整性已核对；安装包未经过 Developer ID 或公证验证。"
                showDownloadCompleteAlert = true
            } catch {
                updateStatusMessage = "下载失败：\(error.localizedDescription)"
            }
            isDownloadingUpdate = false
        }
    }

}
