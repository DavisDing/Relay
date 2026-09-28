# Relay / 驿站

Relay 是一款面向 Apple Silicon 的 macOS 菜单栏应用，用于只读监控多个 AI 服务商、多个账户的余额、消费、积分和用量。应用直接访问供应商接口，不经过 Relay 自建服务器；本地业务数据优先，单个账户刷新失败不会覆盖其他账户或已有快照。

> 本文按当前代码整理，基线为 **2026-09-26** 的 `main` 分支提交 `566a162`。它描述“目前实际实现”，需求文档中的规划项不会被当作已完成能力。

## 当前状态速览

| 范围 | 当前状态 | 说明 |
| --- | --- | --- |
| macOS 菜单栏应用 | 已实现 | SwiftUI + AppKit，默认 accessory app，不显示 Dock 图标 |
| Pipio 多账号监控 | 已实现 | 余额、今日/月度消费、模型用量、趋势、账户级汇率 |
| DeepSeek 余额 | 已实现 | 使用官方余额接口，按供应商返回币种展示 |
| DeepSeek 历史/模型用量 | 条件实现 | 需要用户手动填写可选平台 `userToken`；失败时保留余额并标记为部分数据 |
| workbuddy2api 网关 | 已实现 | 网关积分、内部账号、状态、统计、手动启用/停用 |
| 本地持久化 | 已实现 | 版本化 JSON，凭据与业务数据分离 |
| iCloud Drive 普通文件同步 | 已实现 | 仅同步非秘密数据，带协调读写、合并和冲突处理 |
| 全局快捷键 | 已实现 | 显示/隐藏面板、刷新全部账户；仅保存本机配置 |
| 开机启动、低余额通知、应用更新 | 已实现 | 能力受 macOS 应用包、通知授权和 GitHub Release 条件影响 |
| 首页金额/积分隐藏 | 已实现 | 首页可一键隐藏余额、今日消费和积分，菜单栏行为不受影响 |
| 自定义 OpenAI 兼容端点 | 未实现 | UI 明确标记为后续扩展 |
| 导入/导出配置 | 未实现 | 不属于当前版本已交付能力 |
| 真实双 Mac iCloud 验收 | 未完成 | 离线 fixture 检查已具备，但不能替代第二台真实 Mac 验证 |

## 需求与实现对照

### P0：可用闭环

| 需求 | 实现情况 |
| --- | --- |
| Pipio 单账号/多账号添加、编辑、启用、停用、删除 | 已实现。设置中的账号管理支持顶层账号操作；删除会清理本地账号、快照、历史、同步 tombstone 和凭据引用。 |
| 保存运行时认证信息 | 已实现。Pipio 管理 Token、Pipio 数值用户 ID、DeepSeek API Key、可选 DeepSeek 平台 `userToken` 和网关 API Key 写入本机私有凭据文件。 |
| 读取站点状态、余额、累计/今日数据 | 已实现。不同供应商按其实际接口能力返回；缺失数据保持未知，不把未知伪装成 `0`。 |
| 菜单栏摘要、首页账户列表、账户详情 | 已实现。菜单栏保留状态图标和可用的今日消费数字；首页显示账户投影、汇总和状态；详情页显示趋势及可用模型分析。 |
| 手动刷新、定时刷新、失败保留旧数据、退避/错误隔离 | 已实现。默认刷新间隔为 5 分钟，可配置为 1/5/15/30 分钟；账户级失败保留旧快照并显示 stale/error/partial 状态。 |
| 本地历史和设置持久化 | 已实现。业务数据使用版本化本地 JSON；历史保留可配置为 1 个月、半年、1 年或永久。 |
| iCloud Drive 同步非秘密数据 | 已实现。同步目录由系统目录选择器授权并保存 security-scoped bookmark；目录不可用时本地功能继续工作。 |

### P1：产品完整度

