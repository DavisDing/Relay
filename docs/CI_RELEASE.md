# Relay CI 与发布

## 自动版本号

`/scripts/ci-version.sh` 使用完整 Git 历史计算提交数：

- 普通分支提交：版本为 `0.1.<提交总数>`，例如 `0.1.42`。
- `vX.Y.Z` 标签构建：版本使用标签去掉 `v` 后的值，例如 `v1.2.0` 生成 `1.2.0`。
- `CFBundleVersion` 始终使用提交数，作为单调递增的构建号。
- 可通过 `RELAY_VERSION` 覆盖营销版本；可通过 `RELAY_VERSION_PREFIX` 修改普通提交的主/次版本前缀。

版本计算依赖完整 Git 历史，因此 GitHub Actions 使用 `fetch-depth: 0`。

## GitHub Actions

`.github/workflows/build.yml` 在以下场景运行：

- `main` 分支 push：构建并上传 macOS Apple Silicon zip artifact。
- Pull Request：构建验证，不发布 Release。
- 推送 `vX.Y.Z` 标签：构建并发布 GitHub Release，附带带版本号的 zip 包和构建元数据文件。
- 手动运行：执行一次构建验证。

构建产物是 ad-hoc 签名的 `Relay.app` zip 包。当前设计没有 Developer ID 证书或公证流程；这与项目的 GitHub Releases 首期发布决策一致。用户首次打开时可能需要在 macOS 的“隐私与安全性”中手动允许。

CI 构建使用 GitHub Actions 的 `xcode-27` arm64 runner，因为 `Package.swift` 的最低 macOS 部署目标为 27.0；`macos-26` 的 SDK 无法满足该目标。

## 应用图标

正式图标位于 `Resources/AppIcon.icns`；`Resources/AppIcon.png` 是 1024×1024 透明底母图，不随应用分发。`scripts/package-app.sh` 检查 ICNS 格式，将图标复制到 `Relay.app/Contents/Resources/AppIcon.icns`，并写入 `CFBundleIconFile=AppIcon.icns`，随后对完整应用包签名。应用图标不替换菜单栏按钮或页面内的功能图标。

## 本地打包

在 macOS 上执行：

```bash
scripts/package-app.sh
```

默认产物写入 `.build/package/`，不会污染源码目录。该脚本要求 macOS 的 Swift、`codesign` 和 `ditto` 工具。

Release 附件命名示例：

```text
Relay-1.2.3-macos-arm64.zip
Relay-1.2.3-metadata.txt
```


## 离线回归验证

在 macOS 上执行：

```bash
scripts/test-regressions.sh
```

脚本使用当前 macOS SDK 和 `swiftc` 编译独立检查程序，不需要 XCTest、第三方依赖或供应商凭据。编译产物、测试 JSON 和模拟凭据只写入随机临时目录，正常结束或测试失败时清理。CI 在打包前运行相同检查，失败会阻止打包/发布。

覆盖范围：

- 凭据文件损坏/未知版本后不可被后续保存覆盖；加载可重试；写入/删除失败时缓存和磁盘保持一致；目录/文件权限为 0700/0600。
- 账号元数据、快照、每日历史、设置、删除标记及同步合并的失败写入不污染 repository 内存。
- 导入账号可补录本机凭据；编辑失败恢复旧凭据或删除本次新凭据；回滚失败单独报错。
- 两个独立本地仓库交替读取、合并和写回共享文件，保留远端新增与删除；损坏和未知版本的同步文件不被覆盖。
- 等时间记录确定性合并、删除优先、偏好时间戳兼容，以及保留本机同步开关。
- 启用账号缺快照时汇总不完整；跨日/时区失效不依赖网络；保留旧余额且不把未知消费转为零。

`NSFileCoordinator` 需要系统文件协调服务；部分嵌套沙箱会拒绝协调临时文件，需在允许该服务的 macOS 环境运行。该测试不替代真实双 Mac iCloud 冲突/下载验证、GUI 验收或真实 GitHub Release 发布。

## 同步兼容说明

- 每次导出均在同一文件协调范围内先读、合并、再写回；所有冲突版本校验完成后才修改本地数据，成功写回后才标记冲突已解决。
- 本地与同步 JSON 新增可选 `settingsUpdatedAt`，缺字段的旧文件仍可读取。仅共享偏好实际变化时更新时间，同步开关仍属于本机，不被远端开关覆盖。
- 延续原有秒级 ISO8601 格式；同秒编辑使用确定性内容比较，删除与编辑同秒时删除优先。旧版本客户端不具备新的合并行为，多设备应一并更新。
- 发布 job 使用 `gh release create --repo "$GITHUB_REPOSITORY"`，不依赖下载产物目录中存在 Git checkout。
