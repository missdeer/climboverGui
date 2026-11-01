import SwiftUI

struct ConfigurationTemplateEditor: View {
    @ObservedObject var model: ProxyModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = EditableTemplates()
    @State private var section = ConfigurationTemplateSection.sslocal
    @State private var saveError: String?
    @State private var confirmDiscard = false
    @State private var downloading = false
    @State private var cache: DownloadedTemplateVariable?

    private var validationError: String? {
        do { _ = try draft.encoded(); return nil }
        catch { return error.localizedDescription }
    }

    private var changed: Bool {
        draft != (try? EditableTemplates.decode(model.templatesJSON))
    }

    private var editorText: Binding<String> {
        Binding(get: { section.text(in: draft) }, set: {
            section.update($0, in: &draft)
            saveError = nil
            reloadCache()
        })
    }

    private func reloadCache() {
        guard let variable = section.variable else { cache = nil; return }
        cache = try? RemoteTemplateVariables.cached(variable, source: section.text(in: draft))
    }

    private func refreshCache() {
        guard let variable = section.variable else { return }
        downloading = true
        saveError = nil
        let source = section.text(in: draft)
        Task { @MainActor in
            defer { downloading = false }
            do { cache = try await RemoteTemplateVariables.download(variable, source: source) }
            catch { saveError = error.localizedDescription }
        }
    }

    private func save() {
        downloading = true
        saveError = nil
        Task { @MainActor in
            defer { downloading = false }
            do {
                // Fetch new URLs before saving, so the saved settings also work offline.
                _ = try await RemoteTemplateVariables.resolve(draft)
                let text = try draft.encoded()
                UserDefaults.standard.set(text, forKey: EditableTemplates.preferencesKey)
                model.templatesJSON = text
                dismiss()
            } catch { saveError = error.localizedDescription; reloadCache() }
        }
    }

    private var sourceEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("https://example.com/list.txt", text: editorText)
                    .textFieldStyle(.roundedBorder).disableAutocorrection(true)
                    .accessibilityLabel("\(section.rawValue) 下载 URL")
                Button(cache == nil ? "下载并缓存" : "重新下载并刷新缓存") { refreshCache() }
                    .disabled(section.text(in: draft).isEmpty)
            }
            if let cache {
                Text("缓存更新：\(cache.downloadedAt.formatted()) · \(cache.content.utf8.count.formatted()) 字节")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    Text(String(cache.content.prefix(12_000)))
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 220)
                if cache.content.count > 12_000 { Text("仅预览前 12,000 个字符，运行时使用完整缓存。").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(section.text(in: draft).isEmpty ? "当前使用默认内容。" : "尚无此 URL 的缓存；保存时会自动下载。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("编辑内容", selection: $section) {
                ForEach(ConfigurationTemplateSection.allCases) { item in Text(item.rawValue).tag(item) }
            }
            Text(section.help).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if section.variable != nil { sourceEditor }
            else {
                TextEditor(text: editorText)
                    .font(.system(.body, design: .monospaced)).disableAutocorrection(true)
                    .accessibilityLabel(section.rawValue).border(Color.secondary.opacity(0.3))
                    .frame(minHeight: 280).id(section)
            }
            if let error = saveError ?? validationError {
                ScrollView {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 70)
            }
            Text("保存后，在下次启动或切换服务器时使用缓存；下载失败会保留已有缓存。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("恢复当前项默认值") { section.update(section.defaultText, in: &draft); saveError = nil; reloadCache() }
                Spacer()
                if downloading { ProgressView().controlSize(.small) }
                Button("取消") { if changed { confirmDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(model.busy || validationError != nil || !changed)
            }
        }
        .padding(20).frame(minWidth: 640, minHeight: 520)
        .disabled(downloading)
        .onAppear {
            do { draft = try EditableTemplates.decode(model.templatesJSON); reloadCache() }
            catch { saveError = error.localizedDescription }
        }
        .onChange(of: section) { _ in saveError = nil; reloadCache() }
        .confirmationDialog("放弃未保存的模板更改？", isPresented: $confirmDiscard) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
    }
}
