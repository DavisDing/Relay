# Relay 技术设计

**版本**：v2.0
**状态**：当前实现设计
**最近整理**：2026-10-11

需求与验收见 [REQUIREMENT](REQUIREMENT.md)，长期事实和构建命令见 [AI_CONTEXT](AI_CONTEXT.md)；原始凭据方案见 [SECURITY_DESIGN](SECURITY_DESIGN.md)；该旧记录的删除顺序不代表现状，账户生命周期以本文和 REQUIREMENT 为准。

本文描述当前代码的职责边界、数据流、持久化、界面入口、异常语义和验证边界。未实现的方案必须标记 `PROPOSED`，未经过目标环境操作的内容标记 `NOT_EXECUTED`。

## 1. 设计约束

- 使用 SwiftUI + AppKit 的 macOS 菜单栏单体应用；不新增远程后端、数据库或第三方依赖。
- 本地优先；业务数据、同步数据和凭据数据分离。
- 已保存凭据仅由 `FileCredentialStore` 读取；UI 可持有用户正在录入的临时草稿，不回显旧值，同步、导出和备份不接触凭据正文。
- 账户失败隔离，刷新和写入采用原子提交；未知值不能被转成零。
- 复用现有页面和原生材质，不通过结构重做解决局部状态问题。

## 2. 模块职责

### UI

`Sources/Relay/UI` 负责输入、展示和页面状态：

- `MainPopoverView`：总览、搜索、分组、置顶排序和账户入口。
- `AccountAddModalView` / `AccountEditModalView`：账户字段、预算、分组、置顶和凭据编辑。
- `AccountDetailContainerView` / `AccountDetailView`：账户实时投影、固定近 7 日趋势、按日模型明细及明确口径的网关累计模型。
- `SettingsDataPage`：刷新、历史保留、月预算通知。
- `SettingsSyncPage` + `DataTransferPanel`：iCloud 普通文件同步、备份摘要/恢复、配置迁移；备份列表与 CSV 筛选使用折叠区，错误和搬移待处理状态不折叠。
- `SettingsShortcutsPage` + `SettingsBackupDirectoryPanel`：全局快捷键、通知权限/测试、登录项、iCloud 与备份目录选择/重新授权；复用原文件同步/备份服务。
- `SettingsPageLayout`：统一 12pt 正文、10pt 说明、紧凑分组、右侧 mini 开关及右对齐 28pt 胶囊操作行。设置内快捷键、导入/恢复及诊断 sheet 沿用同一控件体系。
- `RelayMenuBarController`：菜单栏状态、Popover 和辅助窗口导航。

UI 不拼供应商 URL、不解码供应商 JSON、不持有长期凭据。关闭辅助页返回首页；外部隐藏保留页面状态。

### 业务服务

- `AccountService`：账户验证、凭据事务、首个快照和元数据保存。
- `ProviderAdapter`：供应商 URL、凭据请求、快照、历史和能力适配。
- `RefreshScheduler`：账户请求去重、全局并发、同源串行、手动优先和取消。
- `RefreshCoordinator`：执行单次请求、退避、能力补充、历史批量提交和刷新原子事务。
- `DashboardAggregator`：基于可比较金额和数据完整性生成总览，不将未知视为零。
- `AccountOrganizationService`：搜索、分组筛选、置顶和稳定排序的纯投影；`manualOrder` 按 sortOrder/createdAt/UUID 稳定排列设置列表。`RelayStore.reorderAccounts` 校验完整且唯一的父账户 ID 集合，一次 CAS 保存连续 sortOrder，仅为发生排名变化的账户推进 updatedAt；失败不发布新顺序，首页置顶与服务商分组语义不变。
- `BudgetService`：月预算币种、月份、80/100% 阈值和本机去重状态。
- `ModelAnalysisService`：模型消费、Token、占比、单位成本和未知原因。
- `AccountHealth`：运行期健康摘要，不持久化秘密。
- `UpdateService`：GitHub Release 检查、精确版本/资产绑定、暂存下载和 SHA-256 验证。
- `GlobalShortcutService` / `LaunchAtLoginService`：快捷键事务注册和系统登录项调用，失败报告真实系统错误。

### 持久化与文件服务

- `FileLocalRepository`：`relay-local-v1.json`，版本化 JSON、原子替换、权限校正和恢复前内容比较与交换（compare-and-swap）。
- `RecoverableLocalRepository`：启动读取失败时保持故障态，不创建可写空库；支持重试打开与明确确认的损坏库备份恢复。
- `FileSyncService` / `SyncFileWorker`：iCloud Drive 普通文件、`NSFileCoordinator`、后台准备、冲突合并和最多三次 compare-and-swap 重试。
- `LocalBackupService`：本机备份创建、列表、预览、security-scoped bookmark 和目录迁移；数据恢复事务由 `RelayStore` 执行。
- `FileCredentialStore`：本机私有凭据文件，独立于其他持久化模型。

## 3. 领域模型和版本

