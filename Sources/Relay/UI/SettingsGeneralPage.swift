import SwiftUI

@MainActor
struct SettingsGeneralPage: View {
    @Binding var appearanceMode: AppearanceMode
    @Binding var fixedMenuBarWidth: Bool
    @Binding var showTodayInMenuBar: Bool
    @Binding var baseCurrency: Currency
    @Binding var lowBalanceThreshold: String
    @Binding var lowBalanceNotificationsEnabled: Bool
    @Binding var launchAtLoginEnabled: Bool
    @Binding var launchAtLoginError: String?

    var body: some View {
        SettingsPageScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("外观质感 (Appearance & Vibrancy)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                Picker("", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("外观模式")
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("macOS 菜单栏常驻显示")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                Toggle(isOn: $fixedMenuBarWidth) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("固定菜单栏宽度 (70pt)")
                            .font(.system(size: 12, weight: .medium))
                        Text("仅显示今日消费数值，不含币种；长数字可在悬停提示中查看")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                Text("如果使用 Hidden Bar，请将 Relay 拖到右侧常驻区；Relay 会保持稳定的菜单栏身份，但第三方菜单栏工具仍可能按自己的分隔位置隐藏图标。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $showTodayInMenuBar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("常驻显示今日消耗 (若数据不全自动隐藏)")
                            .font(.system(size: 12, weight: .medium))
                        Text("严格遵循只读降级逻辑，不展示捏造数字")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("基准折算币种与低额预警")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack {
                    Text("基准币种:")
                        .font(.system(size: 12))
                    Picker("", selection: $baseCurrency) {
                        ForEach(Currency.allCases, id: \.self) { curr in
                            Text("\(curr.rawValue) (\(curr.symbol))").tag(curr)
                        }
                    }
                    .frame(width: 120)
                    .accessibilityLabel("基准折算币种")
                    Spacer()
                }

                HStack {
                    Text("当任一账号折算余额低于:")
                        .font(.system(size: 12))
                    TextField("20.00", text: $lowBalanceThreshold)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("低余额预警阈值")
                        .accessibilityHint("以基准折算币种计价")
                    Text("时，在顶栏与卡片标红预警")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Toggle("低余额系统通知", isOn: $lowBalanceNotificationsEnabled)
                .toggleStyle(.checkbox)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { setLaunchAtLogin($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录时自动启动 Relay")
                            .font(.system(size: 12, weight: .medium))
                        Text("使用 macOS 系统登录项，不保存额外凭据")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            launchAtLoginEnabled = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "无法更新登录项：\(error.localizedDescription)"
        }
    }

}
