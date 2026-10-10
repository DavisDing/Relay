# Relay / 驿站 · 技术设计

**版本**：v1.3-draft
**日期**：2026-09-18
**阶段**：Architecture

阅读指引：前文保留历次方案与实施记录；2026-10-09 已实施基线见第 17 节，2026-10-10 增量评估与待确认事项见第 18 节。早期“尚无业务代码”、顺序刷新、无下载校验等描述不代表当前实现。

## 1. 技术栈

| 层 | 方案 | 原因 |
|---|---|---|
| UI | SwiftUI + 少量 AppKit | SwiftUI 实现页面；AppKit 负责状态栏、窗口层级和必要的 macOS 生命周期控制 |
| 语言 | Swift（macOS 27 SDK） | 原生平台能力、菜单栏、文件协调和 Liquid Glass 支持最好 |
| 并发/网络 | Swift Concurrency + URLSession | 不引入第三方网络框架；便于账户级隔离、取消和限流 |
| 图表 | Swift Charts | 7/30 日趋势，无需第三方图表库 |
| 本地数据 | 版本化 JSON `FileLocalRepository`（当前实现） | 无第三方依赖、免费账户可直接编译运行；通过 `LocalRepository` 协议保留未来替换空间 |
| 文件同步 | iCloud Drive 普通文件 + `NSFileCoordinator` | 不使用 CloudKit；默认逻辑目录为 `iCloud Drive/文稿/Relay`，仅同步非秘密数据 |
| 凭据 | `FileCredentialStore` 私有应用支持目录 | 用户已明确选择不使用 Keychain；目录/文件使用 0700/0600，不进入同步文件 |
| 启动项 | ServiceManagement | 原生登录项管理 |

项目当前只有文档，没有可复用业务代码或既有技术栈。版本化本地 JSON 是当前本机事实源；iCloud 云盘同步文件是可合并副本，不直接替代本地数据。SwiftData 作为未来可替换实现，不是当前运行前提。CloudKit 不在当前或后续已规划范围内。

## 2. 系统结构

```text
Menu Bar / SwiftUI Views
          │
          ▼
       AppStore                         SettingsStore
          │                                  │
          ├───────────────┬──────────────────┘
          ▼               ▼
   AccountService    RefreshCoordinator
          │               │
          │               ├── PipioAdapter ── URLSession ── pipio.io
          │               └── DeepSeekAdapter ─ URLSession ─ deepseek.com
          │
          ├── CredentialStore ── Application Support/relay-credentials-v1.json
          ├── LocalRepository ── relay-local-v1.json
          └── FileSyncService ── iCloud Drive/Documents/Relay
```

Relay 无自建后端。前端、业务层和供应商访问均运行在本机；“前后端职责”在本项目中对应 UI 层与本地业务/数据层。

## 3. 模块设计

### 3.1 AppShell

职责：应用生命周期、菜单栏入口、Dock 显示策略、弹出面板、设置窗口、深色模式和全局快捷键。

主要组件：

- `RelayApp`
- `MenuBarController`
- `PanelCoordinator`
- `AppRoute`

### 3.2 Dashboard

职责：组合本地快照，计算可展示的总余额、完整的今日消费、账户状态和趋势。

规则：

- 只汇总币种一致或已有有效换算结果的金额。
- `knownTotal` 与 `isComplete` 同时返回；今日消费只有在当前展示范围完整时才交给 UI，否则该字段隐藏。
- UI 首屏直接读本地缓存；刷新异步发生。

### 3.3 AccountService

职责：账户增删改、启用禁用、验证、本地凭据引用维护、删除数据和文件同步 tombstone。

添加 Pipio 账户流程：

1. 规范化站点 URL，拆分 origin、management base、model base。
2. 请求 `GET {origin}/api/status`。
3. 校验令牌非空、`pipioUserId` 为正整数。
4. 请求 `GET {origin}/api/user/self`。
5. 请求统计接口并生成 `ProviderCapabilities`。
6. 先写本地凭据文件，成功后写账户元数据；任一步失败则回滚本次新建数据。
7. 保存首个快照和按日聚合。

### 3.4 ProviderAdapter

供应商通过协议适配，不让 UI 直接理解供应商响应。

```swift
protocol ProviderAdapter {
    var kind: ProviderKind { get }
    func probeSite(_ configuration: SiteConfiguration) async throws -> SiteMetadata
    func validateAccount(_ account: AccountConfiguration,
                         credential: ProviderCredential) async throws -> ValidationResult
    func fetchSnapshot(_ context: FetchContext) async throws -> ProviderSnapshot
    func fetchUsage(_ range: DateInterval,
                    context: FetchContext) async throws -> ProviderUsage
}
```

规范化输出：

- `MoneyValue?`
- `UsageMetrics?`
- `ModelUsage[]`
- `ProviderCapabilities`
- `DataFreshness`
- `ProviderError`（脱敏）

#### PipioAdapter

已验证管理令牌可用于 Pipio 管理接口，但不可用于 `/v1/models`。Pipio 账户的数值用户 ID 可从用户本人已登录网页的 `/api/user/self` 请求头 `Pipio-User` 读取；Relay 不读取浏览器 Cookie，也不尝试自动抓取 Safari 会话。

URL 规则：

```text
输入：https://pipio.io/v1
origin：https://pipio.io
modelBaseURL：https://pipio.io/v1
managementBaseURL：https://pipio.io/api
```

不能执行字符串直接拼接 `input + /api/...`。使用 `URLComponents` 删除已知 `/v1` 后缀并保留 origin。

认证头：

```http
Authorization: Bearer <secret>
Pipio-User: <positive integer>
```

首期只发送服务端明确要求的 `Pipio-User`；`New-Api-User` 作为兼容选项仅在验证后加入，不默认重复发送两个身份头。

已知端点：

| 用途 | Method/Path | 认证 |
|---|---|---|
| 站点能力 | `GET /api/status` | 无 |
| 当前账户 | `GET /api/user/self` | Bearer + Pipio-User |
| 聚合统计 | `GET /api/log/self/stat` | Bearer + Pipio-User |
| 日志列表 | `GET /api/log/self` | Bearer + Pipio-User |
| 模型列表 | `GET /v1/models` | 模型 API Key；不与管理系统令牌混用 |

配额换算：

```text
amount = quota / quota_per_unit
```

`quota_per_unit` 来自站点状态；缺失或非法时标记金额不可换算，而不是静默使用错误值。Pipio 不提供手动额度除数或猜测兜底值。

#### DeepSeekAdapter

- P0 不实现，P1 接入 DeepSeek 官方余额接口；历史用量作为 userToken 可选能力接入。
- 用户必须主动提供 DeepSeek 官方 API Key；Relay 使用该 Key 调用官方账户余额端点。
- 不读取浏览器 Cookie，不复制登录会话。用户可手动提供可选平台 userToken，仅用于 DeepSeek 网站的历史用量接口；该接口属于网页内部接口，可能变更，失败时降级为余额可用。
- 官方接口无法提供的用量维度显示为“不支持”，不通过网页抓包补齐。

### 3.5 RefreshCoordinator

职责：定时刷新、手动刷新、账户级并发、取消、退避、数据落库和状态发布。

建议规则：

- 最大并发：3 个账户。
- 同一账户同一时间最多一个刷新任务；手动刷新复用或取消旧任务。
- 5xx/超时：1、2、5、15、30 分钟退避并加抖动。
- 401/403：停止自动重试，状态变为 `credentialInvalid`。
- 429：优先遵守 `Retry-After`，否则退避。
- 成功后清零失败计数。

### 3.6 CredentialStore

- 实现：`FileCredentialStore`，不依赖 `Security.framework`。
- 默认文件：`~/Library/Application Support/cloud.dinghao.relay/relay-credentials-v1.json`。
- 文件内容：版本化 JSON map，key 为稳定的本地 `accountId` 引用，value 为令牌和供应商所需的用户 ID。
- 文件权限：父目录 0700，凭据文件 0600；写入使用 `.atomic`。
- 该文件只属于当前 Mac 的本地应用数据，不进入 SwiftData、iCloud Drive 同步文件、源码、文档、日志或诊断导出。
- 这是用户明确选择的安全降级：普通文件不具备 Keychain 的硬件保护、系统访问控制和授权提示。当前不自创主密码或加密算法，避免产生虚假的安全保证。
- 只向业务层返回短生命周期值，不进入可观察 UI state。

### 3.7 LocalRepository

职责：保存账户元数据、最近快照、日聚合、模型聚合、偏好和同步状态。

不保存：系统令牌、Pipio 用户 ID、API Key、Cookie、完整原始日志响应；DeepSeek userToken 仅保存在本机凭据文件，不进入同步数据。

### 3.8 FileSyncService

