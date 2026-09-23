# DeepSeek 历史 / 模型用量

**状态：已接入可选平台 userToken**
**验证日期：2026-09-23**

## 范围

Relay 将余额和平台历史用量分为两个认证边界：

- **API Key**：只用于官方公开余额接口 `GET https://api.deepseek.com/user/balance`。
- **平台 userToken**：可选，由用户手动录入，仅用于 `platform.deepseek.com` 的网页内部用量接口。Relay 不读取浏览器 Cookie，不自动获取网页登录状态。

平台接口不是 DeepSeek 面向开发者公开承诺的稳定 API，响应结构或认证方式变化时必须安全降级。

## 接口契约

### 余额

```http
GET https://api.deepseek.com/user/balance
Authorization: Bearer <API Key>
```

### 历史用量

```http
GET https://platform.deepseek.com/api/v0/usage/amount?month=<M>&year=<Y>
GET https://platform.deepseek.com/api/v0/usage/cost?month=<M>&year=<Y>
Authorization: Bearer <userToken>
Referer: https://platform.deepseek.com/usage
```

`amount` 通常返回对象形式的 `data.biz_data`，`cost` 通常返回货币分组数组；Relay 同时容错 `total`/`days` 的数组或单对象形式，并按日期、模型聚合 token、请求次数和消费。

## 产品行为

- 添加账户时 userToken 可选。未填写只查询余额；填写后余额和平台历史用量都查询。
- 首次添加填写 userToken 时回填最近 7 天；当天以当前快照为准，历史回填不得覆盖当天。
- 平台用量认证失败、接口异常或响应变更时，余额仍可用，快照标记 `partial`。
- userToken 只存本机凭据文件，不进入 `RelaySyncData`、日志或 UI 报告。
- 未知指标保持 `nil`，不以 0 代替。

## 已知限制

- `platform.deepseek.com` 接口是网站内部接口，可能在无通知的情况下变更。
- DeepSeek 用量历史的月份边界、`days` 日桶、今日消费和首次 7 天回填统一按固定 GMT+8（北京时间）解释与保存，不使用 Mac 本地时区。平台日桶仍是平台返回的日期标签；当前实现不额外引入 `usage/export` 的 ZIP/CSV 严格窗口。