- `AccountConfiguration` 持久化账户 ID、供应商、站点、启用/隐藏、低余额阈值、手动汇率、月预算、分组、置顶、排序和时间。
- `ProviderSnapshot` 持久化余额、今日/月消费、请求量、模型使用、能力、数据新鲜度、账户汇率和 workbuddy2api 子账户。
- `DailyUsageRecord` 保存账户级日消费及可选 `modelUsages`。新增字段向后兼容，旧记录解码为 nil（未知），空数组表示已知无模型；日模型随原日记录原子持久化、同步和备份，不修改 CSV 口径。
- `RelaySettings` 当前 schema 1，包含刷新间隔、菜单栏今日消费、基础币种、默认低余额阈值、历史保留和同步开关。
- `RelaySyncData` 当前 schema 1；本地 JSON 另有 schema 2 兼容检查。配置导出使用独立的 `RelayConfigurationArchive`。
- `ProviderCredential` schema 为 2，独立保存本机秘密，不作为同步模型。便携 UUID 引用不是凭据正文；合并不能覆盖已保存的本机引用。
- `RepositoryPerformanceDiagnostics` 与同步耗时只供运行期使用；本地历史按账户建立读取索引，写入仍全量 JSON 原子替换。
- 新增可选字段必须兼容旧 JSON；删除或改变含义必须先增加 schema 迁移和回归夹具。

### 文件边界

| 文件/位置 | 当前格式与版本 | 内容/授权边界 |
|---|---|---|
| `~/Library/Application Support/cloud.dinghao.relay/relay-local-v1.json` | 本地 schema 2 | 账户、快照、日历史、设置和 tombstone，不含凭据 |
| 同目录 `relay-credentials-v1.json` | 凭据 schema 2 | 仅本机秘密，禁止复制到同步/备份 |
| 用户选定同步目录 `relay-sync-v1.json` | RelaySyncData schema 1 | 非秘密投影，credentialReference 重写为便携 UUID，同步开关关闭 |
| 配置导出 JSON | `relay-configuration` schema 1 | 仅账户配置和 RelaySettings，不含历史/凭据/授权 |
| 默认 `Application Support/Relay/Backups` 或所选父目录 `RelayBackups` | RelaySyncData schema 1 | 非秘密备份，创建/恢复前备份使用同一服务 |
| UserDefaults | 各功能自己的本机键 | bookmark、外观、通知开关/去重、快捷键等，不随配置文件授权 |

内部 JSON 日期采用 ISO 8601 编解码；`yyyyMMdd` 只是备份界面的显示格式，不改变 JSON 日期字段、CSV 日期或文件名。同步同一记录取更新时间较新者；时间按秒比较，同秒编辑用规范编码稳定裁决，同秒删除优先于编辑。日记录 ID 使用账户 UUID 与日桶时间戳，不添加旧草案中未实现的 ModelDailyUsage 表或设备写入者字段。

### 账户生命周期

测活只执行网络验证，不写账户或凭据。新增先获取汇率、验证账户并取得快照，再准备可选历史，再保存凭据，一次提交账户、首快照及日历史；失败补偿新凭据，补偿失败明确报告。业务提交原子性不代表两个文件跨文件原子性。编辑账户偏好归入原元数据提交路径，保持原凭据替换回滚语义。删除先提交本机账户/快照/历史删除和 tombstone，再清理凭据；凭据已不存在不阻断删除。

## 4. 供应商适配与数据流

### Pipio

输入站点可以是站点根地址或 `/v1` 地址。`ProviderURLNormalizer` 派生 origin、`/api` 管理基址和 `/v1` 模型基址。管理请求使用 `Authorization: Bearer` 和 `Pipio-User`，两者来自本机凭据文件的不同字段。

快照路径：

```text
/api/status + /api/user/self
  → 额度、余额、站点换算参数、能力
/api/data/self（看板数据）
  → 当日消费、模型/Token/缓存可选指标
/api/log/self/stat
  → 当前月份消费与今天以前的历史日消费
  → ProviderSnapshot + DailyUsageRecord
```

今日只使用看板口径：成功空数组为零，缺 quota 或失败则未知，不回退旧日志统计；可选模型请求失败不得丢弃可确认的消费总额。

### DeepSeek

余额固定调用 `https://api.deepseek.com/user/balance`。可选平台历史用量访问 `platform.deepseek.com` 的已封装用量接口，按 UTC+8 月份聚合；没有用户手动提供的 `userToken` 时只提供余额能力。

### workbuddy2api

地址仅接受 HTTPS，另保留已实现的 localhost/127.0.0.1/::1 loopback HTTP 例外；该例外尚未成为已确认安全需求。读取网关 `status` 和可选 `v1/stats`，将子账户积分、状态、请求量和模型统计转换为统一快照。网关积分独立于金额汇总；累计统计的每日记录是采集间隔观测增量，无法还原离线各日真实消耗。子账户启停请求在执行前重新读取当前状态并确认外部 ID 存在；该写操作的产品边界见 REQUIREMENT 的 `NEEDS_CONFIRMATION`。