| 需求 | 实现情况 |
| --- | --- |
| DeepSeek 官方余额 | 已实现。余额固定请求 `https://api.deepseek.com/user/balance`，不使用平台 `userToken`。 |
| DeepSeek 历史用量 | 已实现但依赖用户配置。填写平台 `userToken` 后访问平台用量接口，历史日桶、今日和首次 7 日回填统一按 GMT+8 计算；接口失败不会清空余额。 |
| 历史趋势、分模型用量 | 已实现。Relay 保存每日聚合历史，当前详情页展示近 7 日；业务层支持读取更长的历史窗口（默认最多 30 日）。Pipio 提供模型 Token/缓存/消费，DeepSeek 在平台数据可用时提供历史日用量和模型数据，workbuddy2api 提供基于统计增量的趋势与模型统计。 |
| 开机启动 | 已实现。使用 `SMAppService.mainApp`；未打包的 SwiftPM 环境无法注册时显示真实错误。 |
| 全局快捷键 | 已实现。支持“显示/隐藏 Relay 面板”和“刷新全部账户”；未实现“打开设置”快捷键。未打包环境不会虚报注册成功。 |
| 低余额阈值与通知 | 已实现。按账户阈值判断，默认阈值为 20；通知按账户和自然日去重，未授权或发送失败不会提前记为已通知。 |

### P2 与扩展范围

- **自定义 New API / OpenAI 兼容站点**：当前未实现，添加账户界面会提示该能力尚未启用。
- **配置导入/导出**：当前未实现。
- **更多供应商适配器**：当前已经额外实现 `workbuddy2api`，但尚未提供通用自定义适配器机制。
- **应用内检查更新**：当前已实现为 GitHub Releases 检查和用户确认下载，不会静默替换或自动重启。

## 支持的供应商

### Pipio

用户在添加账户时提供站点地址、Pipio 管理 Token 和数值用户 ID。Relay 会拆分站点 origin、管理 API 基址和模型 API 基址：

- 站点状态：`/api/status`
- 账户验证和余额：`/api/user/self`
- 月度统计：`/api/log/self/stat`
- 当日看板与模型明细：`/api/data/self`
- 请求头：`Authorization: Bearer <management-token>`、`Pipio-User: <numeric-user-id>`

`quota_per_unit`、币种和站点美元/人民币汇率在运行时按账户读取。Pipio 管理 Token 不会被当作 `/v1` 模型 API Key 使用。今日消费、模型消费和官网看板数据使用同一份当天看板口径；数据不完整时保持未知。

### DeepSeek

- API Key 只用于官方余额接口。
- 平台 `userToken` 是可选项，只能由用户手动输入，用于历史用量接口。
- Relay 不读取浏览器 Cookie，不获取网页会话，也不自动抓取登录状态。
- 未填写 `userToken` 时，详情页显示“仅查询余额”。
- 平台接口结构变化、认证失败或数据不完整时，余额仍可用，历史部分标记为 partial/unsupported，而不是写入 0。

### workbuddy2api

当前 UI 显示名为 **WordBuddy2Api**，持久化枚举值为 `workbuddy2api`。Relay 访问网关的：

- `/healthz`：确认服务类型；503 仍会继续检查 `/status`，因此空账号池也可以保存并查看。
- `/status`：读取内部账号、积分、停用和冷却状态。
- `/v1/stats`：读取进程累计统计，并由 Relay 计算本地去重后的每日增量。
- `/v1/accounts/{uid}/enable` / `disable`：仅在网关启用管理能力时使用。

网关作为父账号管理，内部账号作为首页投影。网关删除会连带删除本地快照、历史和凭据引用；隐藏网关不会显示内部账号，但仍可后台刷新。

## 核心行为

### 账户管理

- 设置 → 账号管理可以启用/停用、隐藏/取消隐藏和删除顶层账号。
- 隐藏账号仍参与后台刷新，但不进入首页账户列表、汇总、网关提示和低余额通知。
- 首页提供金额/积分显示切换，可将首页余额、今日消费和网关积分替换为 `••••`；该显示偏好保存在本机，不改变原始数据。
- 编辑账户时支持修改名称、低余额阈值、网关地址、手动美元/人民币汇率及供应商凭据。
- 保存前会先检查所有必填字段；保存失败留在当前页面并尽量回滚旧凭据，不清空用户输入。
- 从首页打开的设置、添加、编辑、详情窗口，显式关闭/取消/保存成功后返回首页；点击应用外部或隐藏面板则保留当前页面状态。
- 账号操作菜单统一使用紧凑的下拉指示图标，账号操作仍包括详情、编辑、同步、启用/停用和删除。

### 金额、未知值和汇总

