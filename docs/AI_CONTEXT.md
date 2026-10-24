# Relay 项目长期上下文

> 维护对象：长期有效的项目事实、技术边界和验证边界。
> 本文件不记录逐次实现日志、临时进度、真实凭据或个人数据。
> 最近整理：2026-10-11。
> 阅读顺序：本文 → [需求与验收](REQUIREMENT.md) → [当前技术设计](DESIGN.md)。

## 项目定位

Relay（驿站）是面向 Apple Silicon、macOS 27 的菜单栏应用，用于只读查看多个 AI 服务商和多个账户的余额、消费、请求量和 Token 用量。应用直接访问供应商接口，没有 Relay 自建后端。

当前正式支持的供应商适配器为 Pipio、DeepSeek 和 workbuddy2api；自定义 OpenAI 兼容站点仍是模型中的扩展类型，不代表已经有通用账单适配器。

## 技术栈与目录

- Swift（Package tools version 5.9、Swift 5 language mode）、SwiftUI，必要处使用 AppKit；Swift Package Manager 可执行目标。
- 网络使用 Swift Concurrency 和 `URLSession`。
- 本地业务数据使用版本化 JSON，通过 `LocalRepository` 访问；当前本地文件 schema 为 2，文件位于 `~/Library/Application Support/cloud.dinghao.relay/relay-local-v1.json`。SwiftData 不是当前运行时前提。
- 本机凭据由 `FileCredentialStore` 保存到 `~/Library/Application Support/cloud.dinghao.relay/relay-credentials-v1.json`，目录 0700、文件 0600；不使用 Keychain，不进入同步、导出、备份或日志。
- 非秘密同步使用 iCloud Drive 普通文件，不使用 CloudKit Container。逻辑目录为 `iCloud Drive/Documents/Relay`（中文 Finder 显示“文稿/Relay”），由用户选择实际目录，不拼接本地化物理路径。同步文件名为 `relay-sync-v1.json`。
- 主要目录：`Sources/Relay/Models`、`Persistence`、`Services`、`UI`、`Tests`、`docs`。

## 当前架构事实

```text
SwiftUI/AppKit 菜单栏
        ↓
RelayStore / AccountService / RefreshScheduler / RefreshCoordinator
        ├── ProviderAdapter → URLSession → Pipio / DeepSeek / workbuddy2api
        ├── FileCredentialStore → 本机私有凭据文件
        ├── LocalRepository → relay-local-v1.json
        ├── FileSyncService → iCloud Drive 普通非秘密文件
        └── LocalBackupService → 本机 RelayBackups 备份
```

### 账户和刷新

- `AccountService` 负责账户验证、凭据写入、元数据保存和首个快照；网络准备后一次提交账户/首快照/历史，保存失败补偿新凭据，补偿失败明确报告。
- `RefreshScheduler` 负责账户去重、手动优先、全局并发和同源串行；`RefreshCoordinator` 负责一次尝试、退避、原子提交和取消语义。
- 单账户失败不会覆盖其他账户或上一次成功快照。未知、未支持和真实的零值保持区分。
- `RecoverableLocalRepository` 把启动读取失败分为不可读、损坏和版本不支持；故障态禁止写入，提供重新读取与损坏库备份恢复入口，不回退到可写空库；恢复保留原件，重新分配凭据引用并关闭同步，不覆盖不可读文件或未知版本。
- `AccountHealth` 是运行期状态，区分凭据、权限、限流、网络、供应商、响应不兼容和本地存储问题，不写入同步文件。
- 详情页按稳定账户 ID 读取共享 `RelayStore`，不会保留打开时的旧数据副本；临时读取失败保留最后完整数据，确认账户删除后才关闭详情页。

### 供应商边界

- Pipio 的管理地址和模型 API 地址分开规范化：`https://pipio.io/api` 与 `https://pipio.io/v1`。管理令牌和数值 `Pipio-User` 分开保存和发送。
- Pipio 今日消费使用看板数据；模型和 Token 等可选指标缺失时保持未知。历史补齐只处理今天以前的 7/30 日范围。
- DeepSeek 余额固定使用官方 `GET https://api.deepseek.com/user/balance`。平台历史用量只在用户手动提供 `userToken` 时访问网页内部接口；应用不读取浏览器 Cookie。
- workbuddy2api 读取网关状态、子账户积分和可选统计，并提供已经存在的子账户启停请求入口。远端启停与本机 loopback HTTP 的产品边界见 REQUIREMENT 的 `NEEDS_CONFIRMATION`。
- 汇率与额度换算按账户隔离；没有可靠换算值时禁止跨币种汇总。

### 数据、同步和迁移

