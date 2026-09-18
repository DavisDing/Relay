# Relay / 驿站 · 技术设计

**版本**：v1.0-draft
**日期**：2026-09-18
**阶段**：Architecture

## 1. 技术栈

| 层 | 方案 | 原因 |
|---|---|---|
| UI | SwiftUI + 少量 AppKit | SwiftUI 实现页面；AppKit 负责状态栏、窗口层级和必要的 macOS 生命周期控制 |
| 语言 | Swift（macOS 27 SDK） | 原生平台能力、Keychain、CloudKit、菜单栏和 Liquid Glass 支持最好 |
| 并发/网络 | Swift Concurrency + URLSession | 不引入第三方网络框架；便于账户级隔离、取消和限流 |
| 图表 | Swift Charts | 7/30 日趋势，无需第三方图表库 |
| 本地数据 | SwiftData（首选） | 项目目前无既有代码；日聚合数据规模小，原生且足够简单 |
| 云同步 | CloudKit 私有数据库 | 满足同 Apple ID 多 Mac 同步；通过独立 SyncService 隔离 |
| 凭据 | Security.framework Keychain | 普通持久化层只保存 credential reference |
| 启动项 | ServiceManagement | 原生登录项管理 |

项目当前只有文档，没有可复用业务代码或既有技术栈。若 SwiftData 与实际 CloudKit schema/迁移要求冲突，再评估 Core Data；首期不同时维护两套本地数据库。

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
          ├── CredentialStore ── macOS Keychain
          ├── LocalRepository ── SwiftData
          └── SyncService ── CloudKit Private Database
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

职责：组合本地快照，计算可展示的总余额、今日已知消费、账户状态和趋势。

规则：

- 只汇总币种一致或已有有效换算结果的金额。
- `knownTotal` 与 `isComplete` 同时返回，避免把部分数据误认为全量。
- UI 首屏直接读本地缓存；刷新异步发生。

### 3.3 AccountService

职责：账户增删改、启用禁用、验证、Keychain 引用维护、删除数据和 tombstone。

添加 Pipio 账户流程：

1. 规范化站点 URL，拆分 origin、management base、model base。
2. 请求 `GET {origin}/api/status`。
3. 校验令牌非空、`pipioUserId` 为正整数。
4. 请求 `GET {origin}/api/user/self`。
5. 请求统计接口并生成 `ProviderCapabilities`。
6. 先写 Keychain，成功后写账户元数据；任一步失败则回滚本次新建数据。
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

- P0 不实现，P1 接入。
- 官方 API Key 只承担官方明确支持的数据。
- 网页 userToken 私有接口必须单独开能力开关；解析失败不能影响余额能力。
- 具体私有接口路径目前为 `UNKNOWN`，不得先写死。

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

- Keychain service：`com.relay.credentials`（最终 Bundle ID 未确认）。
- account key：稳定的本地 `accountId`，不把站点令牌或邮箱拼进 key。
- Keychain value：版本化的 credential payload。
- 默认 `kSecAttrSynchronizable = false`；若用户明确启用凭据同步，再迁移为可同步条目。
- 只向业务层返回短生命周期值，不进入可观察 UI state。

### 3.7 LocalRepository

职责：保存账户元数据、最近快照、日聚合、模型聚合、偏好和同步状态。

不保存：令牌、API Key、Cookie、网页 userToken、完整原始日志响应。

### 3.8 SyncService

- CloudKit 私有数据库。
- 同步账户元数据、日聚合、用户主动设置和 tombstone。
- 不同步瞬时 UI 状态、刷新中的任务、错误堆栈。
- 同步失败不阻塞本地写入。
- 账户与凭据解耦：其他设备收到元数据但缺少凭据时显示“需要在此设备补充凭据”。

## 4. 层职责

### UI 层

- 展示本地状态、收集输入、基础格式校验。
- 不直接拼 API URL，不持有长期凭据，不解释供应商 JSON。
- 完整处理 Loading、Empty、Refreshing、Partial、Stale、Error、Success。

### 业务层

- 账户验证、能力探测、金额/时间规范化、汇总、刷新调度、错误分类。
- 所有安全校验必须在业务层再次执行。