- 不创建或使用 CloudKit Container。同步只读写 iCloud 云盘普通文件；Finder/iCloud Drive 客户端负责上传下载，Relay 不读取用户的 iCloud 账户凭据。
- 默认逻辑目录为 `iCloud Drive/Documents/Relay`，中文 Finder 中显示为 `iCloud Drive/文稿/Relay`。不得硬编码 `~/Library/Mobile Documents/...` 或本地化的“文稿”字符串。首次启用时用系统目录选择器定位 iCloud Drive，并让用户确认“文稿/Relay”；保存确认后目录的持久化 URL bookmark。
- 当前保存带安全作用域的持久化 URL bookmark；bookmark 失效或目录不可访问时要求用户重新选择，不阻塞本地功能。即使当前 GitHub 构建不启用 App Sandbox，也保持该授权模型，避免未来迁移时改变数据路径语义。
- 同步文件名固定为 `relay-sync-v1.json`，使用版本化 schema、临时文件和原子替换，并通过 `NSFileCoordinator` 协调读写。
- 同步账户元数据、日/模型聚合、用户主动设置和 tombstone；不含令牌、用户 ID、API Key、Cookie、原始日志或认证响应。
- 合并以记录 UUID、`updatedAt` 和 tombstone 为依据；检测到无法自动解决的 iCloud 冲突版本时保留双方文件并提示用户。
- 同步失败不阻塞本地写入；`FileLocalRepository` 始终是当前本机事实源。
- 其他设备导入账户元数据后显示“需要在此设备补充凭据”。

### 3.9 RateService

- 读取 Pipio 站点发布的 `quota_per_unit`、币种和相关换算元数据。
- 刷新频率可配置：每天、每 7 天（默认）、每月、仅手动。
- 缓存来源、获取时间和有效状态；失败时保留最后一次成功值并标记过期。
- USD→CNY 优先读取账户配置中的有效手动外汇参数，否则使用未过期站点汇率；不改写用于额度归一化的 `AccountRate`。

### 3.10 SwiftData 与账户/发布限制

- SwiftData 是 Apple 平台随系统提供的原生框架，不是需要单独购买或单独下载的第三方 SDK；没有按数据量或调用量收费。
- SwiftData 没有一个适用于所有 App 的固定“占用多少 MB”数字；它由系统提供，最终应用包体受链接、优化和实际使用 API 影响，当前不为它单独估算包体。
- 代码体积没有 Apple 官方固定数字；实际包体增量取决于链接方式、优化和最终使用的 API，不能在设计阶段承诺一个固定 MB 数。
- 免费 Apple 账户可以用于本地 Xcode 开发、编译和在自己的 Mac 上运行调试版本；不需要先购买 Apple Developer Program。
- 付费 Apple Developer Program 主要影响 Developer ID 签名、公证、App Store/TestFlight 等分发能力，不是 SwiftData 的使用门槛；Apple 官方标准价格为 99 USD/年（地区可能显示本地货币）。
- 因此当前不把 SwiftData 作为必要依赖；现有 `LocalRepository` 已支持将来替换。

### 3.11 Distribution

- Bundle ID：`cloud.dinghao.relay`。
- 发布渠道：GitHub Releases，不提交 Mac App Store。
- 当前使用免费 Apple 账户，因此不能把 Developer ID 签名和公证作为首期前提；CloudKit Container 已明确不采用，与未来是否付费无关。
- Release 构建至少执行 ad-hoc code signing 以固定应用包内部签名结构，但它不等同于 Apple 信任的 Developer ID 签名或公证。首期不启用 App Sandbox，以避免依赖当前不可稳定分发的沙盒授权与安全作用域书签身份。
- 安装文档优先说明首次尝试打开后，到“系统设置 → 隐私与安全性 → 仍要打开”的流程；不把 `sudo xattr` 作为默认安装步骤。
- `xattr -d/-rd com.apple.quarantine` 仅删除下载文件的 quarantine 扩展属性，不是代码签名、开发者认证或公证。普通用户对自己拥有的 App 通常不需要 `sudo`；该命令只作为高级故障排查说明，并附带来源校验警告。

## 4. 层职责

### UI 层

- 展示本地状态、收集输入、基础格式校验。
- 不直接拼 API URL，不持有长期凭据，不解释供应商 JSON。
- 完整处理 Loading、Empty、Refreshing、Partial、Stale、Error、Success。

### 业务层

- 账户验证、能力探测、金额/时间规范化、汇总、刷新调度、错误分类。
- 所有安全校验必须在业务层再次执行。

### 数据层

- `FileCredentialStore` 管本机凭据文件；不使用 Keychain。
- `FileLocalRepository` 管当前本地业务数据；SwiftData 不是当前运行前提。
- FileSyncService 管 `iCloud Drive/文稿/Relay` 中的可同步非秘密数据。

### 外部服务层

- 每个适配器只访问其声明的 HTTPS origin。
- 响应先解码为供应商 DTO，再映射为统一领域模型。

## 5. 数据流

### 5.1 启动

```text
App Launch
  → 读取 Settings / Accounts / Cached Snapshots
  → 立即渲染菜单栏与首页
  → 对到期且启用的账户安排后台刷新
  → 单账户结果独立落库并更新汇总
```

### 5.2 Pipio 刷新

```text
Account metadata + local credential file
  → PipioAdapter 构造 management request
  → /api/user/self + /api/log/self/stat
  → DTO 校验与单位换算
  → ProviderSnapshot / DailyUsage
  → LocalRepository 原子写入
  → Dashboard 重算
  → FileSyncService 异步合并并写入同步文件
```

## 6. API 设计

### 6.1 Relay 自建 API

`NOT_REQUIRED`：Relay 没有自建服务器或公开 HTTP API。

### 6.2 Pipio 外部 API 合约

#### PIPIO-001 站点状态

```http
GET {origin}/api/status
```

读取字段（其余忽略）：

```json
{
  "success": true,
  "data": {
    "system_name": "Pipio",
    "version": "...",
    "server_address": "https://pipio.io",
    "quota_per_unit": 500000,
    "credit_currency": "USD",
    "quota_display_type": "USD"
  }
}
```

错误：非 2xx、`success != true`、`quota_per_unit <= 0` 或 JSON 不可解析。状态接口失败时仍可允许用户手动继续验证账户，但需显示站点探测失败。

#### PIPIO-002 当前账户

```http
GET {origin}/api/user/self
Authorization: Bearer <system-token>
Pipio-User: <numeric-user-id>
```

已实测返回 `data` 对象，包含数值配额、已用配额、请求数、账户状态和权限元数据等字段。实现时只读取余额/配额、累计消耗、请求数和状态所需字段；用户身份、邮箱和权限等非必要字段直接忽略，不持久化、不进入诊断或汇总。

#### PIPIO-003 聚合统计

```http
GET {origin}/api/log/self/stat?start_timestamp=<seconds>&end_timestamp=<seconds>&model_name=<optional>
Authorization: Bearer <system-token>
Pipio-User: <numeric-user-id>
```

已实测 `data` 返回 `quota`、`rpm`、`tpm` 三个聚合字段；请求可使用 Unix 秒级 `start_timestamp`/`end_timestamp`。该接口不保证按模型拆分，模型维度首期从日志列表聚合。

#### PIPIO-004 日志列表

```http
GET {origin}/api/log/self?...pagination...
Authorization: Bearer <system-token>
Pipio-User: <numeric-user-id>
```

响应为分页 `data.page`、`data.page_size`、`data.total`、`data.items`；单条日志包含 `created_at`（Unix 秒）、`model_name`、`quota`、`prompt_tokens`、`completion_tokens`、`use_time`、`is_stream` 等字段。首期可按时间窗口分页拉取并本地按日/模型聚合；`other` 字段和缓存命中率仍视为未知，不解析为强依赖。

### 6.3 DeepSeek 官方 API 合约（P1）

```http
GET https://api.deepseek.com/user/balance
Authorization: Bearer <deepseek-api-key>
```

只解析官方返回的可用状态、币种和余额字段。DeepSeek API Key 存本机 Relay 凭据文件，并固定请求 `GET https://api.deepseek.com/user/balance`。可选平台 userToken 另存于同一本机凭据文件，仅请求 `https://platform.deepseek.com/api/v0/usage/amount` 和 `/api/v0/usage/cost`，不读取 Cookie。

## 7. 数据设计

### DATABASE

本地数据库：`REQUIRED`（当前为版本化 JSON；SwiftData 不是运行前提）。
服务器数据库：`NOT_REQUIRED`。

### Account

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID | 本地主键/跨设备稳定标识 |
| providerKind | enum | pipio/deepSeek |
| displayName | String | 用户可编辑 |
| siteOrigin | URL/String | 规范化 origin，不含令牌 |
| credentialRef | String | 本地凭据文件 map key；Pipio 用户 ID 与令牌仅保存在私有应用数据目录 |
| enabled | Bool | 是否刷新和汇总 |
| lowBalanceThreshold | Decimal? | 账户级阈值 |
| sortOrder | Int | 默认手动顺序 |
| createdAt/updatedAt | Date | UTC |
| deletedAt | Date? | tombstone |

索引：仅保证 `id` 唯一；不得使用用户 ID、令牌、其哈希或可逆派生值构造索引。首期不做基于秘密字段的自动去重，重复账户由显示名、站点和用户确认处理。

### AccountSnapshot

| 字段 | 类型 | 说明 |
|---|---|---|
| accountId | UUID | 关联账户 |
| balanceAmount | Decimal? | 未知可空 |
| currencyCode | String? | ISO 代码或站点单位 |
| todaySpend | Decimal? | 未知可空 |
| monthSpend | Decimal? | 未知可空 |
| requestCount | Int64? | 未知可空 |
| tokenCount | Int64? | 未知可空 |
| cacheHitRate | Decimal? | 0...1；未支持为空 |
| capabilities | OptionSet/raw | 实际能力 |
| fetchedAt | Date | 本次完成时间 |
| sourceUpdatedAt | Date? | 服务端时间 |
| freshness | enum | fresh/stale/partial |