## 5. 刷新与原子提交

```text
定时/手动/详情刷新
  → RefreshScheduler 合并账户请求
  → RefreshCoordinator 读取凭据并执行一次尝试
  → 适配器返回快照与可选历史
  → 提交前复核账户仍存在、配置未变、仍有订阅者
  → LocalRepository 原子写入快照和今日记录
  → RelayStore 发布完整投影
  → 健康/预算通知评估
  → FileSyncService 异步合并非秘密数据
```

- 默认全局并发 3，同一 scheme/host/port 的 origin 串行；历史补齐与正常刷新共用请求许可和原点冷却。
- `Retry-After` 支持秒数和 HTTP 日期。等待退避的任务释放执行名额，未结束的非协作请求仍占名额。
- 最后一个订阅者取消、删除、停用或编辑账户后，旧结果不能提交。
- 刷新提交失败不推进快照、历史、网关累计基线或已发布完整数据；失败健康状态可更新。
- 自动刷新逐账户投递，每账户最多一个定时订阅者；下一轮不等待长冷却账户结束，睡眠后不回放所有错过的周期。
- `RelayStore` 完整读完账户/快照/详情历史后才发布，读取失败保留上次投影。隐藏/停用与详情存在性分别判断；临时不可用保留窗口，确认移除才返回首页。
- `StorageAvailability` 区分启动故障与短暂供应商错误；故障态暂停刷新/同步并拒绝写入，重新读取成功后恢复。

## 6. 历史、预算和模型分析

回填入口位于 `AccountEditContainerView` / `AccountEditModalView`，观察共享 store 的进度与取消状态；使用已保存凭据，待保存凭据变更时禁用回填。详情保持固定近 7 日，无范围选择器。历史补齐只覆盖今天以前的目标日，过滤无效和跨币种记录，所有目标日处理完后一次性提交；不覆盖正常刷新写入的今日记录。供应商不支持时显示不可用原因。

预算展示校验同月、同币和有效数值；通知另要求 fresh。Pipio 使用本机日历，DeepSeek 使用 UTC+8 公历。80% 和 100% 通知按账户、月份、币种和预算值持久化去重。

`DailyModelUsageService` 按账户 ID 和供应商真实日期选择日模型，初始当天，`AdaptiveLineChart.onSelect` 回传稳定记录 ID 后切换日期。Pipio 回填同时读取该日看板模型桶；DeepSeek 从平台按日、按模型用量/费用桶归集，今日快照使用当天模型而非月度模型。旧 Pipio 同日快照可以回退；旧 DeepSeek 月度快照不按日复用。workbuddy2api 模型展示改用明确标记的网关进程累计口径，详情页不再仅显示按日不支持提示；其累计模型仍不参与日模型选择。

模型面板每行五列为模型名、总 Token、缓存占比、费用/百万 Token、当日消费。表头与数据行共享列宽：模型名占行宽 2/5，右侧四列等宽，表头和数值在各自单元格内居中，列间距统一 4pt；单行截断，悬停与辅助文本保留完整值。保留排序和 Top 5，消费占比移至悬停。模型分析按消费降序、Token 降序或名称稳定排序，同额按名称，未知消费排最后；免费和未知行保留。消费占比要求列表中金额已知、同币种且总额大于零，不将其宣称为未知请求范围的完整占比；混币消费排序先按币种分组，不比较不同币种原始数字。单位成本按各行可确认消费/正 Token 数计算，百万 Token 为单位。总 Token 优先服务商总数，否则按可确认输入、缓存读取/写入和输出计一次；缓存读取率按完整输入组成汇总分子/分母，未满足条件保持未知。显示用 K/M/B/T/P/E 缩写，悬停与辅助功能保留完整数值。

低余额/预算通知需用户开启和系统授权；发送前重查账户启用、可见性、最新快照、阈值和本机去重状态，单账户成功不等待其他账户长退避。

### 不支持日模型的供应商：累计展示（IMPLEMENTED）

**目标与范围**：按本次用户要求，workbuddy2api 在“模型消耗分析”展示已有累计模型统计。按供应商统计能力选择口径；Pipio/DeepSeek 缺少某日明细仍提示未知，不自动替换为累计数据。复用现有面板、排序与 Top 5，不新增请求、存储版本或依赖，不修改日消费、预算、趋势和 CSV 的统计口径。其他供应商只有确认累计接口及统计范围后才能接入。

**已核实数据流**：`WorkBuddy2APIAdapter.stats` 读取 `/v1/stats`，将 `models` 保存为 `ProviderSnapshot.modelUsages`，进程起点保存在 `workBuddyStats.since`。`RelayStore.accountDetail(for:)` 按父网关 ID 读取完整详情快照，子账户也使用父网关模型。原有模型投影把 nil 转为空数组，无法区分统计不可用与确实为空；新增可选累计投影保留这一区别。适配器用 `MoneyValue(.cny)` 承载 `credit`；这是现有积分存储方式，展示不能解释为人民币。

