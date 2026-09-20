# P3：iCloud 冲突与同步状态局部能力

日期：2026-09-20

## 范围

本工作流只增加独立的状态模型、冲突处理适配层和最小 SwiftUI 视图。它不接入 `FileSyncService`、`SyncMerge` 的调用点，不修改 `RelayStore`、`SettingsWindowView` 或共享模型。

## 状态模型

`SyncConflictService.swift` 定义：

- `SyncAvailability`：`available` 或 `unavailable(reason:)`。同步不可用只影响同步状态，不阻塞本机业务。
- `SyncStatus`：`idle`、`downloading`、`uploading`、`merged`、`conflicted`、`unavailable`、`failed`。
- `SyncCandidate`：本机、远端或冲突副本的不可变候选。初始化时通过 `RelaySyncDataSafety` 生成安全同步投影。
- `SyncConflictReport`：记录本机候选、全部远端候选、冲突原因、可选的建议合并结果，以及是否必须用户决策。
- `SyncResolutionResult`：只有调用方明确传入 `SyncConflictDecision` 后才产生；会保留所有候选，不能通过 resolution 自动删除冲突文件。
- `SyncConflictState`：供 UI 读取的独立状态，不依赖 `RelayStore`。

## 冲突处理契约

```swift
public protocol SyncConflictHandling: Sendable {
    func inspect(
        local: SyncCandidate,
        remoteCandidates: [SyncCandidate],
        availability: SyncAvailability
    ) -> SyncConflictState

    func resolve(
        report: SyncConflictReport,
        decision: SyncConflictDecision
    ) throws -> SyncResolutionResult
}
```

`SyncDataMerging` 是当前确定性合并实现的适配器接口。默认 `RelaySyncDataMergeAdapter` 只调用现有 `SyncMerge`，不修改该文件。多个远端候选即使能产生确定性建议合并，也会保持 `conflicted` 并要求用户选择；合并建议不会自动写入本地或云端。

## 凭据安全

`RelaySyncData` 中的 `ProviderCredential` 不作为字段存在。由于现有 `AccountConfiguration` 为本地仓库保留了 `credentialReference`，冲突层在创建 `SyncCandidate` 时从不复制该值，而是将其重写为对应账户 UUID。`RelaySyncDataSafety.isSafe` 只接受该安全投影；原始 token、Pipio 用户 ID、API Key、userToken、Cookie 和凭据 map key 不会进入候选数据或其序列化结果。

该层不读取 `CredentialStore`，不接触 Authorization 头，不打印同步 payload。

## 用户可见行为

`SyncConflictView` 是可独立编译的最小视图：

- `unavailable`：显示 iCloud 不可用，但明确本机数据仍可查看和刷新。
- `conflicted`：列出待处理版本，提供“保留本机”“保留远端”“接受合并结果”（仅当存在建议合并结果）三个动作。
- 未决状态只触发 `onDecision`，由上层调用服务产生 resolution。
- 视图不执行文件删除、仓库写入或同步目录操作。

## 验证

`Tests/SyncConflictContractTests.swift` 是独立契约测试入口，覆盖：

1. 凭据引用被安全投影，序列化结果不含测试 token。
2. 多版本冲突在用户决策前保留全部候选，接受建议合并后仍保留候选。
3. 自动合并失败不会伪造合并数据，可在明确选择后保留远端。
4. iCloud 不可用不影响本机数据可用性。

当前实现没有修改共享模型，也没有改动 `FileSyncService`、`SyncMerge`、`RelayStore` 或设置页；后续集成应在独立任务中完成。
