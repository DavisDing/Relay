import SwiftUI

@MainActor
struct SettingsGeneralPage: View {
    @Binding var appearanceMode: AppearanceMode
    @Binding var fixedMenuBarWidth: Bool
    @Binding var showTodayInMenuBar: Bool
    @Binding var baseCurrency: Currency
    @Binding var lowBalanceThreshold: String
    @Binding var lowBalanceNotificationsEnabled: Bool
    let onManagePermissions: () -> Void

    var body: some View {
        SettingsPageScroll {
            SettingsSection("外观") {
                Picker("外观模式", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider().opacity(0.4)
            SettingsSection("菜单栏") {
                SettingsToggleRow(title: "固定菜单栏宽度 · 70pt",
                                  detail: "长数字可在悬停提示中查看。", isOn: $fixedMenuBarWidth)
                SettingsToggleRow(title: "显示今日消耗",
                                  detail: "仅显示消费数值；数据不全时自动隐藏。", isOn: $showTodayInMenuBar)
            }

            Divider().opacity(0.4)
            SettingsSection("折算与低余额预警") {
                HStack {
                    Text("基准币种")
                    Spacer()
                    Picker("基准折算币种", selection: $baseCurrency) {
                        ForEach(Currency.allCases, id: \.self) { currency in
                            Text("\(currency.rawValue) (\(currency.symbol))").tag(currency)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)
                }
                HStack(spacing: 8) {
                    Text("预警阈值")
                    Spacer()
                    TextField("20.00", text: $lowBalanceThreshold)
                        .relayFormField()
                        .frame(width: 76)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("低余额预警阈值")
                        .accessibilityHint("以基准折算币种计价")
                    Text(baseCurrency.rawValue).foregroundStyle(.secondary)
                }
                SettingsHint("折算余额低于阈值时，菜单栏与账户卡片标红预警。")
                SettingsToggleRow(title: "低余额系统通知", isOn: $lowBalanceNotificationsEnabled)
                SettingsActionRow {
                    Button("通知权限…", action: onManagePermissions)
                }
            }
        }
    }
}
