# iCloud 多设备同步验证基线

## 范围

本基线只验证 Relay iCloud Drive 普通文件同步的可验证契约，不修改 `Sources/`、生产数据或已有回归测试。同步文件只允许包含非秘密数据；凭据仍保存在本机私有应用数据目录。

脚本位置：

```text
scripts/verify-icloud-sync.sh
```

固定 fixture 位置：

```text
Tests/Fixtures/MultiDeviceSync/
```

## 脚本接口

```text
scripts/verify-icloud-sync.sh \
  --fixture-dir <path> \
  --report <path> \
  --mode deterministic|manual
```

参数说明：

- `--fixture-dir`：fixture 根目录，默认使用仓库内的 `Tests/Fixtures/MultiDeviceSync/`。
- `--report`：可选 JSON 报告路径；省略时只输出到 stdout。
- `--mode deterministic`：运行确定性 fixture 检查，并把真实第二台 Mac 检查标记为 `blocked`。
- `--mode manual`：运行同一组结构检查；真实双 Mac 检查标记为 `not_run`，要求操作者依据本文档在两台 Mac 上执行，脚本不会把 fixture 当成真实设备证据。

脚本不会删除、解析或修改 Relay 的生产同步文件，也不会自动解决冲突副本。

## JSON 报告契约

```json
{
  "status": "passed|failed|blocked",
  "mode": "deterministic|manual",
  "fixtureDir": "/absolute/path/to/fixture",
  "cases": [
    {
      "id": "SYNC-001",
      "name": "credentials-excluded",
      "status": "passed|failed|blocked|not_run",
      "details": "..."
    }
  ],
  "blockingIssues": [],
  "generatedAt": "ISO-8601"
}
```

退出码：

- `0`：所有可执行检查通过，且没有阻塞项。
- `1`：至少一个 fixture 或契约检查失败。
- `2`：没有失败，但仍有环境阻塞项；当前基线在没有真实第二台 Mac 时预期为 `2`。

## 当前确定性检查

| ID | 检查 | 判定 |
|---|---|---|
| SYNC-001 | `credentials-excluded` | local、remote、expected JSON 中不能出现 secret、token、API key、Cookie、Pipio 数值用户 ID 等凭据字段或敏感标记；允许不具备秘密含义的 `credentialReference`。 |
| SYNC-002 | `tombstone-and-schema` | 顶层与 settings schema 为 `1`，记录结构可解析；删除 tombstone 被保留，并能抑制删除时间之前的账户记录。 |
| SYNC-003 | `conflict-copies-retained` | `conflicts/` 中至少存在两个可解析且版本不同的 payload；脚本只读，不删除或标记已解决。 |
| SYNC-004 | `offline-local-availability` | 本地 fixture 明确声明本地数据可用、云端不可用，并保留至少一个账户。 |
| SYNC-005 | `real-second-mac` | 永远不能由 fixture 自动判定通过；没有真实第二台 Mac 时为 `blocked`/`not_run`。 |

fixture 目录结构：

```text
Tests/Fixtures/MultiDeviceSync/
├── local/relay-sync-v1.json
├── remote/relay-sync-v1.json
├── expected/merged-relay-sync-v1.json
├── conflicts/relay-sync-v1.json
├── conflicts/relay-sync-v1.json.conflict.json
└── offline/local-repository.json
```

## 真实双 Mac 手工验收清单

真实设备检查必须在两台已登录同一 Apple 账户、可访问同一 iCloud Drive 的 Mac 上完成。fixture 和脚本结果不能替代以下证据。

1. Mac A 选择 Relay 同步目录并启用同步；确认首次启用会先导入已有 payload，再导出。
2. Mac A 添加或更新账户元数据；确认 Mac B 最终收到非秘密账户元数据。
3. 在一台设备删除账户；确认另一台设备收到 deletion tombstone，且不会让旧账户记录复活。
4. 在两台设备分别更新设置、历史/模型聚合；确认记录按版本规则合并。
5. 在两台设备制造同一记录的不同修改；确认 iCloud 冲突副本仍可见，不能在用户确认前静默删除。
6. 检查同步 JSON：不得出现 system token、Pipio 数值用户 ID、API key、Cookie 或其他供应商凭据；`credentialReference` 只能是不可逆的本地引用。
7. 让 iCloud Drive 暂时不可用或让同步文件保持未下载状态；确认本地账户和已保存快照仍可读取。
8. 记录两台 Mac 的系统版本、Relay 构建版本、测试时间、测试结果和未通过项。不要把凭据、用户 ID 或 Cookie 写入报告。

如果没有第二台真实 Mac，报告必须保持 `SYNC-005` 为 `blocked` 或 `not_run`，整体退出码为 `2`；不得将确定性 fixture 通过解释为多设备验证通过。

## 运行示例

在仓库根目录运行：

```bash
scripts/verify-icloud-sync.sh \
  --fixture-dir Tests/Fixtures/MultiDeviceSync \
  --report /tmp/relay-icloud-sync-report.json \
  --mode deterministic
```

手工模式：

```bash
scripts/verify-icloud-sync.sh \
  --report /tmp/relay-icloud-sync-manual-report.json \
  --mode manual
```

当前没有接入真实第二台 Mac 的自动探测器，因此上述示例会通过四个确定性检查，但整体报告为 `blocked`，退出码为 `2`。这表示“基线可执行且环境未满足”，不是伪造的双设备通过。
