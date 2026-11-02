import SwiftUI

struct DirectRouteWindow: Scene {
    var domains: Bool
    @ObservedObject var model: ProxyModel

    var body: some Scene {
        Window(domains ? "额外直连域名" : "额外直连 CIDR", id: domains ? "direct-domains" : "direct-cidrs") {
            DirectRouteEditor(domains: domains, model: model)
        }
        .defaultSize(width: 540, height: 420)
    }
}

struct DirectRouteEditor: View {
    var domains = false
    @ObservedObject var model: ProxyModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    private var validationError: String? {
        do { _ = try parsedDraft(); return nil }
        catch { return error.localizedDescription }
    }

    private func parsedDraft() throws -> [String] {
        try domains ? DirectDomains.parse(draft) : DirectCIDRs.parse(draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(domains ? "额外直连域名" : "额外直连 CIDR").font(.headline)
            Text(domains ? "这些域名及其子域名解析得到的 IP 将直接连接。每行输入一个域名，例如 example.com；留空可清除额外设置。" : "这些 IPv4 网段将直接连接。每行输入一个 CIDR，例如 192.168.1.0/24；留空可清除额外设置。")
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel(domains ? "额外直连域名，每行一个" : "额外直连 IPv4 CIDR，每行一个")
                .border(Color.secondary.opacity(0.3))
                .frame(minHeight: 200)
            if let error = validationError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
            Text("保存后，在下次启动代理或切换服务器时生效。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let values = try? parsedDraft() else { return }
                    let text = values.joined(separator: "\n")
                    if domains {
                        model.additionalDomains = text
                        UserDefaults.standard.set(text, forKey: DirectDomains.preferencesKey)
                    } else {
                        model.additionalCIDRs = text
                        UserDefaults.standard.set(text, forKey: "additionalDirectCIDRs")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || validationError != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { draft = domains ? model.additionalDomains : model.additionalCIDRs }
    }
}
