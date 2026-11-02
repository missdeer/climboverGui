import SwiftUI

struct TemplateDownloadStatus: View {
    let variable: RemoteTemplateVariable?
    let progress: VariableDownloadProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(variable.map { "正在下载 \($0.rawValue)" } ?? "正在检查缓存…")
                Spacer()
                Button("取消下载", action: cancel)
            }
            if let total = progress.totalBytes, total > 0 {
                let fraction = min(Double(progress.receivedBytes) / Double(total), 1)
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))% · \(formattedBytes(progress.receivedBytes)) / \(formattedBytes(total))")
                    .font(.caption).monospacedDigit()
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("已下载 \(formattedBytes(progress.receivedBytes))").font(.caption).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func formattedBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