- 未知、未支持、部分覆盖和真实的 0 分开处理。
- 跨币种汇总只使用账户专属且有效的换算参数。
- Pipio 的 `quota_per_unit` 与 USD→CNY 汇率是两个不同参数，不能混用。
- 编辑账户可设置手动 `1 USD = … CNY`；手动值优先于站点值，清空后恢复自动模式。
- 缺少可信换算参数时不伪造人民币金额，也不把账户强行计入完整汇总。
- workbuddy2api 的积分使用独立于金额汇总的积分卡片和指标。

### 模型用量

- 优先使用供应商返回的 `token_used`。
- 缺少总数时，按有效的普通输入、缓存读取、缓存写入和输出 Token 求和，每个独立分量只计一次。
- 缓存读取占比按有效分子/分母计算；缺字段、负数或分母为 0 时保持未知。
- 模型按消费金额降序排列，同额按模型名稳定排序；免费模型保留，未知消费排在最后。
- Token 列使用十进制 K/M/B/T/P/E 缩写，悬停和辅助功能保留完整整数。

## 架构

Relay 没有传统远程后端；所有业务在本机运行：

```text
SwiftUI / AppKit 菜单栏与窗口
                │
                ▼
RelayStore / AccountService / RefreshCoordinator
       ├── ProviderAdapterRegistry
       │     ├── PipioAdapter ─────── URLSession ─── pipio.io
       │     ├── DeepSeekAdapter ──── URLSession ─── api.deepseek.com
       │     └── WorkBuddy2APIAdapter ─ URLSession ─ workbuddy2api 网关
       ├── FileCredentialStore ─── 本机私有凭据 JSON
       ├── FileLocalRepository ─── 本地业务 JSON
       └── FileSyncService ─────── iCloud Drive 普通文件
```

主要模块：

```text
Sources/Relay/
├── Models/       领域模型、快照、同步和 DeepSeek 用量模型
├── Persistence/  LocalRepository、本地 JSON 读写
├── Services/     适配器、账户、刷新、汇总、凭据、同步、更新
├── UI/           菜单栏、首页、详情、添加/编辑、设置和冲突页面
└── main.swift    应用入口和 accessory app 生命周期
```

## 数据与安全边界

### 本地文件

- 业务数据：`~/Library/Application Support/cloud.dinghao.relay/relay-local-v1.json`
- 凭据数据：`~/Library/Application Support/cloud.dinghao.relay/relay-credentials-v1.json`
- 应用支持目录权限：`0700`
- JSON 文件权限：`0600`
- 写入使用临时文件和原子替换；未知 schema 版本拒绝读取，避免被新版本覆盖。

### 凭据规则

当前产品明确选择 **不使用 macOS Keychain**。凭据文件是本机明文 JSON 加 POSIX 文件权限保护，不等同于 Keychain，不提供 Secure Enclave、硬件绑定、主密码加密或逐次访问授权提示。

凭据只允许出现在：

1. 本机私有凭据文件；
2. 发起供应商请求期间的进程内存；
3. 系统网络栈发送的 HTTPS 请求头。

凭据不会写入本地业务 JSON、iCloud 同步文件、源码、文档、日志、诊断导出或 UI 回显。Relay 不读取浏览器 Cookie，也不会同步凭据；在另一台 Mac 导入账户元数据后必须重新填写凭据。

## 构建与运行

### 环境要求

- macOS 27
- Apple Silicon
- Swift Package Manager
- Swift 5.9 语言模式
- 当前包的最低部署目标：macOS 27.0

### 本地构建

项目没有第三方 Swift Package 依赖。可使用：

```bash
HOME=/tmp/relay-home \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/relay-cache \
CLANG_MODULE_CACHE_PATH=/tmp/relay-clang \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift build --scratch-path /tmp/relay-build
```

当前验证环境下，上述命令可完成构建；SwiftPM 可能打印 Command Line Tools 缓存或链接搜索路径警告，但不影响本次构建结果。正式打包应使用 macOS 27 / Xcode 27 工具链。

### 运行

```bash
swift run Relay
```

直接运行裸 SwiftPM 可执行文件时，应用仍可使用菜单栏和本地业务功能，但以下能力可能受限：

- 全局快捷键需要打包为 `.app` 才能注册。
- 登录项需要有效的应用包身份。
- 正式发布包应使用 `scripts/package-app.sh` 创建 `Relay.app`。

## 验证

