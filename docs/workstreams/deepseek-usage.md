# DeepSeek 历史 / 模型用量能力探测

**状态：unsupported（已实现安全降级）**  
**验证日期：2026-09-20**

## 范围

本工作流只探测 DeepSeek 官方 API 是否能提供账户级历史用量和分模型用量，不读取浏览器 Cookie、网页 `userToken`、Dashboard 私有接口或其他未公开接口。

## 官方能力结论

DeepSeek 官方 API 文档当前公开的账户余额接口是 `GET /user/balance`。该接口返回账户余额可用性以及余额构成，不返回账户历史账单、按日期用量或按模型聚合用量。官方文档同时说明，单次模型生成响应会带有该次请求的 `usage`，但 Relay 本身不发起用户模型请求，也没有可用的官方历史查询接口可以回放这些请求。

因此本实现不会猜测 `/usage`、`/billing`、Dashboard 或私有网页接口，也不会把缺失数据转换成 0。

## 契约

### 查询输入

```swift
DeepSeekUsageQuery(
    accountID: UUID,
    siteOrigin: URL,
    startAt: Date,
    endAt: Date,
    calendar: Calendar
)
```

约束：

- `credential.secret` 必须非空。
- `siteOrigin` 必须是 HTTPS。
- `startAt <= endAt`。
- 凭据只用于输入校验；不会写入报告、日志或同步数据。

### 输出

```swift
DeepSeekUsageReport(
    accountID: UUID,
    coverage: .unsupported,
    daily: nil,
    models: nil,
    unavailableReason: .officialAPIHasNoHistoricalOrModelUsageEndpoint,
    fetchedAt: Date
)
```

语义：

- `coverage == .unsupported`：官方 API 没有本能力，不能推导出“真实为 0”。
- `daily == nil`：没有历史日用量数据。
- `models == nil`：没有分模型用量数据。
- `fetchedAt` 只表示本次能力探测生成报告的时间，不是供应商用量数据时间。

### 适配器契约

`DeepSeekAdapter.fetchUsage(for:credential:startAt:endAt:calendar:)` 复用适配器已经注入的 `HTTPClient`，但在当前官方能力下不发起额外请求，直接返回上述 unsupported 报告。余额流程仍只调用既有的 `GET /user/balance` 路径。

## 安全边界

- 只允许通过 `DeepSeekAdapter` 的现有 HTTPS 站点原点访问官方 API。
- 不读取 Safari/Chrome Cookie。
- 不读取或保存网页 `userToken`。
- 不调用 DeepSeek 网页端私有接口。
- 不记录 Authorization、API Key 或完整响应。

## UI 行为

`DeepSeekUsageSection` 对 `unsupported` 显示“DeepSeek 官方 API 暂未提供历史或分模型账户用量”，不显示空图表、不显示 0、不伪造成功数据。

## 离线测试策略

服务构造函数接受 `HTTPClient`。本轮 unsupported 探测不会访问网络，因此契约测试使用 stub client 验证：

1. 合法查询返回 `.unsupported`，`daily` 和 `models` 都是 `nil`。
2. 未知/猜测接口不会被请求。
3. 空凭据、非 HTTPS 原点、逆序时间范围会被拒绝。
4. `DeepSeekAdapter` 的既有余额请求仍为 `GET /user/balance`，并携带 Bearer Authorization；费率查询不额外请求余额。

## 已知限制

- 本轮没有把单次生成响应中的 `usage` 接入历史聚合，因为 Relay 不代理用户模型请求，且需求要求只使用官方接口。
- 若未来 DeepSeek 发布正式的历史或模型用量接口，只应在 `DeepSeekUsageService` 中增加官方 DTO、响应验证和契约测试；不得改变 `nil`/unsupported 语义为默认 0。