**修改入口与职责**：

- `AccountDetailData` / `RelayStore.accountDetail(for:)`：提供可选 `cumulativeModelUsages` 与 `modelStatsSince`，保留 nil 与空数组差别；从现有 `detailSnapshots` 按 `parentAccountID ?? accountID` 读取，避免使用只含启用账户的首页快照集合。读取失败继续保留最后完整投影和既有读取错误。
- `AccountDetailContainerView` / `AccountDetailView`：传递累计投影；workbuddy2api 使用累计分支，Pipio/DeepSeek 继续使用 `DailyModelUsageService`。日模型服务对网关仍返回 nil，不把累计数据写入日模型记录。
- `ModelAnalysisPanel`：使用 `ModelAnalysisScope` 明确展示口径（日消费 / 进程累计积分），集中控制标题标记、两列名称、数值格式、空状态、悬停及辅助文本；复用 `ModelAnalysisService` 的排序、占比和单位成本计算，不依据存储币种推断展示单位。

**页面与交互**：

- 标题仍为“模型消耗分析”，旁边显示“进程累计”；短说明为“网关全部模型累计，不随趋势日期切换”。子账户详情使用相同网关范围说明，不宣称是该子账户独立模型账单。
- 每行仍为五列：模型名、总 Token、缓存占比、积分/百万、累计积分。保持模型名约 2/5、右侧等宽居中及 4pt 间距；不增加常驻时间选择器或新卡片。
- 积分显示十进制数，不带 ¥/$；积分/百万 = 同进程累计积分 ÷ 正总 Token × 100 万。缺值、非法值或零 Token 时单位成本显示 `--`；真实零积分保留。悬停占比标为“已获取模型累计积分占比”，沿用完整、可比较数据的计算条件，不因 Top 5 改变分母。
- 点击近 7 日趋势只选择趋势点；累计模型列表、进程标签和单位不随日期改变。进程起点与“网关重启后重新累计”放在悬停和辅助文本中；无起点时不推算范围。

**必要状态与异常**：模型列表为 nil 时显示“暂未获取网关累计模型统计，请刷新账户。”；已知空数组显示“网关暂无累计模型记录。”。刷新整体失败保留既有完整投影并显示原有健康状态。可选 `/v1/stats` 不可用而 `/status` 成功时，以当前模型列表的 nil 提示统计不可用；现有刷新协调器可能保留旧 `workBuddyStats` 作为增量基线，但它不含模型列表，不能据此伪造可用累计明细或新的统计时间。成功读取新进程后使用新列表及新起点，不跨进程累加模型。

**验收与回归**（离线与编译分别验证，真实界面 `NOT_EXECUTED`）：

1. 有统计的网关打开详情即可看到进程累计模型；点选任意趋势日期后内容和累计标签保持一致，正常刷新后同步更新。
2. 两个不同网关相互隔离；同一网关父/子账户显示相同网关累计范围并明确归属，停用账户详情仍可读取已有完整快照。
3. nil、空数组、真实零积分、零/缺失 Token 分别按规则展示；统计接口不可用不能把旧增量基线当作新明细。
4. 变更 `since` 后仅显示新进程统计；积分列、单位成本、悬停和辅助文本不出现人民币符号或“当日消费”。排序、Top 5、长模型名与数值居中保持既有行为。
5. Pipio/DeepSeek 默认当天、点击日期切换及历史缺失语义保持原样。实现后运行相关详情投影/模型回归和 GUI build-only；实际行布局、趋势交互与辅助文本须在图形会话验收，编译不代替界面通过。

**文档衔接**：REQUIREMENT 4.4 / AC-015 与 AI_CONTEXT 的 UI 约定已区分日模型和网关累计口径。`AccountDetailRefreshChecks` 覆盖父/子投影、停用缓存、刷新失败、nil/空数组、进程变化和网关隔离；真实布局、趋势交互与供应商对账仍需对应环境验收。

### workbuddy2api 日志按日汇总（PROPOSED / NEEDS_CONFIRMATION）

用户说明所用原作者仓库已转私有；当前 Relay 仅有已核实的 `/status` 与可选 `/v1/stats` 读取，尚未取得该部署版本的日志接口或文件契约。公开分支不能作为私有版本的接口依据，本轮不猜测日志 URL、不读取容器终端日志，也不改变现有累计展示。

后续可在实际版本提供可访问的结构化请求日志时，按请求时间和模型归集为 `DailyUsageRecord.modelUsages`。接入前确认：日志来源与只读认证、时间戳和时区、请求唯一 ID/稳定游标、分页、保留范围及重启后的持久性；Token、缓存 Token、积分、最终状态和子账户归属各自缺失时保持未知。日志只有模型/时间时只能统计请求量，不能补造 Token 或积分。普通运行日志包含重试、流式片段时不能直接当作完整请求消费。

