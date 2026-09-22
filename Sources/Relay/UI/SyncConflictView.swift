import SwiftUI

/// A deliberately standalone view. It renders the conflict state and emits a
/// user's decision; persistence, file deletion, and repository writes remain
/// outside the view so local business data cannot be blocked by iCloud.
public struct SyncConflictView: View {
    public let state: SyncConflictState
    public let onDecision: (SyncConflictDecision) -> Void
    public let onDismiss: () -> Void

    public init(
        state: SyncConflictState,
        onDecision: @escaping (SyncConflictDecision) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onDecision = onDecision
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let message = state.availabilityMessage, state.status == .unavailable {
                statusCard(
                    icon: "icloud.slash",
                    title: "iCloud 暂不可用",
                    message: "\(message) 本机数据仍可正常查看和刷新。"
                )
            } else if let resolution = state.resolution {
                statusCard(
                    icon: "checkmark.circle",
                    title: "冲突已处理",
                    message: resolutionSummary(resolution)
                )
            } else if let report = state.report, report.requiresUserAction {
                conflictContent(report)
            } else {
                statusCard(
                    icon: state.status == .merged ? "checkmark.icloud" : "icloud",
                    title: state.status.title,
                    message: state.error?.localizedDescription ?? "本机数据不受 iCloud 状态影响。"
                )
            }

            HStack {
                Spacer()
                Button("关闭", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .relayPanelSurface(cornerRadius: RelayVisualStyle.panelCornerRadius)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.icloud")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("同步状态")
                    .font(.headline)
                Text(state.status.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func conflictContent(_ report: SyncConflictReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("冲突未决时会保留本机与所有 iCloud 版本。请选择处理方式后，才会产生 resolution。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("待处理版本")
                    .font(.subheadline.weight(.semibold))
                ForEach(report.conflicts) { conflict in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conflict.candidate.source.label)
                                .font(.callout.weight(.medium))
                            Text(conflict.reason.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(conflict.candidate.modifiedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .relayInsetSurface(cornerRadius: 8)
                }
            }

            HStack(spacing: 8) {
                Button("保留本机") { onDecision(.keepLocal) }
                Button("保留远端") { onDecision(.keepRemote) }
                if report.mergedData != nil {
                    Button("接受合并结果") { onDecision(.acceptMerged) }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func statusCard(icon: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .relayInsetSurface(cornerRadius: 10)
    }

    private func resolutionSummary(_ resolution: SyncResolutionResult) -> String {
        switch resolution.decision {
        case .keepLocal:
            return "已选择本机版本。远端候选仍保留，待上层明确处理文件生命周期。"
        case .keepRemote:
            return "已选择最新远端版本。其他候选仍保留，未自动删除冲突文件。"
        case .acceptMerged:
            return "已接受合并结果。原始候选仍保留，未自动删除冲突文件。"
        }
    }
}