每账户只保留一条 current snapshot；历史进入 `DailyUsage`。

### DailyUsage

唯一键：`accountId + localDate + timeZoneId`。

字段：消费金额、币种、请求数、输入/输出/缓存 Token、是否完整、来源更新时间。

### ModelDailyUsage

唯一键：`accountId + localDate + modelName`。保存 token/request/spend 聚合，不保存单次日志。

### RefreshState

每账户保存最近成功时间、最近尝试时间、连续失败次数、下次允许刷新时间、脱敏错误代码。

### AppSettings

刷新间隔、状态栏显示项、外观、默认页面、低余额默认值（20）、历史保留策略（默认 1 年/可选永久）、iCloud Drive 同步目录书签、文件同步开关、汇率刷新频率（默认 7 天）。

### SyncEnvelope

同步文件顶层结构：

```text
schemaVersion
exportedAt
writerDeviceId
accounts[]
dailyUsage[]
modelDailyUsage[]
preferences
tombstones[]
```

- `writerDeviceId` 是随机设备 UUID，不包含账户身份。
- `accounts[]` 不包含 `credentialRef`、令牌或 Pipio 用户 ID；导入后按 `Account.id` 关联本地凭据。
- 永久历史仍只保存日/模型聚合，不保存单次请求日志。
- schema 升级必须向后读取至少一个旧版本；未知新版本只读保护，不覆盖。

### RetentionPolicy

- `.oneYear`：默认，滚动保留最近 365 个本地日期。
- `.forever`：不按时间自动删除聚合历史。
- 清理只作用于聚合记录；tombstone 按独立周期保留，确保删除已传播后再回收。

## 8. 前端设计

### 8.1 菜单栏折叠态

元素：模板图标、可选金额、完整性/异常提示。
状态：无账户、正常、部分未知、刷新中、过期、认证失败。

### 8.2 首页面板

- 顶部：总余额、今日消费（仅完整时）、账户数、最近刷新；今日数据不完整时整个今日字段隐藏。
- 中部：账户卡片列表；默认按手动顺序。
- 底部：刷新、添加、设置。
- 首次无账户时显示引导，不显示空图表。
- 高度超过上限后列表滚动，顶部总览和底部操作保持可达。

### 8.3 添加/编辑账户

步骤：选择供应商 → 输入站点/身份/凭据 → 验证 → 展示可用能力 → 保存。

Pipio 表单明确区分：

- 站点地址（可粘贴 `/v1` 地址，应用负责规范化）
- 系统令牌
- 数值用户 ID (`Pipio-User`)

令牌和数值用户 ID 均按敏感输入处理：保存后不回显现有值，编辑时仅支持留空保持或覆盖更新。

### 8.4 账户详情

- 概览指标。
- 能力支持时显示用量和分模型数据。
- 7/30 日切换。
- 显示数据更新时间和来源状态。
- 编辑/禁用/删除放在更多菜单；删除二次确认。

### 8.5 设置

- 账户
- 刷新、汇率与低余额
- 状态栏与外观
- 登录项/快捷键
- iCloud 云盘文件同步（默认 `文稿/Relay`）
- 高级（缓存、数据保留、诊断信息）

诊断导出必须脱敏，不包含令牌、Pipio 用户 ID、Cookie、邮箱、姓名或原始认证响应。

## 9. 错误处理

| 场景 | 领域错误 | UI 行为 |
|---|---|---|
| 未填 Pipio 用户 ID | validation | 阻止验证并定位字段 |
| `/v1/api/...` 误拼 | invalidBaseURL | 自动规范化；诊断显示管理基址 |
| 401 缺少 Pipio-User | missingUserHeader | 提示填写数值用户 ID |
| 401 Invalid token | credentialInvalid/typeMismatch | 提示令牌无效或类型不匹配，不自动重试 |
| 403 | forbidden | 保留旧数据，提示无权限 |
| 429 | rateLimited | 按 Retry-After 延迟 |
| 5xx/超时 | transient | 保留旧数据并退避 |
| JSON 字段变化 | responseIncompatible | 当前账户标记部分失败；仅保存错误代码和结构版本，不保存原始响应或身份字段 |
| 指标缺失 | unsupported/unknown | 隐藏或标注未知，不显示 0 |
| 同步目录不可用/冲突 | syncUnavailable/syncConflict | 本地照常工作；提示重新授权目录或处理冲突 |
| 本地凭据文件读取失败 | credentialUnavailable | 提示重新录入 |

## 10. 安全设计

- 代码、测试夹具和文档均不得包含真实令牌或真实 Pipio 用户 ID；只能使用字段名、协议示例和明确的占位符。
- 网络日志通过统一 `RedactingLogger`，过滤 Authorization、`Pipio-User`、Cookie、Token、userToken 和查询中的敏感项。
- UI state 不存明文 credential；验证表单离开后清空。
- 不枚举 `Pipio-User`，不尝试访问不属于用户的账户。
- 站点 URL 只允许 HTTPS；重定向到不同 origin 时默认拒绝携带认证头。
- 同步文件、本地 JSON 序列化和诊断导出需检查令牌、用户 ID 及其派生值永不进入序列化模型；凭据只能进入独立的本机凭据文件。

## 11. 测试关注点

### 单元测试

- `/v1` 输入到 origin/management/model 三种 URL 的规范化。
- Decimal 配额换算和缺失 `quota_per_unit`。
- 未知/null/0 的区分。
- 今日边界、时区和夏令时。
- 能力矩阵与 UI 字段可见性。
- 退避、429 Retry-After、401 不重试。
- 今日字段完整性、汇率过期，以及缺少可靠换算时拒绝跨币种求和。

### 集成测试

- MockURLProtocol 覆盖 status/self/stat/log 的 2xx、401、403、429、5xx、超时和畸形 JSON；夹具只使用明显的虚构占位值。
- 本地凭据文件新增、覆盖、删除、不可用和权限检查；验证本地 JSON、同步文件、日志及诊断导出均不出现令牌或用户 ID。
- 单账户失败不影响其他账户。
- 删除账户时本地数据、本机凭据文件与 tombstone 一致。
- iCloud 云盘离线、目录书签失效、文件冲突、schema 升级和恢复同步。
- 一年/永久保留策略切换及清理边界。
- 默认低余额阈值 20 的币种显示与用户覆盖。

### UI 测试

- 空状态、部分数据、过期数据、认证失效、刷新中。
- 菜单栏金额过长和无金额。
- 面板最大高度、键盘操作、VoiceOver、增强对比度、减少透明度。
- 删除和关闭文件同步的二次确认。

### 实机验证

- 菜单栏面板焦点/失焦关闭行为。
- 登录项、睡眠唤醒、网络切换。
- Liquid Glass 性能和文字可读性。

## 12. 重要风险

| 风险 | 影响 | 处理 |
|---|---|---|
| Pipio 管理接口非稳定公开合约 | 字段/路径变化导致统计失败 | 适配器隔离、容错 DTO、能力降级、契约测试 |
| 管理令牌与模型 API Key 语义不同 | 将管理令牌误用于 `/v1/models` 会得到 401 | 适配器分离 management/model credential；管理接口只走 `/api` |
| DeepSeek 平台历史接口是网页内部接口 | 接口/响应可能变化，userToken 可能过期 | 用户主动提供 token；解析失败保留余额并标记 partial，不把未知值写成 0 |
| iCloud 云盘是文件同步而非数据库 | 多设备并发可能产生冲突副本 | NSFileCoordinator、版本字段、确定性合并和冲突提示 |
| 首期为未公证、非沙盒的 GitHub 构建 | Gatekeeper 警告且应用权限边界弱于沙盒应用 | 发布校验和、公开源码/构建流程、最小文件访问、安装风险提示；优先使用系统“仍要打开”，不把移除 quarantine 冒充认证；未来取得 Developer ID 后签名公证并评估沙盒 |
| 多币种汇总 | 过期或缺失汇率导致总额误导 | 使用 Pipio 发布值、默认 7 天刷新、过期标记；无法可靠换算时不汇总 |

## 13. NEEDS_CONFIRMATION

`NONE`：当前 Architecture 阶段无待确认项。

已确认：Bundle ID 为 `cloud.dinghao.relay`；GitHub Releases 发布；不使用 CloudKit Container；同步使用 `iCloud Drive/文稿/Relay` 普通文件；凭据不通过任何 iCloud 机制同步；凭据存放在本机私有应用数据目录而不是 Keychain；DeepSeek 余额使用官方接口，历史用量使用可选的用户手动输入 userToken；汇率默认每 7 天刷新；历史默认 1 年并可选永久；低余额默认 20；今日数据不完整时隐藏该字段。

## 14. 设计决策

### D-001 原生单体应用

**决定**：SwiftUI/AppKit 单体，无 Relay 后端。
**原因**：需求只需要本机读取供应商 API 和 iCloud 云盘普通文件同步，自建服务增加隐私与维护成本。
**日期**：2026-09-18。

### D-002 供应商适配器 + 统一领域模型

**决定**：每个供应商独立 Adapter，UI 只读取统一快照与能力。
**原因**：第三方接口字段和能力差异大，需支持降级且避免供应商逻辑渗入 UI。
**日期**：2026-09-18。

### D-003 凭据与同步数据分离