### 离线回归检查

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
scripts/test-regressions.sh
```

该脚本使用 `swiftc` 编译独立检查程序，不访问供应商接口、不需要真实凭据、不依赖 XCTest。当前覆盖：

- 凭据加载、重试、原子写入与 0700/0600 权限；
- repository 写入失败时的内存/磁盘一致性；
- 账户导入、凭据替换和回滚；
- 账户级手动汇率、离线汇总和同步隔离；
- 同步合并、删除 tombstone、损坏/未知版本保护；
- 账户覆盖完整性、跨日/时区处理和设置保存失败；
- Pipio 看板、模型 Token/缓存占比、今日消费和菜单栏展示；
- workbuddy2api 统计解码、刷新去重和历史保留策略。

### 窗口导航检查

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
scripts/test-window-navigation.sh
```

该检查需要已登录的 macOS 图形会话，使用模拟内存数据验证设置、添加、编辑、详情页面的关闭/隐藏/恢复/替换行为；不会调用供应商接口。

### iCloud 同步基线

```bash
scripts/verify-icloud-sync.sh --mode deterministic
```

该检查可以验证 schema、凭据排除、删除 tombstone、冲突副本保留和云端不可用时本地数据可用。默认 deterministic 模式会将“真实第二台 Mac 验证”标记为 blocked 并返回非零状态，这是刻意设计，不能把 fixture 结果当作真实多设备验收。真实双 Mac 验收请按 `docs/verification/icloud-multidevice.md` 执行。

## 打包与发布

```bash
scripts/package-app.sh
```

默认产物写入 `.build/package/`：

- `Relay-<version>-macos-arm64.zip`
- `Relay-<version>-macos-arm64.dmg`
- `Relay-<version>-metadata.txt`

打包脚本会构建 arm64 可执行文件、生成 `Relay.app`、复制 `Resources/AppIcon.icns`、写入 Bundle ID `cloud.dinghao.relay` 并进行 ad-hoc 签名。当前发布路线是 GitHub Releases，不使用 Developer ID 签名和公证；首次打开可能需要用户在“隐私与安全性”中手动放行。

版本规则：

- `vX.Y.Z` 标签使用去掉 `v` 后的语义化版本；
- 普通分支默认使用 `0.1.<Git 提交总数>`；
- `CFBundleVersion` 始终使用完整 Git 历史计算的提交数；
- 可用 `RELAY_VERSION` 覆盖营销版本。

GitHub Actions 在 PR、`main` push、版本标签和手动运行时执行构建；`main` push 成功后按提交数创建 Release，上传 ZIP、DMG 和 metadata。CI 使用 `xcode-27` arm64 runner，并要求完整 Git 历史。

## 应用内更新

Relay 从 `DavisDing/Relay` 的 GitHub Releases API 检查版本，仅接受包含 `macos-arm64.dmg` 或 `macos-arm64.zip` 的更高版本。用户确认后下载到当前用户的 `~/Downloads`，下载完成后由用户退出 Relay 并手动替换安装。

当前没有静默更新、自动重启或签名校验安装流程；未来如采用 Developer ID + 公证，可再评估 Sparkle 等方案。

## 已知限制与未完成验收

1. 凭据文件不是 Keychain 或加密保险箱，属于已确认的安全降级。
2. DeepSeek 历史用量依赖平台内部接口和手动 `userToken`，该接口可能变化；官方余额不受此影响。
3. workbuddy2api 的统计来自网关进程累计值，Relay 只能统计已观察到的增量；容器重启前未被 Relay 刷新的区间无法恢复。
4. iCloud 同步仍需真实第二台 Mac 做下载、冲突、权限和离线恢复验收；fixture 只能证明确定性数据契约。
5. 未实现自定义 OpenAI 兼容站点和配置导入/导出。
6. 本项目当前不做充值、扣费、模型代理、税务分析或账单对账。

## 相关文档

- [需求与验收](docs/REQUIREMENT.md)
- [技术设计](docs/DESIGN.md)
- [长期项目上下文](docs/AI_CONTEXT.md)
- [凭据存储安全设计](docs/SECURITY_DESIGN.md)
- [CI 与发布](docs/CI_RELEASE.md)
- [iCloud 多设备验证](docs/verification/icloud-multidevice.md)
- [DeepSeek 用量工作流](docs/workstreams/deepseek-usage.md)
- [全局快捷键工作流](docs/workstreams/global-shortcut.md)
- [iCloud 冲突工作流](docs/workstreams/icloud-conflict.md)
