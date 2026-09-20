# Relay / 驿站 · 技术设计

**版本**：v1.3-draft
**日期**：2026-09-18
**阶段**：Architecture

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

`quota_per_unit` 来自站点状态；缺失或非法时标记金额不可换算，而不是静默使用错误值。可配置的兜底值只用于明确为兼容 New API 的站点，并在 UI 标出来源。

#### DeepSeekAdapter

- P0 不实现，P1 仅接入 DeepSeek 官方余额接口。
- 用户必须主动提供 DeepSeek 官方 API Key；Relay 使用该 Key 调用官方账户余额端点。
- 不读取浏览器 Cookie，不要求网页 userToken，不复制登录会话，也不调用仅供 DeepSeek 网站内部使用的私有接口。
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

不保存：系统令牌、Pipio 用户 ID、API Key、Cookie、网页 userToken、完整原始日志响应。

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
- 仅当所有参与金额都有同源或明确可比较的未过期换算信息时才允许汇总。

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

只解析官方返回的可用状态、币种和余额字段。DeepSeek 官方 API Key 存本机 Relay 凭据文件；不接受浏览器 Cookie、网页 userToken 或网站内部接口凭据。

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
| DeepSeek 官方接口指标有限 | 无法提供网页上的全部用量维度 | 只展示官方接口数据，不复制浏览器会话 |
| iCloud 云盘是文件同步而非数据库 | 多设备并发可能产生冲突副本 | NSFileCoordinator、版本字段、确定性合并和冲突提示 |
| 首期为未公证、非沙盒的 GitHub 构建 | Gatekeeper 警告且应用权限边界弱于沙盒应用 | 发布校验和、公开源码/构建流程、最小文件访问、安装风险提示；优先使用系统“仍要打开”，不把移除 quarantine 冒充认证；未来取得 Developer ID 后签名公证并评估沙盒 |
| 多币种汇总 | 过期或缺失汇率导致总额误导 | 使用 Pipio 发布值、默认 7 天刷新、过期标记；无法可靠换算时不汇总 |

## 13. NEEDS_CONFIRMATION

`NONE`：当前 Architecture 阶段无待确认项。

已确认：Bundle ID 为 `cloud.dinghao.relay`；GitHub Releases 发布；不使用 CloudKit Container；同步使用 `iCloud Drive/文稿/Relay` 普通文件；凭据不通过任何 iCloud 机制同步；凭据存放在本机私有应用数据目录而不是 Keychain；DeepSeek 仅使用官方接口；汇率默认每 7 天刷新；历史默认 1 年并可选永久；低余额默认 20；今日数据不完整时隐藏该字段。

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

### D-009 DeepSeek 用量能力降级

DeepSeek 适配器只使用官方余额接口；历史/分模型账户用量在无官方端点时返回 `unsupported + nil`，不调用私有网页接口。UI 只展示实际支持的字段，不把未知能力转换为 0。

### D-010 iCloud 冲突状态机

`FileSyncService` 在发现多个远端候选或 unresolved conflict versions 时生成不可变 `SyncConflictReport`，并暂停本次自动合并写回。`RelayStore.resolveSyncConflict` 通过 `FileSyncService.resolve` 应用用户明确选择的 resolution；候选文件保留，不由 resolution 自动删除。同步目录不可用时使用 `unavailable` 状态，同时保持本机 repository 可用。

### D-011 验证边界

确定性同步脚本的退出码 2 表示无 fixture 失败但缺少真实第二台 Mac；此结果是环境阻塞而非通过。当前命令行工具链的 SDK/compiler mismatch 使 `swift build` 无法完成，交付报告必须单独列出该阻塞。