**决定**：令牌和供应商用户 ID 仅在请求期间短暂驻留内存，持久化时只存当前 Mac 的非同步 Relay 凭据文件；本地 JSON repository 和 iCloud 云盘同步文件只存非秘密数据。凭据不跨设备同步。
**原因**：用户已明确选择不使用 Keychain，同时禁止凭据通过 iCloud Keychain、iCloud 云盘文件或其他 iCloud 机制同步；其他设备必须重新录入。
**日期**：2026-09-18。

### D-004 Pipio 双基址

**决定**：模型 API `/v1` 与管理 API `/api` 分开建模。
**原因**：2026-09-18 实测 `/v1/api/...` 为 404，而 `/api/status` 可用。
**日期**：2026-09-18。

### D-005 iCloud 云盘文件同步

**决定**：不使用 CloudKit；采用版本化 JSON 普通文件同步，默认逻辑目录为 `iCloud Drive/文稿/Relay`。首次设置时通过系统目录选择器确认实际目录并保存 bookmark，不硬编码本地化物理路径。
**原因**：用户明确选择 iCloud 云盘文件同步，同时要求凭据不参与同步。
**日期**：2026-09-18。

### D-006 GitHub 非 App Store 发布

**决定**：Bundle ID 使用 `cloud.dinghao.relay`，通过 GitHub Releases 发布；当前构建使用 ad-hoc 签名，不把 Developer ID 公证作为首期要求。
**原因**：用户明确不在 App Store 上架且当前没有付费开发者账户。
**日期**：2026-09-18。

### D-007 数据默认值

**决定**：汇率默认每 7 天刷新；历史默认保留 1 年并可选永久；低余额阈值默认 20；今日数据不完整时隐藏今日消费字段。
**原因**：用户已明确产品行为。
**日期**：2026-09-18。

## 13. 本轮实现记录（2026-09-18）

- `RelayStore` 已接入菜单栏 UI，负责本地缓存加载、账户添加、真实测活、保存、刷新、删除和错误状态。
- `AccountAddModalView` 不再构造假的 `AccountModel`，而是创建 `AccountDraft`，由业务层真实调用供应商接口。
- `MainPopoverView` 不再维护孤立的内存账号数组；账户列表、汇总和刷新状态都来自 `RelayStore`。
- `AccountModel.balance` 已改为可选，未知余额显示 `--`。
- `FileLocalRepository` 也使用 `0700` 目录和 `0600` 文件权限；凭据仍只由 `FileCredentialStore` 保存。
- 独立安全设计变更见 `docs/SECURITY_DESIGN.md`。

## 14. 2026-09-19 Implementation Update

- 账户编辑采用凭据先验证、元数据提交、失败回滚旧凭据的事务式顺序；UI 仅在 `async throws` 成功后关闭。
- `ProviderSnapshot.modelUsages` 为可选的模型聚合列表，Pipio 通过 `/api/log/self` 当日分页日志聚合模型、请求数、Token 和消费；解析失败只降级该能力。
- 设置持久化支持历史保留策略（1 年/永久）和 1/5/15/30 分钟自动刷新频率，默认 5 分钟。
- iCloud 普通文件路径使用 `NSFileCoordinator` 协调读写，导入时尝试合并可解码的冲突版本；首次启用先导入再导出，凭据仍不进入 payload。
- 删除账户 UI 增加二次确认，避免误删本地凭据和同步 tombstone。

## 15. 2026-09-20 本轮设计落地

### D-008 全局快捷键运行时

使用 AppKit `NSStatusItem + NSPopover` 作为菜单栏面板的显式控制目标；Carbon `RegisterEventHotKey` 负责注册快捷键。快捷键服务通过 runtime 抽象隔离系统注册，支持事务性回滚和离线契约测试。快捷键配置只保存 key code 与 modifier，不同步凭据或业务数据。

### D-009 DeepSeek 余额与可选历史用量

余额使用 API Key 请求官方 `GET https://api.deepseek.com/user/balance`；历史用量在用户手动提供平台 userToken 后请求 `platform.deepseek.com/api/v0/usage/amount` 和 `/api/v0/usage/cost`。未填写 token 时只获取余额；填写后首次回填最近 7 天，当天快照优先。Relay 不读取浏览器 Cookie，平台接口失败时保留余额并标记 partial；未知值不转换为 0。DeepSeek 历史月份、日桶、今日消费和首次 7 天回填固定按 GMT+8（北京时间）计算，不跟随 Mac 本地时区。

### D-010 iCloud 冲突状态机

`FileSyncService` 在发现多个远端候选或 unresolved conflict versions 时生成不可变 `SyncConflictReport`，并暂停本次自动合并写回。`RelayStore.resolveSyncConflict` 通过 `FileSyncService.resolve` 应用用户明确选择的 resolution；候选文件保留，不由 resolution 自动删除。同步目录不可用时使用 `unavailable` 状态，同时保持本机 repository 可用。

### D-011 验证边界

确定性同步脚本的退出码 2 表示无 fixture 失败但缺少真实第二台 Mac；此结果是环境阻塞而非通过。当前命令行工具链的 SDK/compiler mismatch 使 `swift build` 无法完成，交付报告必须单独列出该阻塞。

### 2026-09-21：菜单栏状态保留与 Pipio 看板契约修正

本段替代此前通过 `/api/log/self` 分页聚合模型明细的方案。Pipio 公开数据看板当前使用 `/api/data/self?start_timestamp=…&end_timestamp=…` 的数组数据进行模型 Token 明细聚合，`/api/data/flow/self` 属于另一块流量明细，不混用。独立 `PipioDashboardParser` 负责字段解码、时间筛选、模型合并和完整性判断，适配器继续隔离可选能力失败。余额、今日/月消费已有接口保持不变。

`RelayMenuBarController` 保留辅助窗口及其 SwiftUI 状态；点击外部/再次点击入口使用 `orderOut`，再次打开复用窗口，显式关闭才释放。打开详情/设置/表单前记录首页内容屏幕坐标用于定位，并按屏幕可视区域限制边界。固定宽度 70 点，无金额时缩为仅图标入口；缩窄后的双行显示及多屏定位仍需打包 GUI 实测。

Pipio 换算按账户读取公开 `usd_exchange_rate`，有效正数才允许 USD→CNY 汇总。真实账户模型数、金额及系统令牌授权范围仍需有效凭据验证，合成 fixture 不作为真实对账结论。

### 2026-09-21：区分额度参数与外汇参数

`AccountConfiguration.manualUSDToCNY: Decimal?` 是可选非秘密元数据，旧 JSON 缺少该字段时兼容解码为 nil。`ManualExchangeRateUpdate` 区分不修改、设置和清空，避免无关账户编辑清除手动值。业务层在凭据读写/验证之前校验正数，沿用事务写入和账户 `updatedAt` 合并语义；同步安全投影显式保留该字段。

`AccountRate` 始终记录站点原始参数、来源、获取/过期时间，`quota_per_unit` 只用于适配器归一化。`RelayStore` 将账户级手动 FX 字典交给 `DashboardAggregator`，只在 USD→CNY 汇总时使用，保存立即重算，不重写快照或历史。无有效手动值时才回落到未过期站点汇率；已知原生金额配合手动 FX 不继承站点 FX 过期时间。手动值不会补全未知原生金额、过期今日消费或未知额度除数。

编辑页保留原表单风格，增加独立汇率区；参数只读、手动输入留空恢复自动，内容区域滚动，按钮固定。仅更新本地元数据无需系统令牌；真实站点对账仍需单独验证。

### 2026-09-21：消费展示与模型统计修正

替代前述菜单栏余额/今日双行显示和缓存比例无回退的约定：`MenuBarStatusPresentation` 统一数值与状态符号，AppKit 用模板 `NSImage(systemSymbolName:)` 交给系统着色；只给完整且已启用显示的今日消费生成两位小数文本。金额换算逻辑不变，首页余额不受影响。

`PipioDashboardParser` 继续只请求公开 `/api/data/self` 数据契约。`token_used` 缺失时使用该桶有效非负普通输入+缓存读取+缓存写入+输出计数，再跨桶求和；提供商明确返回的总数优先。原缓存覆盖契约可用时不改结果，否则以 `sum(cache_read_tokens) / sum(input_tokens + cache_read_tokens + cache_write_tokens)` 计算模型级加权比例。三个输入分量均须存在且非负，分母须大于零；缓存读取可以大于普通输入，明确零读取返回零占比。该回退按用户确认不再依赖旧覆盖计数字段；覆盖不完整时只代表已获取明细，禁止用可能覆盖不同请求的 `token_used - output_tokens` 替代分母。合成测试包含用户表格转录的五模型数据、多模型交错桶、非零写入和缺失/溢出边界，不代表认证 API 已对账。

`ModelUsageSummary.spendDescending` 在解析与展示入口复用，保留免费/未知模型并稳定排序。Token 展示列固定宽度以避免被长模型名挤占。现有持久化与同步 schema 不变；派生总数与缓存比例在下次刷新时获得，无需迁移，排序立即应用于旧快照。

### 2026-09-21：表单反馈与今日消费统一

替代前文“今日消费保持原 stat 接口”的约定：`PipioDashboardParser.usage` 从一次解码后的当天看板时间桶产生原生消费总额和分模型明细，总额基于原始 quota，不基于已格式化/四舍五入后的 UI 字符串。模型计数溢出等可选明细错误与有效总金额隔离。适配器不再另查当日 stat，月统计与余额不变；当日能力根据金额是否可确认设置。历史回填只查询已完成日期，今日记录由创建/刷新快照负责写入。

