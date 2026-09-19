# Relay 凭据存储安全设计

**版本**：v1.0  
**日期**：2026-09-18  
**状态**：已实施

## 1. 变更目标

Relay 不再使用 macOS Keychain。Pipio 管理 Token、Pipio User ID、DeepSeek API Key 统一由软件内部的 `FileCredentialStore` 保存到当前用户的本机 Application Support 目录。

该变更是明确的产品安全取舍，而不是与 Keychain 等价的替代方案。

## 2. 存储边界

默认文件：

```text
~/Library/Application Support/cloud.dinghao.relay/relay-credentials-v1.json
```

允许出现真实凭据的位置只有：

1. 上述本机凭据文件；
2. 发起供应商请求期间的进程内存；
3. 系统网络栈发送的 HTTPS 请求头。

禁止写入：

- `relay-local-v1.json` 业务数据文件；
- SwiftData（当前项目也未启用 SwiftData）；
- iCloud Drive 同步文件；
- 源码、文档、测试夹具；
- 普通日志、错误消息、诊断导出；
- 浏览器 Cookie 或网页会话存储。

## 3. 文件保护

`FileCredentialStore` 执行以下措施：

- Application Support 应用目录权限强制为 `0700`；
- 凭据文件权限强制为 `0600`；
- 读取已有凭据文件时重新校正目录和文件权限；
- 写入使用原子替换，避免留下半写入 JSON；
- 使用版本化 schema，未知版本拒绝读取；
- 对外错误不包含 Token、User ID 或 API Key；
- `ProviderCredential.description` 永远返回脱敏文本。

业务数据文件 `relay-local-v1.json` 不含凭据，但同样使用目录 `0700`、文件 `0600`，减少本机其他用户读取账户元数据的风险。

## 4. 明确不提供的保证

当前凭据文件是受 POSIX 权限保护的本地 JSON，不是加密保险箱。它不提供：

- Keychain 的系统访问控制；
- Secure Enclave 或硬件绑定保护；
- 每次读取时的用户授权提示；
- 用户主密码加密；
- 对已获得当前 macOS 用户权限的恶意进程的防护。

因此 UI 和文档必须明确提示这是相对于 Keychain 的安全降级，不能使用“硬件加密”“绝对安全”等描述。

## 5. 生命周期与失败处理

### 新增账户

1. UI 构造临时 `AccountDraft`；
2. 业务层通过 HTTPS 验证供应商和账户级汇率；
3. 验证成功后才保存凭据；
4. 再保存非秘密账户元数据和首个快照；
5. 若业务数据写入失败，删除刚写入的凭据并回滚账户数据。

### 删除账户

先删除对应凭据引用，再删除账户元数据、快照和账户级汇率缓存。

### 旧 Keychain 数据

不读取、不自动迁移旧 Keychain 项。升级后用户需要重新录入凭据，避免在用户不知情时复制秘密数据。

## 6. 账户级汇率隔离

- `AccountRate` 必须绑定具体 `accountID`；
- Pipio 每个账户独立调用 `/api/status`，独立保存 `quota_per_unit`、币种、获取时间和过期时间；
- 不允许因为两个账户属于同一供应商或同一域名而共享缓存；
- DeepSeek 官方余额按 CNY 原值处理，`conversionToCNY = 1`，不套用 Pipio 参数；
- 无可靠汇率时，该账户从跨币种总额中排除，并在 UI 显示总额不完整。

## 7. 后续增强路线

只有在用户明确要求更强保护时，才设计迁移方案。优先候选为用户主密码派生密钥与标准认证加密，并需要包含：密钥派生参数、随机盐、nonce、认证标签、版本迁移、忘记密码处理和安全擦除策略。不得自行设计加密算法。