- 日消费记录保存可选日模型聚合，旧记录 nil 为未知；Pipio 回填取同日看板，DeepSeek 按平台日/模型桶归集，今日快照模型使用当天数据。
- 本地 JSON 写入使用候选状态和原子替换；刷新、历史批量提交、导入和恢复失败不得落半批。
- iCloud 同步只包含账户元数据、设置、日/模型聚合和删除 tombstone。同步合并按稳定记录 ID、更新时间和 tombstone 处理，冲突副本保留并提示；本地数据优先可用。
- 导入导出：CSV 只导出日消费，保留原币种和未知状态；配置 JSON 只包含非秘密账户配置和设置，导入前预览并校验。
- 本机备份运行期间每日最多自动创建一份，也支持手动和恢复前备份，正常创建后保留最近 5 份；默认目录为 `~/Library/Application Support/Relay/Backups`。选择备份目录使用 security-scoped bookmark，并在所选父目录下使用 `RelayBackups` 子目录。切换目录时先复制、逐文件校验，再更新设置并删除已校验的旧原件；失败时保留旧原件。备份日期显示使用 `yyyyMMdd`，文件名仍是内部时间戳和 UUID。
- 同步载荷会关闭同步开关；目录 bookmark、通知开关/去重、快捷键和外观等 UserDefaults 偏好仅存本机。
- 凭据引用只在本机解析；跨设备同步、配置导入和备份恢复都不会复制凭据正文。相同账户 ID/供应商/origin 保留本机引用；来源变化或新账户分配新引用。

### 恢复与使用反馈

- 备份搬移清单、授权与阶段仅留本机，未完成时保留有效文件，支持显式重试；完成前不执行五代裁剪。
- 首页点击“今日总消耗”卡片打开当日/月度及分组已记录消费总览，按原币/供应商日历统计覆盖，已结束自然日的完整可比同期数据才显示环比。
- 低余额/月预算设置显示系统授权与测试通知；测试不占真实去重，提交失败可见。
- 关于页支持白名单脱敏诊断预览及主动导出，无账号名、ID、站点、路径、原始错误或凭据，不上传。
- 同步页有备份份数/容量/最近成功及导入字段差异；账户管理支持原子批量分组、隐藏和启停，删除单独确认。

### 当前 UI 约定

- 保持菜单栏、Popover、设置分页和辅助窗口的信息结构；视觉按已确认的 HyperOS × iOS 玻璃拟态体系统一。首页、账户表单、详情和设置接入胶囊按钮、圆形图标按钮、输入与卡片样式；原生材质保留，不能只新增未被页面调用的组件。
- 详情趋势固定近 7 日，不提供历史范围选择；历史 7/30 日回填在账户编辑页，有进度/取消。Pipio/DeepSeek 模型初始当天，点击趋势日期读取该日日模型，单行五列展示；旧明细缺失不冒充已知。workbuddy2api 展示父网关进程累计模型与积分单位，不随趋势日期切换，子账户同样标明网关范围；累计列表保留 nil 与空数组差别，不写入日模型。
- 页面、设置分页与 sheet 通过中性初始响应者避免自动聚焦搜索/文本/趋势；用户点击、Tab 和辅助操作仍可聚焦。
- 预算、分组、置顶在添加/编辑账户表单中保存；首页提供搜索、分组筛选和置顶排序，筛选不改变汇总口径。
- 设置「数据」分页把数据刷新、历史数据、月预算通知作为同级区块；设置「同步」分页承载导入、导出和本机备份。
- 关闭设置、添加账户、编辑账户和账户详情返回首页；保存失败留在原页，点击外部隐藏保留未提交内容。设置内 sheet 返回父页面，退出 Relay 仍退出程序。
- 本机备份列表和恢复预览主日期显示 `yyyyMMdd`，时间以 `HH:mm:ss` 作为次要信息。

## 安全和发布边界

- Pipio/DeepSeek 地址校验要求 HTTPS；workbuddy2api 另允许本机 loopback HTTP（localhost/127.0.0.1/::1），与原 HTTPS 需求的例外边界见 REQUIREMENT；跨 origin 不转发认证头属于安全要求，供应商请求使用独立同来源重定向 delegate，拒绝跨站/端口/降级/方法改变，真实请求仍需验收。`UpdateService` 已有独立的下载重定向白名单和 SHA-256 校验，不据此推定供应商请求使用同一策略。
- 日志、诊断、同步、导出和备份不得出现 Authorization、Token、Cookie、Pipio 用户 ID 或 DeepSeek `userToken`。
- 当前发布路线是 GitHub Releases、ad-hoc 签名和手动安装；不把 Developer ID、公证或 App Store 作为前提。SHA-256 只证明下载完整性，不证明发布者身份。
- 当前工程只有 SwiftPM 可执行目标和手工 app 打包入口，没有 WidgetKit extension target。
- 真实第二台 Mac 的 iCloud 验收、真实供应商对账和完整发布安装验收不属于当前已验证事实。

## 构建与验证

部署目标为 macOS 27；本机已核实可用的 Command Line Tools 构建配置使用 MacOSX26.5 SDK 和隔离缓存（不代表降低部署目标）：