`AccountDraft` 统一收集空字段，业务层在 URL 归一化、选取适配器、网络和持久化之前抛出带字段名的 `AccountServiceError`。展示模型保留原始 `tokenCount` 和完整字符串；`RelayNumberFormatter.tokens` 只负责显示缩写，临界四舍五入到 1000 时提升单位。首页汇总卡片仅调整内部对齐。

`RelayMenuBarController` 给详情窗口标记关闭后返回首页；原生 `windowWillClose` 先释放详情引用，再在下一主线程事件重新展示现有 Popover。切换辅助窗口前清除返回标记，避免误弹首页；`orderOut` 隐藏不触发返回。详情底部按钮明确命名“返回首页”，右上角按钮增加相同辅助说明。

### 辅助窗口统一返回首页

替代 `returnsToDashboard` 逐页开关：所有通过 `RelayMenuBarController.presentAuxiliaryWindow` 打开的窗口统一由 `windowWillClose` 清理引用并在下一主队列事件展示首页。设置完成、表单取消/保存成功及自定义关闭沿用公共 `closeAuxiliaryWindow`，原生窗口关闭使用同一委托路径。页面保存失败不调用关闭回调。

替换旧页面前先移除旧窗口委托，再关闭旧窗口，避免触发返回首页。`pendingDashboardReturn` 请求标识使延迟返回可以被 `close()`、`toggle()` 或页面替换取消，避免已收起或已切换后又意外弹出首页。隐藏仍使用 `orderOut`，不释放页面状态。页面结构不变，设置/添加/编辑的右上角按钮补充“返回首页”悬停和辅助功能标签。

`scripts/test-window-navigation.sh` 是需登录图形会话的独立 AppKit 集成检查，使用内存数据和实际首页回调，检查四类页面的窗口关闭、隐藏/恢复、页面替换及延迟返回取消；不调用服务商接口。不纳入仅业务层的离线回归脚本。

### 辅助页面面板视觉统一（2026-09-22）

设置、添加账号、编辑账号和账号详情继续使用独立 `NSWindow` 承载复杂表单与滚动内容，避免直接嵌入菜单栏 `NSPopover` 时出现失焦或交互不稳定；但窗口统一改为无标题栏的无边框 key window。窗口外观由共享的 Relay 面板容器提供，与首页使用相同的 `regularMaterial`、圆角和阴影，页面内部保留统一的标题及“返回首页/关闭”操作。这样只保留普通窗口的交互稳定性，不再向用户暴露 macOS 原生关闭、最小化和缩放标题栏。

### 2026-09-22：Relay 全局原生材质视觉统一

首页、账户详情、添加/编辑账户、设置、全局快捷键和同步冲突页面统一使用 `RelayVisualStyle` 提供的 SwiftUI 原生 `regularMaterial` / `thinMaterial` / `ultraThinMaterial`。容器与卡片保留现有尺寸、布局、功能和导航，只统一材质层级、圆角、细边缘和阴影；文字继续使用系统语义色，保证浅色壁纸透入时仍有足够对比度。不得通过自绘渐变或自定义模糊替代系统材质。

### 2026-10-07：原子刷新与详情完整读取

常规刷新先计算对应日历史，再调用 `LocalRepository.commitRefresh(snapshot, dailyUsage:)`。文件 repository 在单个候选状态中更新快照和可选历史，经一次原子写入成功后才替换内存状态；不能先推进 workbuddy2api 累计值再写历史，否则存储失败会永久丢失增量。没有新增持久化字段，原有 JSON 和同步文件保持兼容。

`RelayStore.reloadFromRepository` 先完整读取设置、账户、所有账户快照和每账户最近 30 条日历史，再发布。详情使用完整快照/历史缓存，首页仍使用启用及可见性过滤；子账户投影共用状态构建逻辑，但详情定位不依赖 `dashboardAccounts`。读取失败保留完整缓存和原窗口，发布 `repositoryErrorMessage`，并继续按当前时间使今日消费等时效字段失效。

详情容器根据 `AccountDetailState` 展示最新数据、上次成功数据及读取失败提示，或仅在完整读取确认移除后返回首页。现有布局不变，错误占用底部已有更新时间文本位置并提供悬停全文。离线回归覆盖实际文件写入失败/恢复、累计基线持久化与去重、隐藏/停用子账户详情、部分读取失败、跨日失效和错误恢复；窗口脚本补充相应 GUI 用例，需正常登录图形会话执行。

## 16. 2026-10-09 当前软件优化方向评估（仅设计，未实施）

### 16.1 评估范围与当前基线

本节是对当前工作区实现的优化路线评估，不改变 `REQUIREMENT.md` 已确认的产品范围，也不表示下列方案已经实现。

已核实的当前基线：

- 本地回归脚本覆盖凭据原子写入、刷新事务、历史去重、同步合并、账户详情故障隔离和三个已接入供应商的关键契约；2026-10-09 在当前环境执行通过。
- iCloud 确定性验证中的 `SYNC-001` 至 `SYNC-004` 通过；`SYNC-005`（真实第二台 Mac）按脚本设计返回 `blocked`，不能视作多设备验收通过。
- `RefreshCoordinator.refreshAll` 当前顺序刷新全部启用账户；`RelayStore` 以单个全局 `isRefreshing` 防止重叠刷新。
- 发布检查仅从 GitHub Releases 选择 Apple Silicon 包并下载到用户下载目录；当前版本没有安装包的哈希、签名或公证校验链。
- 本地数据仍是单个版本化 JSON 文件。刷新提交已具备快照与当日历史的一次原子提交语义；凭据仍按已确认决策保存于私有本地文件，不进入同步文件。

本轮没有发现应立即改动的业务功能缺陷；以下路线按风险、用户可感知收益和实施成本排序。

### 16.2 优先级排序

| 优先级 | 优化项 | 主要收益 | 触发依据 | 本轮结论 |
| --- | --- | --- | --- | --- |
| P0 | 刷新调度、限流与取消 | 多账户场景下缩短等待，避免过时任务占用网络 | 当前全量刷新逐账户串行，且全局刷新状态会阻塞单账户重试 | 建议作为下一项实现 |
| P0 | 更新包完整性与来源验证 | 降低下载篡改、错包与误安装风险 | 当前仅限制 GitHub 下载地址和文件名/后缀；发布仍为 ad-hoc 签名路线 | 需要先确认发布身份方案 |
| P0 | 真实双 Mac 同步验收 | 关闭数据正确性与可恢复性的剩余验证缺口 | `SYNC-005` 尚未执行 | 不需要先改业务代码 |
| P1 | 供应商健康状态与可诊断反馈 | 更快区分账户凭据、限流、接口变更和网络故障 | 当前 UI 有账户错误文案，但没有可持续的刷新健康摘要 | 建议与刷新调度一起设计 |
| P1 | 测试分层与 GUI/可访问性自动化 | 降低菜单栏、无边框窗口和系统版本升级回归风险 | 现有离线脚本覆盖丰富，但图形检查需要登录会话，尚未进入 CI 主路径 | 建议逐步补充 |
| P2 | JSON 存储的容量阈值与读取优化 | 在长期保留、大量账户时避免全量编解码放大 | 每次写入替换整个状态；重新加载会按账户读取最近 30 条历史 | 先度量，暂不迁移存储技术 |
| P2 | 状态与设置页面拆分 | 降低后续功能迭代的耦合与回归面 | `RelayStore` 同时承担编排、投影、通知和同步状态，设置页面职责集中 | 作为结构性整理，不应抢占 P0 |

### 16.3 P0-1：刷新编排改造

#### 目标

在维持“一个账户失败不影响其他账户”“旧快照不被失败覆盖”“供应商凭据不进入 UI 状态”的既有约束下，使全量刷新可并发、可取消、可合并，并对各供应商保持有限并发。

#### 拟定方案

1. 将“刷新请求”定义为带来源的意图：`scheduled`、`manualAll`、`manualAccount`、`afterAccountSave`。UI 仅提交意图，不直接创建无管理的 `Task`。
2. 新增仅负责运行期编排的 `RefreshScheduler`（可由 `RelayStore` 持有）：
   - 同一账户在途时合并相同请求；手动请求可以提升优先级，但不重复发起相同网络读取。
   - 全量任务采用受限任务组并发执行；初始并发上限建议为 3，并按 provider/host 设置独立上限为 1，避免对单一站点突发并发。
   - 应用退出、账号禁用/删除、设置缩短刷新周期或新一轮手动刷新时，取消已不再有意义的等待与退避；取消不得写入失败状态或覆盖已保存快照。
   - 继续由每个账户自己的 `RefreshCoordinator` 路径计算快照与日历史，并用既有 `commitRefresh` 原子提交；调度器不得绕过 repository 事务。
3. `RelayStore` 改为发布“整体是否在刷新”和“账户级刷新阶段/最近结果”两个投影。首页保留现在的刷新按钮语义；账号行可以显示仅属于该账户的进行中或失败状态。
4. 退避继续识别 `Retry-After`，但调度层应记录下一次允许尝试时间，以免定时循环在限流窗口内重复启动同类请求。

#### 不在本项范围内

- 不改变 Pipio、DeepSeek、workbuddy2api 的请求协议或统计口径。
- 不增加远程队列、服务端或分析上报。
- 不将账户刷新结果合并为不可靠的跨币种总额。

#### 验收与回归重点