### 数据层

- Keychain 管秘密。
- SwiftData 管本地业务数据。
- CloudKit 管可同步的非秘密数据。

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
Account metadata + Keychain credential
  → PipioAdapter 构造 management request
  → /api/user/self + /api/log/self/stat
  → DTO 校验与单位换算
  → ProviderSnapshot / DailyUsage
  → LocalRepository 原子写入
  → Dashboard 重算
  → SyncService 异步提交可同步记录
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

响应结构尚未实测：`NEEDS_CONFIRMATION`。实现时只读取明确验证过的余额、累计消耗、请求数和身份字段。

#### PIPIO-003 聚合统计

```http
GET {origin}/api/log/self/stat?start_timestamp=<seconds>&end_timestamp=<seconds>&model_name=<optional>
Authorization: Bearer <system-token>
Pipio-User: <numeric-user-id>
```

时间戳单位、字段名、模型分组结构尚未实测：`NEEDS_CONFIRMATION`。

#### PIPIO-004 日志列表

```http
GET {origin}/api/log/self?...pagination...
Authorization: Bearer <system-token>
Pipio-User: <numeric-user-id>
```

仅在聚合接口无法提供必要字段时使用。缓存命中率字段尚未确认；首期不应为了计算一个指标而无限拉取原始日志。

## 7. 数据设计

### DATABASE

本地数据库：`REQUIRED`（SwiftData）。
服务器数据库：`NOT_REQUIRED`。

### Account

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID | 本地主键/跨设备稳定标识 |
| providerKind | enum | pipio/deepSeek |
| displayName | String | 用户可编辑 |
| siteOrigin | URL/String | 规范化 origin，不含令牌 |
| externalUserId | String? | Pipio 数值用户 ID；可同步 |
| credentialRef | String | Keychain 引用，不是秘密值 |
| enabled | Bool | 是否刷新和汇总 |
| lowBalanceThreshold | Decimal? | 账户级阈值 |
| sortOrder | Int | 默认手动顺序 |
| createdAt/updatedAt | Date | UTC |
| deletedAt | Date? | tombstone |

索引：`id` 唯一；`providerKind + siteOrigin + externalUserId` 业务去重。

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

刷新间隔、状态栏显示项、外观、默认页面、低余额默认值、历史保留期、CloudKit 开关。

### CloudKit Record

- `RelayAccount`
- `RelayDailyUsage`
- `RelayModelDailyUsage`
- `RelayPreference`
- `RelayTombstone`

凭据不进入上述 Record。CloudKit container identifier、entitlement 和生产 schema：`UNKNOWN`。

## 8. 前端设计

### 8.1 菜单栏折叠态

元素：模板图标、可选金额、完整性/异常提示。
状态：无账户、正常、部分未知、刷新中、过期、认证失败。

### 8.2 首页面板

- 顶部：总余额、今日已知消费、完整性说明、账户数、最近刷新。
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

令牌字段默认隐藏，仅提供覆盖更新，不回显现有值。

### 8.4 账户详情

- 概览指标。
- 能力支持时显示用量和分模型数据。
- 7/30 日切换。
- 显示数据更新时间和来源状态。
- 编辑/禁用/删除放在更多菜单；删除二次确认。

### 8.5 设置

- 账户
- 刷新与低余额
- 状态栏与外观
- 登录项/快捷键
- iCloud 同步
- 高级（缓存、数据保留、诊断信息）

诊断导出必须脱敏，不包含凭据和原始认证响应。

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
| JSON 字段变化 | responseIncompatible | 当前账户标记部分失败，保存脱敏诊断 |
| 指标缺失 | unsupported/unknown | 隐藏或标注未知，不显示 0 |
| CloudKit 不可用 | syncUnavailable | 本地照常工作 |
| Keychain 读取失败 | credentialUnavailable | 提示重新授权/录入 |

## 10. 安全设计