拟数据流为“可选日志读取 → 有界分页完整性与去重复核 → 供应商日历/模型聚合 → 原子提交日记录 → 按能力选择日模型展示”。不得存储提示词、响应正文、认证信息或原始日志；模型聚合复用现有本地、备份和同步结构。网关日志和子账户日志按实际范围标记；缺少归属不分摊子账户。需选定日志日历、与现有观测增量的来源优先级及迁移规则，避免同一请求双计。日志范围完整才写已知空日；分页缺口/过期/请求失败保留未知或最后完整数据，取消不提交半批。先验收跨午夜、重复/乱序、分页失败、重启、缺字段及日志过期，再开放回填；不能通过累计快照还原离线日模型。

## 7. 同步、导入导出与备份

### iCloud 文件同步

- 文件名 `relay-sync-v1.json`，仅存非秘密账户配置、设置、聚合历史和 tombstone。
- 逻辑目录为 `iCloud Drive/Documents/Relay`（中文“文稿/Relay”）；首次启用由系统选择器确认实际目录，保存 security-scoped bookmark，不拼接 Mobile Documents 或本地化路径。同步书签可解析且 stale 时尝试续写；无法解析/访问时重新授权，不改用猜测目录。备份书签的 stale 拒绝策略另见本机备份节。
- `SyncFileWorker` 在后台准备和编码，`NSFileCoordinator` 负责读写；本地版本改变时 compare-and-swap，冲突候选保留。
- 首次启用先导入再写出，避免空本地库覆盖云端；关闭同步只停止读写，不删除本地数据。
- `NSFileCoordinator` 失败或未调用 accessor 时拒绝操作，没有直接写入回退；冲突报告冻结候选，用户明确选择后应用，候选副本不会自动删除。
- 同步合并保留本机 credentialReference；新设备/供应商或 origin 改变使用新引用。bookmark、同步开关和通知去重不跨设备授权。

### 配置和 CSV

配置导出采用白名单字段；导入先检查格式、版本、大小、账号数量、地址、预算和敏感字段，再生成预览，确认后在存储层 compare-and-swap 应用。CSV 过滤账户/日期范围，保留原币种和未知状态，并转义危险公式前缀。文件上限 20 MiB、账户 1000、备份历史 200000；导入不删除未列出的本机账户，恢复替换完整非秘密数据。

`RelayStore.applyTransferredData` 阻止账户写入，取消刷新并等待在途同步，再复查预览内容；先创建当前数据备份，成功后原子替换。相同 ID/供应商/origin 保留本机凭据映射；目标改变清除旧快照/历史并分配新引用。导入/恢复保持本机同步开关，结束后恢复定时刷新，不立即强制上传。

### 本机备份

备份创建、摘要、列表/恢复及重试搬移位于同步页；目录选择、恢复默认和搬移重新授权集中于快捷键页。原搬移、校验、书签和失败保护不变。

`LocalBackupService` 是共享 actor，自动/手动/恢复前备份和目录迁移串行执行。运行期间每日按本机日历检查备份，正常创建保留最近 5 份；默认位于 `~/Library/Application Support/Relay/Backups`。

它只处理 `relay-backup-*.json` 普通文件，不读取凭据。所选父目录内的 `RelayBackups` 子目录获得私有权限；父目录、无关文件和凭据目录不改权限。

目录切换流程：

```text
选择/恢复默认目录
  → 验证父目录、bookmark、目标子目录和可写性
  → 读取源目录全部 Relay 备份
  → 复制到目标并保留新副本修改日期，核对字节和源文件集合
  → 校验成功后提交新 bookmark/路径
  → 再删除已核验旧原件
```

复制或验证失败仅清理仍经双方校验的本次副本并保留旧设置；不匹配副本保留为待处理，不能盲删；同名不同内容拒绝覆盖；删除失败保留两处有效副本并返回清理警告；迁移阶段不执行五代保留裁剪。列表与恢复预览使用 `yyyyMMdd` 主日期和 `HH:mm:ss` 次要时间。备份文件名仍为 `relay-backup-<Unix秒>-<UUID>.json`，无需重命名旧文件；固定 POSIX locale、公历、本机时区，DateFormatter 用 `yyyyMMdd` 而非周年份 `YYYY`。

列表只展示可解码备份，日期目前取文件修改时间（创建时设为备份时间，搬移新副本时保留）；外部改写修改时间可能影响排序与显示，不声称存在独立的不可变日期索引。所选路径拒绝非目录、符号链接及凭据目录/祖先/子目录；不修改用户父目录权限。

同目录重选只续授权；旧 bookmark 无效时先重新授权原目录，不能静默猜测源数据。迁移不是跨目录单次原子事务；本机清单支持重启后复核清理，中断仍可能留下双副本，不据普通回归声称断电恢复。

## 8. UI 与错误

