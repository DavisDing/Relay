# AI CONTEXT

> Relay 项目长期上下文。所有 AI Agent 开始工作前应读取。
> 只记录长期有效的信息，不记录临时任务过程、真实凭据或个人数据。

## 1. Project Overview

- 名称：Relay / 驿站
- 类型：macOS 菜单栏桌面应用
- 目标：只读监控多个 AI 服务商、多个账户的余额、消费和用量。
- 平台：macOS 27，Apple Silicon。
- 网络模式：应用直接访问供应商 API，无 Relay 自建服务器。

## 2. Technology Stack

- UI：SwiftUI，必要时使用 AppKit。
- 语言：Swift。
- 并发/网络：Swift Concurrency + URLSession。
- 图表：Swift Charts（如当前工具链可用）。
- 当前本地数据：版本化 JSON 文件，通过 `LocalRepository` 抽象访问。
- 凭据：`FileCredentialStore`，保存到本机 Application Support 私有文件，不使用 Keychain。
- 同步：规划使用 iCloud Drive 普通文件，仅同步非秘密数据；不使用 CloudKit Container。
- 构建：Swift Package Manager，`swift build`。

## 3. Project Structure

```text
Relay/
├── Sources/Relay/Models/       # 领域模型和旧 UI 展示模型
├── Sources/Relay/Persistence/  # LocalRepository、本地 JSON 存储
├── Sources/Relay/Services/     # 供应商适配器、凭据、刷新、汇率、汇总
├── Sources/Relay/UI/           # SwiftUI 菜单栏、面板、账户页面
├── Sources/Relay/main.swift    # 应用入口
└── docs/                       # 需求、设计和长期上下文
```

## 4. Architecture

```text
SwiftUI / MenuBar
       ↓
Local business services
(AccountService / RefreshCoordinator / DashboardAggregator / RateService)
       ├── ProviderAdapter → URLSession → Pipio / DeepSeek
       ├── FileCredentialStore → local private credential file
       └── LocalRepository → relay-local-v1.json
```

本项目没有传统远程后端；“后端”指本地业务层、供应商适配器和持久化层。

## 5. Important Modules

- `PipioAdapter`：访问 Pipio 管理 API；管理令牌与 Pipio 数值用户 ID 分开建模；从 `/api/status` 获取该账户自己的 `quota_per_unit`/币种参数。
- `DeepSeekAdapter`：只访问 DeepSeek 官方余额接口；余额按真实 CNY 处理，不额外套汇率。
- `AccountRate` / `RateService`：汇率和换算参数按 `accountID` 隔离，禁止按 provider/host 共享。
- `AccountService`：验证账户、保存账户元数据和首个快照，失败时回滚本地凭据。
- `RefreshCoordinator`：账户级刷新和错误隔离；单账户失败不能覆盖其他账户或旧快照。
- `DashboardAggregator`：仅在金额可比较、数据完整时汇总；不把未知值伪造为 0。
- `LocalRepository`：当前实现是版本化 JSON；未来可在完整 Xcode 工具链下替换为 SwiftData，但 SwiftData 不是当前运行前提。
- `FileCredentialStore`：凭据文件默认位于 `~/Library/Application Support/cloud.dinghao.relay/relay-credentials-v1.json`；父目录 0700，文件 0600，不进入同步文件。

## 6. Important Decisions

### Decision 001：账户级汇率

每一个 `AccountRate` 必须绑定一个账户 UUID。Pipio 每个账户单独读取站点返回的换算参数；DeepSeek 的原生余额为 CNY，转换系数为 1。没有可靠换算值时禁止跨币种求和。

### Decision 002：不使用 Keychain

日期：2026-09-18。

用户明确选择不使用 macOS Keychain，改为 Relay 私有 Application Support 文件。该方案只提供 0700/0600 文件权限和本地隔离，不等同于 Keychain 的硬件保护、系统访问控制或授权提示。当前不自定义加密算法、不保存到 iCloud、不写入日志、源码或同步 JSON。

### Decision 003：SwiftData 不是当前前提