- 3 个以上账户时，慢账户不阻塞其他独立账户完成；同 host 不超过设定并发。
- 定时刷新与手动刷新重叠时，同一账户请求数可预测且不会重复记入 workbuddy2api 增量。
- 取消期间不写入半成品快照、不清除旧错误以外的数据，下一次刷新可正常恢复。
- 限流、认证失败、网络超时与取消在账号行显示不同的可行动含义，但错误信息不得包含 token、用户 ID 或响应原文中的秘密。
- 补充纯 Swift 调度契约测试，使用可控时钟与假 adapter；保留现有原子刷新回归组。

### 16.4 P0-2：更新安全链（原评估方案，实施选择见第 17 节）

#### 目标

使用户在下载更新前能够验证包与项目发布物的对应关系，且不把“已下载”误表述为“可信安装”。

#### 拟定方案

1. Release 同时发布机器可读的 manifest：版本、资产名、SHA-256、构建提交 SHA、生成时间和签名/公证状态；manifest 本身由发布身份签名。
2. `UpdateService` 在下载完成后校验：允许的 GitHub 主机、manifest 中的资产名、文件长度（如提供）和 SHA-256；校验失败删除临时文件并显示明确失败原因。
3. 安装前在本机执行只读校验：DMG/应用解包后的 `codesign --verify` 与预期 Team ID/Designated Requirement 比较；若未来使用 Developer ID，再检查 notarization/Gatekeeper 评估结果。
4. 在“关于/更新”界面展示验证状态：仅下载、哈希已验证、签名已验证、无法验证；不自动替换正在运行的应用。
5. CI 在创建 Release 前生成 manifest，并以独立校验步骤重新计算产物哈希，防止上传步骤与元数据脱节。

#### 发布身份选择（已于 2026-10-09 确认不使用 Developer ID/公证）

当前设计明确允许 ad-hoc 签名和用户手动放行 Gatekeeper。强制校验稳定 Team ID 或公证状态，需要用户选择以下之一后才能定案：

- 继续 ad-hoc 路线：实施 GitHub Release manifest + SHA-256 校验，并在 UI 明确提示“文件完整性已核对，但未具备 Developer ID 身份验证”。
- 迁移 Developer ID：增加证书保管、CI 签名/公证和 Team ID 固定校验；成本和发布流程会变化。

在确认前，不应把代码签名校验写成当前已具备的能力。

### 16.5 P0-3：iCloud 双机验收

此项是验证工作流而非功能扩张。应按 `docs/verification/icloud-multidevice.md` 用两个实际 Mac 和同一 Apple ID 执行以下场景，并把结果留在一次发布验收记录中：首次导入、双端不同修改、删除 tombstone、iCloud 延迟下载、冲突副本、离线编辑后恢复、旧版本/损坏文件。

准入规则：任何一个场景没有确认“凭据不出本机、合并后账户可读、冲突时不静默覆盖”前，不把 iCloud 同步标记为完全验收；但不影响本地优先使用。

### 16.6 P1：用户可感知的可用性提升

#### 账户健康摘要

在不记录敏感请求内容的前提下，为每个账户维护非秘密的运行期摘要：最近成功刷新时间、最近失败分类、连续失败次数、是否正在退避、数据新鲜度。首页优先展示“需要操作”的状态，例如重新录入凭据、等待限流或检查网络；详情页才展示更完整的时间线。该摘要默认不进入 iCloud 同步，除非后续有明确的跨设备产品需求。

#### 图表与信息密度

趋势图在 7/30 日数据较多时应只标注选中点、最后点和极值，避免每个点都绘制数字标签造成重叠；无数据与部分数据继续使用现有“未知不等于 0”语义。该项仅调整呈现密度，不重画已确认的原生材质、导航和面板结构。

#### 可访问性与窗口回归

已存在部分按钮的辅助标签和悬停说明，后续应补齐列表操作、刷新状态、图表替代文本和更新验证状态；在已登录图形会话下把 `scripts/test-window-navigation.sh` 扩展为可重复的 GUI 验收，并在支持该能力的 CI runner 上作为独立必需检查。业务层离线脚本继续保持无图形依赖。

### 16.7 P2：容量与代码结构的保护性演进

#### 存储容量

不预设迁移 SwiftData 或数据库。先在 debug/测试中记录以下非秘密指标：账户数、历史条数、单个 JSON 文件大小、一次 reload/commit 耗时。建议阈值为任一条件连续出现：同步文件超过 5 MB、单账户历史超过 3,000 条、或典型刷新提交/详情加载超过 200 ms。达到阈值后再评估：

- 保持 JSON schema，通过按账户历史分片、摘要索引和惰性读取降低全量编解码；或
- 在不改变 `LocalRepository` 公开契约的前提下引入本地数据库实现，并设计一次性、可回滚迁移。

同步 payload 与凭据隔离、删除 tombstone 和版本兼容性是迁移的硬约束。

#### 结构拆分

优先按运行期职责拆分而不是引入新的通用框架：将刷新编排、同步状态、低余额通知和详情投影从 `RelayStore` 分离为小型可测试组件；将设置页面按“通用/数据/账户/同步/关于”拆为子视图和独立表单状态。对外 UI 行为、`LocalRepository` 和 provider adapter 契约保持稳定。此项必须在 P0 调度改造完成且回归覆盖不下降后再开始。

### 16.8 推荐实施顺序与阶段出口

1. **阶段 A：刷新调度设计与实现。** 先完成可控时钟、取消、去重、host 限流的测试，再替换顺序全量刷新；阶段出口是现有回归全绿并新增多账户并发/取消/去重测试。
2. **阶段 B：更新完整性。** 根据发布身份确认实现 manifest 校验；阶段出口是 CI 产物可独立复算哈希，客户端可拒绝篡改 fixture。
3. **阶段 C：双机验收。** 不等待新功能，执行真实 iCloud 验收；阶段出口是 `SYNC-005` 有真实设备记录，或明确记录阻塞原因与风险接受人。
4. **阶段 D：可用性与可维护性。** 按实际使用反馈优先做健康摘要、图表密度和可访问性；容量/结构性整理以量测阈值触发。

### 16.9 长期文档更新建议

`docs/AI_CONTEXT.md` 第 9 节及 2026-09-21 补充已记录指定 SDK/缓存路径可构建，覆盖了更早的编译器/SDK 不匹配记录。2026-10-09 再次验证该命令通过，仅有 Command Line Tools 链接搜索路径警告；不需要将此事实重复写回。建议之后维护长期上下文时整理旧环境描述，并补充本轮调度、更新校验、历史索引与设置子页事实；保留真实双 Mac iCloud 未验证状态。本轮未直接修改 `AI_CONTEXT.md`。


## 17. 2026-10-09 整合实施方案与分工

本节补充第 16 节的评估，记录用户已确认的实施选择及对应代码入口。已授权实现；不是把拟实施方案写入长期上下文。

### 17.1 已确认边界

- 不使用 Developer ID、公证或 Keychain；继续 ad-hoc 签名与手动替换安装。第 16 节“签名 manifest/固定 Team ID”不在本轮范围。
- 真实双 Mac 验收按用户决定跳过，保持“未验证”，不标记通过。
- 保留原有视觉材质、窗口尺寸、导航、供应商统计口径和 JSON schema；不引入数据库、远程服务或第三方依赖。

### 17.2 并行工作包与集成边界

| 工作包 | 主要写入范围 | 集成点 | 状态 |
| --- | --- | --- | --- |
| A 刷新与健康 | `RefreshScheduler`、`RefreshCoordinator`、`RelayStore`、健康模型、首页/详情 | 账户级结果、运行期健康回调、现有原子 `commitRefresh` | 已实现，统一回归验证 |
| B 更新完整性 | `UpdateService`、打包脚本、发布 workflow、新增测试 | 保持原有更新/下载调用接口；校验后才交付文件 | 已实现，离线校验验证 |
| C 图表与设置 | 趋势图、设置窗口及六个设置子页 | 使用原有领域模型/绑定/回调；由窗口保持编辑状态 | 已实现，选择/标签契约验证 |
| D 存储容量 | `FileLocalRepository`、诊断、新增索引测试 | JSON schema 不变；只在成功提交后替换内存与索引 | 已实现，成功/失败路径验证 |
| E 验证入口 | 独立契约入口、GUI 检查脚本/测试 | 无头契约可必需执行，真实 GUI 明确分开 | 已实现，GUI 会话受环境限制 |

各工作包写集分离，最后统一连接回归入口和文档；GUI/双机结果不能由离线 fixture 冒充。

### 17.3 刷新数据流与取消语义

`RelayStore.refreshAll/refresh` → `RefreshCoordinator` → `RefreshScheduler` → 单账户 adapter/rate → 配置与订阅状态校验 → `LocalRepository.commitRefresh` → 运行期健康/详情投影。