共享 `RelayVisualStyle` 保留页面 `regularMaterial`、卡片 `thinMaterial`、嵌套 `ultraThinMaterial`，叠加适配深浅模式的中性色底；不自绘模糊/渐变替代系统材质。保留 HyperOS × iOS 视觉风格，尺寸参考替换前的 macOS UI：主/次操作使用默认 28pt、按内容宽度布局的胶囊按钮（浅色黑底白字，深色反转），导航图标使用 24pt 圆形按钮，搜索/表单输入默认 28pt，表单为 8pt 圆角与 2pt 聚焦描边，按钮/正文字号 12pt。首页汇总金额 20pt、详情指标金额 16pt，卡片内边距分别恢复为 11pt/9pt，组间距 7～16pt，导航基准高度 32pt。首页汇总内容居中，搜索在账号标题右侧；首页、表单、详情和设置底部使用紧凑悬浮操作区，首页/详情恢复状态与按钮的单行排布，操作区内边距 4pt；账户管理选择后呈现等宽的四项批量操作栏（项高 36pt），仍调用已有原子批量整理接口。减少动态效果时关闭弹性与缩放，减少透明度时使用实色底。设置分为通用、数据、快捷键、同步、账户管理、关于，选中分页使用中性色及蓝色短横线。辅助窗口锚定首页位置，显式退出返回首页，保存失败留原页，替换窗口不闪现首页。此处描述实现，深浅模式、交互与原生材质的实际视觉验收须在图形会话中另行核实。

账户详情顶部指标卡的标题、金额和说明居中；底部状态仅显示短标签（刷新中、待重试、网络异常等），正常时显示简短更新时间，完整健康信息、日期和读取错误保留在悬停与辅助功能文本中。

点击首页原有“今日总消耗”卡片通过既有 AppKit 辅助窗口打开 `ConsumptionOverviewView`，完成后返回首页，默认当日，可切换月度；分组与账户金额复用日记录，原币、覆盖与环比规则不变。

`relayPanelSurface` 嵌入 `RelayInitialFocusView` 中性响应者，页面装入窗口时设置初始焦点；设置切换分页重新安装中性响应者，窗口展示后同步确认初始响应者，不用延迟回调抢走用户点击后的焦点。文本框与图表保留点击、Tab 和辅助功能选择能力；图表初始选择为 nil，只在用户操作时回传。

`AdaptiveLineChart` 在趋势较密时限制标签，保留选中点、键盘和辅助功能描述；缺日继续使用未知语义。

页面按实际场景区分 Loading、Empty、Refreshing、Partial、Stale、Error、Success。典型错误包括凭据失效、权限不足、限流、网络、响应不兼容、本地存储不可用、bookmark 失效、同步冲突、配置冲突和备份迁移冲突。

显示规则：未知/未支持不显示 0；今日不完整时隐藏今日总消费；同步或供应商失败时保留本地可用数据；目录迁移清理失败明确显示未清理文件数。

## 9. 安全设计

- 凭据持久化只进入 `FileCredentialStore`；输入草稿和请求内存是临时生命周期，不进入业务 JSON 或日志。
- JSON 编码前使用非秘密投影；导入、同步、备份和诊断均禁止凭据字段。
- Authorization、Pipio-User、Cookie、Token、userToken 和原始响应不进入日志。
- HTTPS 是原需求；workbuddy2api loopback HTTP 的现有例外单列为待确认。代码负责校验站点/输入；不安全证书与跨 origin 认证转发是安全验收要求。供应商请求使用独立同来源重定向 delegate；下载白名单测试不能代替本项。
- 当前普通文件凭据不等同于 Keychain；不声称具备硬件保护。

## 10. 更新与发布

`UpdateService` 先绑定固定仓库的 Release tag/版本/准确 DMG 或 ZIP 文件名，下载前重新读取该 tag 元数据。优先用资产 `sha256:` digest，否则读取同版本 checksum；缺失、畸形、重复、版本不符、大小不符均拒绝。临时下载通过独立重定向策略限定 GitHub/CDN 路径，验证成功后移入 Downloads 且不覆盖已有文件，失败清理暂存。只下载，不解包替换自身。

`.github/workflows/build.yml` 定义 main/tag 发布：回归、契约、GUI build-only、打包、checksum 复核、上传 ZIP/DMG/metadata/checksum，再创建 Release；PR 构建不等于发布。使用 ad-hoc、手动 Gatekeeper 放行，不采用 Developer ID/公证。SHA-256 不认证发布者身份；更详细流程见 [CI_RELEASE](CI_RELEASE.md)。

DMG 文件图标由 `scripts/set-dmg-icon.swift` 复用 `Resources/AppIcon.icns`，嵌入 UDIF 的 `icns/-16455` 资源。脚本读回验证相同字节并核对原有磁盘资源；失败拒绝继续。图标嵌入发生在最终 checksum 之前，不修改已签名的应用包，不依赖发布流程可能丢弃的 Finder 扩展属性。`scripts/test-dmg-icon.sh` 验证仅复制数据字节后的图标保留、映像完整性和非法输入保护；Finder 实际展示及真实发布下载仍须对应环境验收。

## 11. 验证设计