SwiftData 是 Apple 系统框架，不单独收费，也没有固定独立包体大小；但当前实现使用本地 JSON repository，以减少工具链和迁移复杂度。`LocalRepository` 协议保留未来迁移空间。

### Decision 004：免费 Apple 账户分发边界

免费 Apple 账户可以本地开发、编译和调试；Apple Developer Program 标准价格为 99 USD/年（地区可能显示本地货币），付费计划主要影响 Developer ID 签名、公证、App Store/TestFlight 等分发能力。首期按 GitHub Releases + 用户手动放行 Gatekeeper 的路线设计。

## 7. Coding Rules

- 优先小范围修改，避免无关重构。
- 不写入真实 Token、API Key、Pipio User ID、Cookie 或日志。
- 不读取浏览器 Cookie，不复制网页 userToken，不调用 DeepSeek 私有网页接口。
- UI 不直接拼 API URL、不解释供应商 JSON、不持有长期凭据。
- 账户失败必须隔离；刷新失败保留旧快照并显示 stale/error。
- 未支持或不完整指标保持 `nil`，不显示伪造的 0。
- 跨币种仅使用账户专属、有效的换算参数。
- 新依赖前先确认现有能力不能复用。

## 8. UI Rules

已确认的菜单栏、Popover、添加账户、详情和设置页面应保持布局与视觉风格稳定。优先修改数据绑定、状态、错误处理和业务调用，不为了接入业务重做 UI。

## 9. Environment

- macOS
- Swift Package Manager
- Swift 5.9 language mode
- macOS 27 deployment target
- 当前验证命令：
  `HOME=/tmp/relay-home SWIFTPM_MODULECACHE_OVERRIDE=/tmp/relay-cache CLANG_MODULE_CACHE_PATH=/tmp/relay-clang SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build --scratch-path /tmp/relay-build`

## 10. Known Constraints

- 当前 Command Line Tools 环境无法稳定使用 XCTest；测试结果必须如实标记，不能伪造通过。
- 当前 `FileLocalRepository` 是业务数据实现；SwiftData 仅是后续可替换方案。
- 凭据文件是明文 JSON + 文件权限保护，属于用户选择的安全降级；若未来需要更强保护，应先设计用户主密码/系统加密迁移，不得私自声称已加密。
- 不使用 CloudKit Container；同步文件永远不能包含凭据。

## 11. 2026-09-18 Implementation Update

- UI 与业务层已完成首轮接线：`RelayStore` 统一持有 `AccountService`、`RefreshCoordinator`、`FileLocalRepository`、`FileCredentialStore` 和生产适配器注册表。
- 添加账号的测活现在执行真实 Pipio/DeepSeek 请求；保存前验证，保存后写入首个快照；不再写入硬编码余额或模拟延迟。
- 菜单栏和主面板读取本地快照，刷新失败保留旧快照；未知余额在 UI 中显示 `--`。
- `docs/SECURITY_DESIGN.md` 是凭据不使用 Keychain 的单独安全设计记录。
- 本地业务 JSON 在打开已有文件和写入时都会校正为目录 `0700`、文件 `0600`。
- SwiftData 结论已再次确认：它是 Apple 系统框架且不要求单独付费；当前仍不作为项目运行时依赖。Apple 免费账户足以做本地开发/编译/调试，正式 App 分发、公证和 Developer ID 才需要付费 Developer Program。

## 12. 2026-09-19 Implementation Update

- `RelaySettings` 默认自动刷新间隔与产品约束统一为 5 分钟，并在设置界面提供 1/5/15/30 分钟选择。
- 设置界面已接入历史保留策略：1 年或永久；本地 repository 按策略清理日聚合数据。
- `AccountService.updateAccount` 在替换凭据时先读取旧凭据；元数据写入失败会恢复旧凭据，避免出现半提交状态。
- 账户编辑保存改为 `async throws`；只有业务保存成功才关闭弹窗，失败会留在弹窗内显示错误。
- Pipio 日志列表已按当天分页拉取并聚合模型、请求数、Token 与消费；无法解析或接口不可用时保持模型指标未知，不影响余额/基础快照。
- `ProviderSnapshot` 增加可选 `modelUsages`，旧版本 JSON 缺少该字段时仍可解码。
- iCloud 普通文件同步增加 `NSFileCoordinator` 协调读写，并尝试合并可解码的未解决冲突版本；同步不可用仍不阻断本地数据路径。
- 首次启用同步时先尝试导入已有云端 payload，再写入本机设置，避免空本地库覆盖已有同步文件。
- 删除账户增加二次确认；账户详情接入已保存的每日趋势和 Pipio 模型聚合。