- 调度器维护全局最多 3 个运行账户、同一规范化原点最多 1 个；HTTP 默认 80、HTTPS 默认 443 显式归一化。同账户在途请求共享结果，排队请求可升级强制汇率和手动优先级；已经开始的请求不额外复制网络操作。
- 调度器拥有运行任务与订阅者。单个订阅者取消只解除自身等待；最后一个订阅者取消终止任务。取消标记通过加锁 ticket 同步记录，避免异步 MainActor 清理晚于结果提交；返回订阅结果前也检查取消。
- 停用、删除、编辑和应用退出调用显式取消入口。取消中的非协作 adapter 未退出前仍保留账户/原点槽位，后继请求不能并行计入同一账户增量。
- 最后提交前重新读取账户，比较完整配置并检查是否仍存在有效订阅者；校验与原子提交之间不发生 actor suspension。已完成的原子提交不因之后到达的取消撤销。
- 限流按原点共享内存冷却表；数值和 HTTP 日期 `Retry-After` 均解析。收到限流响应后即使任务被取消也保留冷却，但不发布账户失败。无效等待值默认 60 秒；长冷却最多每 24 小时重新检查一次，不提前缩短供应商给出的期限（极端日期限制为 Foundation distantFuture）。
- 仅网络、HTTP 5xx 和限流可重试；取消不是网络错误，本地写入失败归类存储而非网络。重试当前保留运行槽位，刻意避免同站点突发重试；后续可根据实测考虑退避时释放全局槽位。
- 自动任务使用 scheduled 来源；UI 提交手动请求，调度器管理真正的在途操作。账户完成后立即更新本地显示，不必等全部账户完成；同步交换沿用原有整轮结束逻辑。

### 17.4 账户健康与反馈

`AccountHealth` 非 Codable，保留阶段、最近成功时间、连续终态失败次数、分类、可重试时间及新鲜度。重试中的每次失败不重复计为一轮失败；成功清零，取消保持之前失败状态。旧快照提供首次运行后的最近成功时间。

首页现有状态位置显示排队、刷新、限流/退避或具体可行动提示，完整摘要通过悬停/辅助描述读取；详情底部沿用已有时间/错误区域。摘要中的最近成功时间不使用“本次请求完成时间”替代；长时间未成功的新鲜度仅影响健康描述，不改金额/汇率的既有严格有效性判断。

### 17.5 更新校验与发布行为

- 精确绑定 `DavisDing/Relay`、Release tag、语义版本、资产名与原始下载路径；下载前重读该 tag 的元数据，而不是只依赖最新版本查询。
- 优先采用该资产的 `sha256:<hex>` digest；digest 缺失才读取同 Release 的 `Relay-<version>-sha256.txt`。畸形 digest 不降级绕过；checksum 拒绝重复或不匹配条目。
- 下载使用受限 HTTPS 重定向策略，验证最终主机/路径；在暂存文件中核对可用长度和流式 SHA-256 后才移入 Downloads。不覆盖已有文件，失败或取消清理暂存。
- 打包生成 ZIP/DMG 的版本化 checksum，CI 构建与 artifact 下载后分别复算，随 Release 发布。当前选择是同源未签名完整性记录，不提供独立发布者身份认证。
- 老版本若 digest/checksum 都缺失，应用内下载明确阻止；用户仍可选择手动安装。关于页及下载完成提示明确区分哈希已验证与未签名/未公证身份状态。

### 17.6 存储与界面职责

- `RepositoryPerformanceDiagnostics` 只在内存保留数量、JSON 字节数、初次加载/最近提交耗时与成功标记，无账户名、地址、凭据或响应文本。5 MB、单账户 3,000 条、200 ms 为建议调查阈值而非自动迁移或删除规则。
- `historyByAccount` 是已提交状态的排序投影，初始化和成功提交后构建；失败写入不替换索引、容量或状态，schema 不变。加载耗时不是整个 Store UI 重建耗时。
- 设置拆为通用、数据、账户、快捷键、同步、关于六个子页，共享布局工具与窗口编辑状态；不增加新的通用架构层。Store 已抽出调度/健康模型，本轮不大规模重写通知/同步/详情职责。
- 图表只使用已知数据点，点选/拖动/键盘/辅助调整共用选择；只保留选中、最后、极值标签，并在窄宽度时优先选中点、避免重叠。空数据和单点有明确呈现；日期标签仍沿用现有投影，不宣称未记录日期为零。

### 17.7 验证入口与未验证项

- `scripts/test-regressions.sh`：既有业务检查 + 新的调度/取消/冷却、更新完整性、存储索引/失败语义，并独立运行图表选择/标注检查。
- `scripts/test-contracts.sh`：分别运行既有 DeepSeek、全局快捷键、同步冲突契约及 GUI 会话预检 fixture；无用户目录、网络或真实凭据。
- `scripts/test-window-navigation.sh --build-only`：仅编译，CI 执行该项不等于 GUI 通过；`--check-session` 无有效会话时 skipped/77。实际 `--run` 需要图形会话，可打开模拟窗口，尚未实机执行。
- CI 同时接入离线回归、独立契约与 GUI 只编译步骤。生产 CI 发布、真实 GUI/VoiceOver、正式 release 模式打包及真实供应商调用不由本轮离线测试证明。
- 双 Mac 验收：用户明确跳过本轮；仍保留现有验证文档，未更改 fixture 或将其改为通过。

### 17.8 本轮本地验证记录（2026-10-09）

- 指定 MacOSX26.5 SDK、缓存目录及 scratch path 的 `swift build` 通过；仍有既有 Command Line Tools 链接搜索路径警告。不是 macOS 27/Xcode 27 正式发布验收。
- 扩展后的离线回归通过，包含原有业务组、更新完整性、刷新并发/去重/取消/配置校验/冷却/健康分类、历史索引与失败提交语义。图表选择/标注 24 个断言通过。
- 三组独立契约与 12 个 GUI 会话判断 fixture 通过；没有真实供应商请求、真实凭据或真实 iCloud 账户访问。
- GUI `--build-only` 通过；实际会话预检 skipped/77（无 Quartz GUI session / WindowServer）。没有执行真实窗口交互、VoiceOver 或视觉验收。
- 本地 debug 打包在更新工作包中通过，ZIP/DMG/checksum 可独立复算；未执行正式 release 模式打包或生产 CI 发布。
- 存储合成样本 8 账户/24,008 历史记录约 5.05 MB，一次观测的 80 次索引读取约 0.12 ms、原扫描排序约 359 ms。该样本用于证明索引效果，不是生产性能承诺或不稳定的耗时门禁。
- 真实双 Mac 验收按用户决定跳过，继续标记未验证。未修改其验证脚本的判定，也未把离线“两设备”模拟组当作真实双机结果。

## 18. 2026-10-10 增量优化评估（设计建议，未实施）

### 18.1 范围、证据与分类

目标是加强当前本地优先、多账户监控的可靠性、数据解释和维护效率。本轮基于工作区 `cfcb2f2` 的文档、代码、测试及 workflow 静态检查；未重跑构建、故障注入、真实供应商、GUI 或生产 CI。第 17.8 节的通过记录属于此前验证，不能充当本次或后续提交的测试结果。

已具备刷新并发/取消/去重、账户健康、下载 SHA-256 校验、图表选择、历史索引、设置分页及离线验证入口，不重复列为待开发功能。下列“需要加强”是代码路径分析；尚未做动态复现的影响明确保留验证边界。

| 顺序 | 方向 | 分类 | 当前依据与收益 |
| --- | --- | --- | --- |
| P0-A | 长限流隔离与自动刷新持续性 | 需要加强 | 重试等待保留全局运行槽，整轮刷新完成后才开始下一次定时等待；长冷却会牵连独立账户 |
| P0-B | 启动存储故障与恢复入口 | 需要加强；备份恢复未实现 | 打开失败退回内存 repository，启动错误可能被自动刷新清除；缺少明确恢复流程 |
| P1-A | 同步协调失败保护与响应性能 | 需要加强 | 文件协调失败存在直接操作回退；同步读写和本地全量提交在 MainActor 路径，卡顿程度待量测 |
| P1-B | 历史覆盖说明与按需补取 | 部分已实现；补取入口未实现 | 仅建账时回填 7 天，日常刷新不修复离线缺日或此前回填失败 |
| P1-C | 实际应用包验收与诊断 | 已实现但验证不完整；诊断导出未实现 | 已有离线/GUI 编译检查，真实窗口、系统集成与当前发布结果需单独取证 |
| P1-D | 文档事实与产品边界整理 | 需要加强／NEEDS_CONFIRMATION | 历史方案和现状混排；网关远端控制与“只读监控”的文档边界不一致 |

范围外：本轮不改业务代码、测试、CI 配置或 REQUIREMENT；不重画已确认 UI，不新增服务端/数据库/依赖，不改变不使用 Keychain、Developer ID、公证的选择，不恢复已跳过的双 Mac 验收要求。

### 18.2 P0-A：等待限流的账户不能拖住其他账户

**现状入口**：`RefreshCoordinator.execute` 在重试循环内等待 `Retry-After`；`RefreshScheduler.pump` 将有 task 的 job 全部计入全局并发；`RelayStore.startAutomaticRefresh` 等待 `refreshAll` 完成后再 sleep；整轮后的 repository reload 才触发同步与低余额通知。

具体场景：A 收到 1 小时冷却，B 首轮虽然能成功，但下一轮自动刷新仍等 A；若三个不同原点都进入长退避，第四个健康原点的首次任务也排队。第 17.3 节已记录保留槽位的取舍，此处建议将“保持原点冷却”和“占用全局执行名额”分开。静态路径可确定上述等待依赖，实际耗时影响未运行复现。

**拟改方案**：复用现有 scheduler，将一次请求尝试结束后的 job 转为带 `notBefore` 的等待状态，保留订阅者、重试计数和原点冷却，释放全局执行名额；到期重新排队。实际网络任务未结束、尤其非协作取消任务仍占槽，不能提前释放。同账户去重、手动优先和提交前配置校验保持。