离线测试采用独立 Swift 脚本和临时 fixture，不使用真实供应商凭据：

- `scripts/test-regressions.sh`：业务、刷新、存储、同步、账户偏好/排序、备份、历史、预算、模型和图表回归。
- `scripts/test-account-ordering.sh`：完整 ID 集合校验、旧排序稳定性、单次写入、失败/CAS 保留、元数据隔离、置顶优先、配置/备份/同步载荷兼容及落盘重开；不代替真实上下移按钮交互验收。
- `scripts/test-contracts.sh`：DeepSeek 用量、快捷键、同步冲突和 GUI 会话保护。
- `scripts/test-window-navigation.sh --build-only`：编译 GUI 导航检查，不操作 WindowServer。
- `swift build`：SwiftPM 应用构建；本机已核实的隔离 HOME/缓存/MacOSX26.5 SDK 命令见 AI_CONTEXT；部署目标仍为 macOS 27，发布 runner 配置为 xcode-27。
- `git diff --check`：文档和代码格式检查。

验证状态按证据使用：`IMPLEMENTED` 表示已有代码，`VERIFIED` 只表示对应检查在指定提交/环境通过，`NOT_EXECUTED` 表示目标验收未执行，`PROPOSED` 表示候选方案，`NEEDS_CONFIRMATION` 表示需求冲突待决定。代码存在、fixture 通过和 GUI 编译都不能代替真实 GUI、供应商、iCloud 双 Mac、发布资产或安装验收。

| 验收范围 | 现有验证入口/夹具 | 证据限制 |
|---|---|---|
| 账户与表单（AC-001/002/005/008/014） | `AccountFeedbackChecks`、`AccountFormPreferencesChecks`、`RegressionChecks` | 网络/磁盘注入和状态验证，不代替真实表单操作 |
| 刷新与故障（AC-003/009/010/011） | `RefreshSchedulingChecks`、`StorageRecoveryChecks`、`RegressionChecks` | 不代替真实睡眠唤醒、网络及供应商对账 |
| 历史/预算/模型（AC-004/006/012/013/015） | `HistoryBackfillChecks`、`ProductFeatureChecks`、`PipioDashboardContractChecks` | fixture 统计不等于官网真实账单对账或系统通知体验 |
| 迁移/备份（AC-016/017/018） | `DataTransferChecks`、`TransferIntegrationChecks`、`BackupMigrationChecks` | 此三组检查不含真实目录选择器及断电；子进程中断由 StrengtheningChecks 单列验证 |
| 备份日期/导航（AC-019/020） | GUI build-only，`WindowNavigationContractChecks` 的实际运行需图形会话 | 日期专门行为检查和真实界面验收尚未执行 |
| 同步（AC-007/021） | `SyncSafetyChecks`、`SyncConflictContractTests`、双机 fixture 脚本 | fixture 不证明真实 iCloud 下载、冲突或第二台 Mac |
| 更新（AC-022） | `UpdateIntegrityChecks`、`test-update-integrity.sh` | 不证明当前 Release 已发布、可安装或完成升级 |

新增 `StrengtheningChecks` 关联 AC-023～AC-032；完整离线回归、三个契约、GUI build-only、SwiftPM 构建和本机重定向专项在基于 `2b4a117` 的当前未提交工作区通过。备份重新创建服务后重试已由 fixture 覆盖，子进程强制退出在复制与清理阶段另有检查；真实断电和原生目录授权仍未验收。

日模型回归覆盖旧 JSON 解码、日期/账户隔离、空与未知、DeepSeek 日模型与月度总量分离、Pipio 历史看板可选失败和回填提交后模型保留。界面焦点与五列布局需要原生图形会话验收；`WindowNavigationContractChecks` 已增加初始中性响应者检查，build-only 不代替运行。

专项运行入口 `scripts/test-provider-redirects.sh` 用两个本机回环服务器验证生产 URLSession 的同来源认证和跨端口/多跳/方法变化保护，不连接真实供应商，不证明供应商 HTTPS 实机对账。系统通知和原生目录选择仍需实际应用环境。

## 12. 当前决策

| 编号 | 决策 |
|---|---|
| D-001 | 原生 SwiftUI/AppKit 单体应用，不引入自建后端。 |
| D-002 | 供应商适配器输出统一领域模型，UI 不直接处理供应商 JSON。 |
| D-003 | 凭据与业务/同步数据分离；使用私有文件而非 Keychain。 |
| D-004 | Pipio 管理 API `/api` 与模型 API `/v1` 分开；不混用令牌。 |
| D-005 | iCloud 使用普通文件，不使用 CloudKit Container；冲突保留候选。 |
| D-006 | Bundle ID `cloud.dinghao.relay`，GitHub Releases + ad-hoc，手动安装；不使用 Developer ID/公证。 |
| D-007 | 默认刷新 5 分钟、汇率 7 天、历史 1 年、低余额 20；未知今日消费不展示。 |
| D-008 | Carbon 全局快捷键运行时与 AppKit 面板控制分离，事务注册/回滚，本机保存。 |
| D-009 | DeepSeek 官方余额与用户手动提供的可选平台历史分开，历史/月份使用 UTC+8。 |
| D-010 | iCloud 冲突生成不可变报告，暂停自动写回，用户决定后应用，保留候选。 |
| D-011 | 离线、编译、真实 GUI、双 Mac、供应商和发布分别验收，不以 fixture 替代实机。 |
| D-012 | 当前 JSON repository；SwiftData 只保留未来替换空间。 |
| D-013 | 预算、分组、置顶归入账户表单；搜索位于账号标题右侧。 |
| D-014 | 备份目录切换按复制、校验、提交、清理；固定日期 `yyyyMMdd`、时间 `HH:mm:ss`。 |