- 代码、测试夹具和文档均不得包含真实令牌。
- 网络日志通过统一 `RedactingLogger`，过滤 Authorization、Cookie、Token、userToken 和查询中的敏感项。
- UI state 不存明文 credential；验证表单离开后清空。
- 不枚举 `Pipio-User`，不尝试访问不属于用户的账户。
- 站点 URL 只允许 HTTPS；重定向到不同 origin 时默认拒绝携带认证头。
- CloudKit/SwiftData migration 和诊断导出需检查秘密字段永不进入序列化模型。

## 11. 测试关注点

### 单元测试

- `/v1` 输入到 origin/management/model 三种 URL 的规范化。
- Decimal 配额换算和缺失 `quota_per_unit`。
- 未知/null/0 的区分。
- 今日边界、时区和夏令时。
- 能力矩阵与 UI 字段可见性。
- 退避、429 Retry-After、401 不重试。
- 汇总完整性与多币种拒绝直接求和。

### 集成测试

- MockURLProtocol 覆盖 status/self/stat/log 的 2xx、401、403、429、5xx、超时和畸形 JSON。
- Keychain 新增、覆盖、删除、不可用和迁移。
- 单账户失败不影响其他账户。
- 删除账户时本地数据、Keychain 与 tombstone 一致。
- CloudKit 离线、冲突和恢复同步。

### UI 测试

- 空状态、部分数据、过期数据、认证失效、刷新中。
- 菜单栏金额过长和无金额。
- 面板最大高度、键盘操作、VoiceOver、增强对比度、减少透明度。
- 删除和关闭云同步的二次确认。

### 实机验证

- 菜单栏面板焦点/失焦关闭行为。
- 登录项、睡眠唤醒、网络切换。
- Liquid Glass 性能和文字可读性。

## 12. 重要风险

| 风险 | 影响 | 处理 |
|---|---|---|
| Pipio 管理接口非稳定公开合约 | 字段/路径变化导致统计失败 | 适配器隔离、容错 DTO、能力降级、契约测试 |
| 当前令牌类型不明确且 `/v1/models` 验证失败 | 无法判断它能否用于管理 API | 要求提供数值用户 ID并确认令牌类型；不混用模型 Key |
| DeepSeek 私有 userToken 接口不稳定 | 用量能力随时失效 | 与官方余额能力解耦，首期可不做 |
| CloudKit + Keychain 跨设备语义复杂 | 设备上有账户但无凭据 | 元数据与凭据分离，明确“本机补充凭据”状态 |
| 多币种汇总 | 总余额误导 | 未确认汇率前不跨币种直接求和 |

## 13. NEEDS_CONFIRMATION

1. 提供属于该令牌账户的 Pipio 数值用户 ID，才能继续验证真实账户和统计 JSON。
2. 确认令牌类型；当前实测不能作为 `/v1/models` 的模型 API Key。
3. CloudKit 是否 P0；建议 P0 先完成本地闭环，P1 启用同步。
4. 是否同步 Keychain 凭据；建议默认每台设备单独录入。
5. Bundle ID、CloudKit container ID、签名团队和发布方式。
6. DeepSeek 私有用量是否接受实验性支持。
7. 是否存在多币种账户及认可的汇率来源。

## 14. 设计决策

### D-001 原生单体应用

**决定**：SwiftUI/AppKit 单体，无 Relay 后端。
**原因**：需求只需要本机读取供应商 API 和 iCloud 私有同步，自建服务增加隐私与维护成本。
**日期**：2026-09-18。

### D-002 供应商适配器 + 统一领域模型

**决定**：每个供应商独立 Adapter，UI 只读取统一快照与能力。
**原因**：第三方接口字段和能力差异大，需支持降级且避免供应商逻辑渗入 UI。
**日期**：2026-09-18。

### D-003 凭据与同步数据分离

**决定**：凭据只存 Keychain；本地数据库和 CloudKit 只存引用与非秘密数据。
**原因**：降低泄露面并允许用户选择是否启用 iCloud Keychain 同步。
**日期**：2026-09-18。

### D-004 Pipio 双基址

**决定**：模型 API `/v1` 与管理 API `/api` 分开建模。
**原因**：2026-09-18 实测 `/v1/api/...` 为 404，而 `/api/status` 可用。
**日期**：2026-09-18。