自动刷新按到期账户投递，由调度器合并重复请求，单次整轮等待不再阻断下一个周期；不允许每个周期新增无限等待者。成功提交后的本地展示、通知评估和合并后的同步请求分别触发，不依赖所有账户终结。通知沿用账户/自然日去重，发送前复核账户启用、可见性、最新余额及授权状态。睡眠唤醒只对到期账户补一次请求，不重放睡眠期间全部周期；继续服从冷却。

**验收**：可控时钟下 A 冷却 1 小时，B 在随后两个配置周期均刷新；三个原点等待退避时第四个健康原点可执行；同原点始终不提前请求；反复手动/定时/唤醒不重复网络操作或累计用量；删除、编辑、最后订阅者取消及非协作任务的旧结果继续被拒绝。成功账户的通知不被另一账户冷却无限拖延。

### 18.3 P0-B：持久的存储故障状态，随后补恢复能力

**现状入口**：`FileLocalRepository.init` 将未知高版本和解码失败归入 `corruptData`；`main.swift` 捕获后调用 `RelayStore.unavailable`，后者使用可写的内存 repository 且默认启动自动刷新。`refreshAll` 会清空 `globalErrorMessage`，可能让启动故障显示成普通空账户；此问题不等于磁盘原文件已被覆盖。

**第一步拟改**：建立独立于临时刷新错误的存储状态，至少区分可用、无权限/不可读、内容损坏、版本不支持。故障态暂停自动刷新和同步，禁止会显示保存成功的账户/设置写入；首页持续说明“本地数据未能载入”，不走首次使用引导。提供重新读取入口；重新打开并完整加载成功后再恢复业务。未知新版本保留原文件，提示使用兼容版本，不按损坏数据重建。

**第二步候选**：在 `FileLocalRepository` 内复用 `PrivateFileWriter` 保存有限数量、已验证可解码的非秘密本地备份；恢复前预览日期和账户/历史数量，保留当前原文件，用户确认后原子替换。备份不包含凭据，也不是 iCloud 同步的替代品。恢复成功前不自动同步；旧备份中的账户和 tombstone 必须经过既有冲突规则，不能静默复活已删除账户。凭据不恢复，按当前本机凭据实际存在性提示补录。

备份保存失败的规则应明确：保护副本未成功时拒绝本次需要保护的写入，保留原文件并报告存储错误；主文件提交成功后，不把备份清理等后续失败伪装成主提交失败。保留代数和用户入口尚未确定，见 18.8。

**验收**：截断 JSON、目录无权限、未知 schema、磁盘写入失败分别给出正确状态；自动刷新和点击刷新均不清除启动故障；失败恢复不改变原文件和现有内存投影；成功恢复后重启一致；备份及恢复流程不读取或复制凭据文件。

### 18.4 P1-A：同步安全边界与主线程工作量

**现状入口**：`FileSyncService.exchange/resolve` 在协调器报错且 accessor 未执行时直接操作文件，代码没有将该回退严格限定为测试普通目录。`exchange`、协调读写、解码合并和 `LocalRepository.commit` 均位于 MainActor 调用路径。已有历史读取索引不能消除全量编码、文件同步等待的成本。

**优先拟改**：生产同步协调失败时保持失败/不可用状态并保留候选，不绕过协调直接写；测试通过注入协调执行方式覆盖普通目录 fixture，不让测试兼容回退成为生产行为。冲突决策还需验证“本地已合并、云端写回失败”后的状态和幂等重试，不能将部分完成显示为同步成功。

**性能方案**：先记录同步协调等待、编解码、提交及界面响应耗时，分别测 1/10/50 账户及既有 5 MB 合成历史样本。若主线程阻塞达到第 16.7 节调查阈值，再将协调与文件工作放入串行后台执行器；MainActor 仅提取不可变非秘密快照和应用校验后的结果。后台期间本地发生编辑/删除时，通过进程内修订号拒绝旧结果、重新合并；同一同步任务在途合并触发，禁止用 detached task 直接共享现有 MainActor repository。数据 schema 暂不改变。

**验收**：注入协调失败时无绕过写入；慢文件协调期间仍能打开菜单、查看缓存和关闭面板；云端写回失败后本地可用且状态诚实；并发编辑/删除不被后台旧快照覆盖。耗时改进必须有量测记录，不能由“使用 async”推定。双 Mac 仍未验证，不设为本轮出口。

### 18.5 P1-B：解释历史覆盖，再考虑补取

**现状入口**：`AccountService.addAccount` 可选回填 7 天，失败回退为空历史；`RefreshCoordinator.performRefresh` 明确仅保存当日，不重复回填。现有 adapter 已有 `fetchDailyUsage`，可复用能力，无需创建第二套供应商访问层。

先在现有详情趋势说明位置显示已知日期覆盖范围及缺日，明确“未采集/查询失败/不支持”不能变成 0。按需补取作为候选：仅对供应商实际支持、用户明确选择的日期范围请求，服从既有原点冷却和取消规则；当天仍以快照口径为准。历史批次以 repository 原子批量提交，避免逐日重写全文件；重复补取不重复累计，失败保留旧值。

workbuddy2api 仅有进程累计量，当前把增量归入获取当日；跨日离线或网关期间重启不能从累计值还原准确每日消费。应标注“观测增量”，不套用可查询历史供应商的补取承诺，也不倒推出精确账单。显示口径和补取范围需确认后细化。

**验收**：首次回填失败后能解释缺日；离线数日重开不展示虚构完整趋势；补取取消、重复提交、跨时区和部分缺失均保留正确原生金额；DeepSeek 沿用 GMT+8 日期规则。

### 18.6 P1-C：发布验收和可分享诊断

优先用实际应用包验证已有能力：窗口隐藏/恢复和返回首页、登录项、全局快捷键、通知、睡眠唤醒、键盘及 VoiceOver、浅色/深色与减少透明度。已有 `.github/workflows/build.yml` 包含离线检查、GUI 只编译、打包与两次 checksum 复算；本轮没有查询该提交的远端 run，不宣称发布成功。

下一次交付记录应关联 commit、CI run、版本和实际下载资产；完成下载校验及手动替换安装后的启动、账户和历史保留检查。继续按 ad-hoc 与手动安装路线，不把 SHA-256 当作开发者身份认证。

可选增加用户主动生成的诊断预览与导出：版本/构建、系统版本、错误分类、任务数量、耗时、存储大小和同步阶段。复用 `AccountHealth`、`RepositoryPerformanceDiagnostics`；采用字段白名单，默认不含账户名、UUID、站点 URL、路径、原始错误文本、响应体或凭据，无后台上传。导出前可查看内容，失败时保留当前页面；用含伪造秘密的 fixture 验证导出不携带这些内容。

### 18.7 其他产品方向与文档建议

- 配置导入/导出：REQUIREMENT 已列为 P2。仅非秘密配置，导入前预览新增/冲突/缺凭据，复用同步安全投影与稳定账户 ID；不直接复制整个应用目录。
- 月度预算提醒：可选新需求，优先基于可信完整消费及现有通知去重；部分历史不可显示精确超支/预计耗尽日期。阈值、币种、提醒频率需先定需求。
- 更多站点：优先确认用户实际使用的站点与管理 API；OpenAI 兼容模型调用地址不能证明余额/账单接口兼容。继续走现有 adapter，不预设通用适配器可直接支持所有站点。
- 维护文档：建议后续单独整理 AI_CONTEXT 的当前模块列表、调度/健康、下载完整性和设置分页事实；将旧环境失败与后续成功记录标明时序。DESIGN 早期类型草案与实际协议、REQUIREMENT 早期“仍未完成”与后续完成记录应建立明确取代关系。本轮只加阅读指引和本节，不改写长期上下文或需求。

### 18.8 NEEDS_CONFIRMATION 与下一阶段入口

| 事项 | 原因与影响 | 需要决定的内容 |
| --- | --- | --- |
| 网关远端管理边界 | REQUIREMENT 核心原则写“只读监控”，但 `WorkBuddy2APIAdapter.performSubAccountAction` 已发送启停 POST，UI 已有对应操作；实现存在不等于需求已确认 | 是否把 workbuddy2api 的有限启停管理正式列为例外；确认前不扩展或删除这些操作 |
| 备份恢复产品策略 | 新增本地副本占用空间，恢复可能带回旧设置/账户并影响后续同步 | 是否纳入下一轮，以及保留代数、恢复确认和恢复后同步入口 |
| 历史补取与网关统计说明 | 历史能力因供应商而异；网关累计量不能可靠拆回离线各日 | 补取 7/30 日范围和触发方式；是否采用“观测增量”说明 |
| 可选产品扩展 | 导入导出、预算、诊断导出、更多供应商并非本轮已选需求 | 根据实际使用频率选择，不一次全部加入 |

建议下一阶段先处理 P0-A 与 P0-B 的故障状态保护，再做 P1-A 的协调失败保护和性能量测；备份恢复与历史补取在产品选择确认后实施。独立验证任务可补齐真实应用包验收。每个实现阶段先补故障复现，再运行现有 `scripts/test-regressions.sh`、`scripts/test-contracts.sh` 和已核实构建命令；GUI 只编译、实际 GUI、真实供应商、远端发布和双 Mac 分别报告。

本轮增量评估完成，存在上述未决事项，不能称所有扩展方案均已就绪；停留在设计阶段。