## 13. AI_CONTEXT UPDATE PROPOSAL

- 变化：新增模型用量聚合、编辑回滚、历史保留选项、刷新频率选项和同步冲突协调。
- 原因：补齐 P1 详情能力并修复编辑/同步的半提交和并发风险。
- 影响：`ProviderSnapshot` schema 增加可选字段；本地 JSON 和同步 JSON 对旧数据保持向后兼容；刷新期间 Pipio 多一个分页日志请求路径。
- 建议：后续新增适配器时继续将模型聚合保持为可选能力，不把缺失模型数据转换为 0。
- 变化：iCloud 同步目录改为系统选择器确认并保存安全作用域 bookmark；低余额通知去重状态持久化到本机 UserDefaults；设置页接入 `SMAppService.mainApp` 登录项。
- 原因：满足目录授权、每日通知去重和开机启动的产品约束，同时让未打包开发环境中的失败可见。
- 影响：bookmark 和通知日期均为本机元数据，不进入同步 JSON；登录项能力依赖正式 macOS 应用包，裸 SwiftPM 可执行文件只能显示真实错误。

## 13. 2026-09-19 Implementation Update (continued)

- iCloud 同步目录由系统目录选择器确认，并保存安全作用域 bookmark；同步服务不再根据本地化路径拼接目录。
- 低余额通知去重状态按账户 UUID 与自然日持久化在本机 UserDefaults；通知授权失败不会消耗当天额度。
- 设置页接入 macOS `SMAppService.mainApp` 登录项开关；裸 SwiftPM 可执行文件没有应用包身份时，UI 显示真实注册错误。

## 14. 2026-09-20 Implementation Update

- 全局快捷键已接入 AppKit 菜单栏控制器：支持显示/隐藏 Relay 面板和刷新全部账户；未新增“打开设置”快捷键。快捷键配置仅保存到本机 UserDefaults，注册失败不会覆盖上一次有效配置；未打包的 SwiftPM 环境明确显示未注册。
- 菜单栏可见面板由 `RelayMenuBarController` 持有 `NSStatusItem + NSPopover`，用于提供可被全局快捷键控制的显式显示/隐藏目标；SwiftUI `Settings { EmptyView() }` 仅保持 App 生命周期，并保留退出命令。
- DeepSeek 官方接口能力探测已明确区分余额与历史/分模型用量：当前官方 API 不提供账户历史或分模型聚合端点，因此用量报告返回 `unsupported`，`daily` 与 `models` 保持 `nil`；不读取 Cookie、userToken 或私有网页接口。
- iCloud 同步状态已接入设置页；检测到 unresolved conflict versions 时只生成冲突报告并保留本机/远端候选，不在用户决策前修改本机 repository 或覆盖主同步文件。用户选择“保留本机 / 保留远端 / 接受合并结果”后，才通过显式 resolve API 应用结果；解析过程不自动删除冲突候选。
- 同步目录缺失时状态显示为 `unavailable`，本机数据仍可读取和刷新；同步异常状态不会阻断本机业务路径。同步 payload 继续通过安全投影排除凭据。
- `scripts/verify-icloud-sync.sh --mode deterministic` 的 SYNC-001 至 SYNC-004 已通过；SYNC-005 因没有第二台真实 Mac 标记 `blocked`，不能以 fixture 结果替代实机验证。
- 当前 `swiftc -parse-as-library -typecheck` 全量类型检查通过，仅有既有 SwiftUI 本地化插值弃用警告。`scripts/test-regressions.sh`、三组独立 contract tests 均通过。`swift build` 仍受本机 Swift 编译器与 macOS SDK 版本不匹配阻塞，不能视为构建通过。
