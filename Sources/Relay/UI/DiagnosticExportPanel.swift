import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct DiagnosticExportPanel: View {
    @ObservedObject var store: RelayStore
    @State private var preview: Data?
    @State private var message: String?
    var body: some View {
        SettingsSection("脱敏诊断") {
            Text("仅导出版本、状态分类、数量和耗时；不含账号、站点、路径、凭据或原始错误，不自动上传。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            SettingsActionRow {
                Button("预览诊断…") {
                    do { preview = try store.diagnosticReport().encoded(); message = nil }
                    catch { message = "诊断生成失败。" }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("诊断导出预览").font(.headline)
                ScrollView {
                    Text(String(decoding: preview ?? Data(), as: UTF8.self))
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                SettingsActionRow {
                    Button("取消") { preview = nil }
                    Button("保存 JSON…") { save() }.buttonStyle(RelayPrimaryCapsuleButtonStyle())
                }
            }.padding(20).frame(width: 420, height: 390).relayInitialFocus()
        }
    }
    private func save() {
        guard let preview else { return }
        let picker = NSSavePanel(); picker.allowedContentTypes = [.json]; picker.nameFieldStringValue = "Relay-diagnostics.json"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do { try preview.write(to: url, options: .atomic); self.preview = nil; message = "诊断已保存。" }
        catch { message = "诊断保存失败，请检查目标目录。" }
    }
}