## 13. 未决事项与后续入口

需求未决项为 workbuddy2api 有限远端启停和 loopback HTTP 例外，见 REQUIREMENT；不据现有代码确认“只读”或“仅 HTTPS”的需求变更。

### 13.1 当前新增实现（IMPLEMENTED）

用户已授权恢复与加强项及六项产品功能。复用 JSON repository 和现有页面，不新增后端、数据库或第三方依赖。

| 能力 | 修改入口与数据流 | 限制 |
|---|---|---|
| 损坏库恢复 | 首页故障提示 → `StorageRecoveryView` → `RelayStore` → `RecoverableLocalRepository` → `FileLocalRepository.recover` | 仅可读损坏库；复核原字节及备份，协调替换前保留 `relay-damaged-UUID.json`。未知版本不降级，重新分配凭据引用并关闭同步；保留或协调失败拒绝替换。 |
| 新增账户提交 | `AccountService` 准备网络数据/历史 → 保存新凭据 → `LocalRepository.commitNewAccount` | 业务数据一次提交；跨文件仍需补偿，补偿失败报告。进程中断可能留下未引用凭据，不宣称两个文件原子提交。 |
| 请求跳转 | `HTTPClient` 默认 ephemeral 会话 + `ProviderRedirectDelegate` → `ProviderRedirectPolicy` | 每跳比较原请求来源、端口、方法；跨站/降级/用户信息拒绝，同来源保留认证。loopback 例外不扩大。 |
| 搬移恢复 | `LocalBackupService` 本机 `.relay-backup-migration.json` → 同步页显式重试 | 清单含目录/bookmark/阶段/文件名/hash。目录选择以私有原子 `.relay-backup-selection.json` 为提交标记，`relay.localBackupSelection`/旧键只作兼容提示。双方内容重新核验后清理，修改或授权失效保持待处理；期间暂停五代裁剪。 |
| 通知状态 | `NotificationStatusService` / `NotificationStatusPanel`，集中于快捷键分页的通知权限区 | 检查系统授权/横幅状态，固定示例测试不消费去重；展示提交失败，不声称系统接受就是已展示。 |
| 消费总览 | 首页今日总消耗卡片 → `ConsumptionOverviewView` / `ConsumptionOverviewService` | 按供应商日历、原币日记录统计当日、本月/上月及覆盖，不重复累加月快照；已结束自然日的完整同币同长度同期且上期非零才显示环比。 |
| 脱敏诊断 | 设置关于 → `DiagnosticExportPanel` → 白名单 `RelayDiagnosticReport` | 预览固定内容后主动保存，无账号名、UUID、URL、路径、原始错误或凭据，不上传；存储故障时关于页仍可用。 |
| 备份摘要 | 既有同步页 → `LocalBackupService.summary` | 有效份数、容量、最近日期与待处理状态，支持打开目录、重试及重新授权。 |
| 导入差异 | `ConfigurationDiffService` → 既有确认 sheet | 逐字段前后值、设置变化、历史清除及重填凭据提示；现有 CAS 保留，同步开关保留本机。 |
| 批量整理 | 既有账户管理 → `RelayStore.organizeAccounts` → repository 一次替换 | 仅真实父账户 ID，失败无半批；停用取消刷新，删除不并入批量操作。 |

### 13.2 验证与下一阶段

`StrengtheningChecks` 用临时数据验证独立损坏库恢复、原件保留、过期拒绝、版本保护、单次账户提交及补偿失败、搬移清理失败后重新创建服务重试、批量状态、消费覆盖与币种隔离、导入差异、跳转策略及诊断白名单。另用子进程在复制和清理阶段直接退出、不执行回滚，验证重启后的恢复；仍不等于断电或原生目录授权验收。系统通知、目录选择和 UI 仍需图形会话；供应商真实请求和 Release 安装升级另行验收。

更多供应商需确认管理 API；OpenAI 模型接口兼容不等于账单兼容。WidgetKit 保持 `PROPOSED`/当前非目标，未建立扩展 target、App Group 和签名嵌入。

真实双 Mac 按用户决定跳过本轮，不增加阻塞，也不标通过；后续按 [双机验证说明](verification/icloud-multidevice.md) 单独记录。