```bash
HOME=/tmp/relay-home \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/relay-cache \
CLANG_MODULE_CACHE_PATH=/tmp/relay-clang \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift build --scratch-path /tmp/relay-build
```

离线验证入口：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/test-regressions.sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/test-contracts.sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/test-provider-redirects.sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/test-window-navigation.sh --build-only
git diff --check
```

`scripts/verify-icloud-sync.sh --mode deterministic` 提供同步 fixture 验证；退出码 2 表示没有 fixture 失败但缺少真实第二台 Mac，不能当作双机通过。`test-window-navigation.sh --run` 需要实际图形会话，环境不可用的退出码 77 表示跳过，不表示通过。

`bash scripts/preview-ui.sh --build-only` 编译 `.build/ui-preview/RelayPreview.app`；`--run` 在本机打开真实页面代码的深浅双栏预览。预览使用独立 bundle ID、内存账户/凭据与空供应商适配器，不连接真实供应商；只用于视觉与交互检查，不替代生产应用、窗口导航或供应商验收。

这些检查覆盖离线业务、契约和 GUI 检查编译。重定向专项仅绑定本机回环服务；系统文件协调与本机端口在受限沙箱可能被拒绝，应在允许的验证环境执行，不绕过生产保护。`--build-only` 不等于真实 GUI 验收；真实图形会话、供应商请求、第二台 Mac、发布资产和安装升级仍需对应环境证据。当前 CLT 沙箱可能阻止 SwiftPM 的 `sandbox-exec`，应使用隔离缓存配置并在允许的构建环境重试，不能把沙箱错误写成源码编译失败。

## 已确认的默认值与系统能力

- 自动刷新默认 5 分钟，当前设置按分钟输入，最少 1 分钟；不再描述为固定四档选择器。
- 额度/汇率自动刷新默认每 7 天，可选每天、每周、每月、仅手动；手动 USD→CNY 按账户保存，不能修改 `quota_per_unit`。
- 历史默认 1 年，当前选项为一月、半年、一年、永久；低余额默认阈值 20，未知余额不提醒。
- 菜单栏使用系统单色闪电，仅显示可核实今日消费数字；固定宽度为 70pt，未知消费只保留入口图标。
- 共享原生材质由 `RelayVisualStyle` 管理：页面 `regularMaterial`、卡片 `thinMaterial`、嵌套状态 `ultraThinMaterial`。
- `RelayVisualStyle` 以替换前的 macOS UI 为尺寸参考：28pt 主/次胶囊按钮及搜索/表单输入，24pt 图标按钮，32pt 导航基准高度，12pt 按钮/正文。首页汇总金额 20pt、详情指标金额 16pt，卡片内边距 9～11pt，首页/详情底栏恢复单行排布；窗口外框保持原尺寸。它同时管理输入聚焦描边和紧凑悬浮操作区。深色面板/卡片以黑色与 `#1C1C1E` 为底；减少透明度使用实色回退，减少动态效果关闭按压缩放与弹性过渡。实际图形界面验收仍需单独执行。
- 快捷键仅支持“显示/隐藏面板”和“刷新全部账户”，由 `GlobalShortcutService` 封装 Carbon `RegisterEventHotKey`，可分别留空；登录项使用 `SMAppService.mainApp`，需要实际应用包/系统环境证据。
- 更新、打包流程分别见 `UpdateService`、[CI 与发布说明](CI_RELEASE.md)；workflow 存在不等于当前提交已发布。
- DMG 文件图标使用正式 ICNS，嵌入 UDIF 文件内容并读回核验，完成后生成最终 checksum；不依赖 Finder 扩展属性。专项 `scripts/test-dmg-icon.sh` 验证数据复制后的图标和映像完整性，不代表 Finder 或真实发布下载已验收。

## 维护规则

- 新的长期事实直接更新对应章节，不追加“某日实现记录”；代码变更日志用 Git 历史，具体构建/验收证据按提交、命令、环境和结果记录，不把一次通过永久沿用。
- 需求变化先更新 REQUIREMENT，再更新 DESIGN 和本文件中受影响的事实。
- 设计方案、待确认项和验证结果必须分别标记 `PROPOSED`、`NEEDS_CONFIRMATION`、`VERIFIED`、`NOT_EXECUTED`；代码存在不等于环境验收完成。
- 先读取本文件及 REQUIREMENT/DESIGN，保护用户已有未提交修改，按当前角色工作；需求与代码冲突时保留目标与现状，不能由代码反推授权。
- 本轮三个基线文件优先于旧工作流记录中的实现状态；`docs/workstreams` 是历史任务材料。`SECURITY_DESIGN.md` 中旧删除顺序与现状不同，账户删除以当前 REQUIREMENT/DESIGN 为准。
- 真实凭据、用户数据和临时命令输出不得进入文档。
