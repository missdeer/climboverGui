import SwiftUI
import AppKit
import Combine
import ServiceManagement

@MainActor
final class ProxyModel: ObservableObject {
    @Published var profiles: [String] = []
    @Published var selected: String {
        didSet { UserDefaults.standard.set(selected, forKey: "profile") }
    }
    @Published var service: String {
        didSet { UserDefaults.standard.set(service, forKey: "service") }
    }
    @Published var services: [String] = []
    @Published var additionalCIDRs: String = UserDefaults.standard.string(forKey: "additionalDirectCIDRs") ?? ""
    @Published var status: PublicStatus?
    @Published var busy = false
    @Published var error: String?
    @Published var legacy = false
    @Published var logs = ""
    @Published var unhealthy = false
    @Published var recoveryNotice: String?
    @Published var backgroundLabel = BackgroundService.label
    @Published var backendReady = false
    private var refreshing = false
    private var timer: Timer?
    let root: URL

    init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "ClimbOverRoot") as? String ?? ""
        root = URL(fileURLWithPath: configured)
        selected = UserDefaults.standard.string(forKey: "profile") ?? "huacloud/us-adv-iepl-2.conf"
        service = UserDefaults.standard.string(forKey: "service") ?? ""
        reloadProfiles()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

    }

    var label: String {
        if busy { return "正在处理…" }
        if legacy { return "脚本代理运行中" }
        if status != nil { return unhealthy ? "代理异常" : "代理已开启" }
        if recoveryNotice != nil { return "代理已自动停止" }
        return "代理已停止"
    }

    var artworkState: ClimbOverArtwork.State {
        if busy { return .working }
        if legacy { return .external }
        if status != nil { return unhealthy ? .warning : .connected }
        return recoveryNotice == nil ? .stopped : .warning
    }

    var statusImage: NSImage {
        ClimbOverArtwork.menuImage(state: artworkState)
    }

    var profileChoices: [String] {
        guard let status, status.ready, !profiles.contains(status.profile) else { return profiles }
        // A restored runtime snapshot may outlive its original configuration file.
        return profiles + [status.profile]
    }

    func reloadProfiles() {
        profiles = Profile.names(root: root)
        if !profiles.contains(selected) { selected = profiles.first ?? "" }
    }

    func apply(_ snapshot: ServiceSnapshot) {
        status = snapshot.status
        services = snapshot.services
        legacy = snapshot.legacy
        unhealthy = status.map { !$0.healthy() } ?? false
        if let status, status.ready { selected = status.profile }
        recoveryNotice = snapshot.recovery.map { "\($0.date.formatted(date: .omitted, time: .shortened)) · \($0.message)" }
    }

    func refresh() {
        backgroundLabel = BackgroundService.label
        guard !busy, !refreshing else { return }
        backendReady = BackgroundService.instance.status == .enabled
        guard backendReady else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                let data = try await ServiceClient.call("snapshot")
                apply(try JSONDecoder().decode(ServiceSnapshot.self, from: data))
            } catch {
                backgroundLabel = "后台暂不可用：\(error.localizedDescription)"
                unhealthy = status != nil
            }
        }
    }

    func manageService(_ operation: String) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false; refresh() }
            do {
                if operation == "register" { try BackgroundService.register() }
                else {
                    try await BackgroundService.unregister()
                    status = nil
                    backendReady = false
                    if operation == "update" { try BackgroundService.register() }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func select(_ value: String) {
        guard !busy, value != selected else { return }
        selected = value
        if status != nil { operate(start: true) }
    }

    private func requestOperation(start: Bool) async throws -> Data {
        try await ServiceClient.call(start ? "start" : "stop", profile: start ? selected : "", service: start ? service : "",
            additionalCIDRs: start ? additionalCIDRs : "")
    }

    func operate(start: Bool, quit: Bool = false) {
        guard !busy else { return }
        busy = true
        error = nil
        let switching = start && status != nil
        Task {
            do {
                guard BackgroundService.instance.status == .enabled else { throw ControlError("请先启用并批准后台服务。") }
                let data = try await requestOperation(start: start)
                apply(try JSONDecoder().decode(ServiceSnapshot.self, from: data))
                busy = false
                refresh()
                if quit { NSApplication.shared.terminate(nil) }
            } catch {
                self.error = error.localizedDescription
                UserDefaults.standard.set(error.localizedDescription, forKey: "lastOperationError")
                busy = false
                refresh()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = switching ? "服务器切换失败" : (start ? "启动代理失败" : "停止代理失败")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    func quit() {
        if status != nil { operate(start: false, quit: true) }
        else { NSApplication.shared.terminate(nil) }
    }

    func readLogs() {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let data = try await ServiceClient.call("logs")
                logs = String(decoding: data, as: UTF8.self)
            } catch { logs = error.localizedDescription }
            busy = false
            refresh()
        }
    }
}

private struct MenuBarStatusIcon: View {
    let state: ClimbOverArtwork.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = 0

    private var animates: Bool { state == .connected && !reduceMotion }

    var body: some View {
        Image(nsImage: animates ? ClimbOverArtwork.connectedMenuFrames[frame] : ClimbOverArtwork.menuImage(state: state))
            .task(id: animates) {
                frame = 0
                guard animates else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 150_000_000) }
                    catch { return } // State changes and view removal cancel the animation.
                    guard !Task.isCancelled else { return }
                    frame = (frame + 1) % ClimbOverArtwork.connectedMenuFrames.count
                }
            }
    }
}

struct ControlPanel: View {
    @ObservedObject var model: ProxyModel
    @Environment(\.openWindow) private var openWindow

    var tint: Color {
        if model.busy || model.legacy { return .secondary }
        if model.status != nil { return model.unhealthy ? .orange : .green }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: model.statusImage).renderingMode(.template)
                    .resizable().frame(width: 27, height: 25).foregroundStyle(tint)
                    .accessibilityLabel(model.label)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ClimbOver").font(.headline)
                    Text(model.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("服务器", selection: Binding(get: { model.selected }, set: model.select)) {
                    if model.profileChoices.isEmpty { Text("没有可用配置").tag("") }
                    ForEach(model.profileChoices, id: \.self) { name in
                        Text(name.replacingOccurrences(of: ".conf", with: "").replacingOccurrences(of: ".json", with: ""))
                            .tag(name)
                    }
                }
                .disabled(model.busy || model.legacy)
                Picker("网络", selection: $model.service) {
                    Text("自动 · 默认网络").tag("")
                    ForEach(model.services, id: \.self) { Text($0).tag($0) }
                }
                .disabled(model.busy || model.status != nil)
            }
            .controlSize(.regular)

            if model.legacy {
                Text("请先在终端执行 sudo ./stop.sh 停止脚本代理，再使用此应用。")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let status = model.status {
                Text("当前：\(status.profile) · \(status.service)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if model.unhealthy {
                    Text("代理或监控未就绪。可停止代理恢复网络，或查看日志。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let error = model.error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 110)
            }
            if let notice = model.recoveryNotice {
                Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !model.backendReady {
                Text(model.backgroundLabel).font(.caption).foregroundStyle(.secondary)
                Button("启用后台服务…") { model.manageService("register") }
                    .disabled(model.busy)
            }
            Button {
                model.operate(start: model.status == nil)
            } label: {
                Text(model.status == nil ? "启动代理" : "停止代理")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || !model.backendReady || model.legacy || (model.status == nil && model.selected.isEmpty))

            Divider()
            HStack {
                Menu {
                    Button("额外直连 CIDR…") { openWindow(id: "direct-cidrs"); NSApp.activate(ignoringOtherApps: true) }
                    Button("查看日志…") { model.readLogs(); openWindow(id: "logs"); NSApp.activate(ignoringOtherApps: true) }
                    Button("后台服务设置…") { SMAppService.openSystemSettingsLoginItems() }
                    Button("重新注册后台服务…") { model.manageService("update") }
                    Button("停用后台服务") { model.manageService("unregister") }
                    Divider()
                    Button("刷新服务器列表") { model.reloadProfiles() }
                    Button("打开配置文件夹") { NSWorkspace.shared.open(model.root.appendingPathComponent("conf")) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("更多操作")
                Spacer()
                Button(model.status == nil ? "退出" : "停止并退出") { model.quit() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .disabled(model.busy)
            .font(.caption)
        }
        .padding(20)
        .frame(width: 330)
    }
}

struct DirectCIDREditor: View {
    @ObservedObject var model: ProxyModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    private var validationError: String? {
        do { _ = try DirectCIDRs.parse(draft); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("额外直连 CIDR").font(.headline)
            Text("这些 IPv4 网段将直接连接。每行输入一个 CIDR，例如 192.168.1.0/24；留空可清除额外设置。")
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("额外直连 IPv4 CIDR，每行一个")
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
                    guard let values = try? DirectCIDRs.parse(draft) else { return }
                    model.additionalCIDRs = values.joined(separator: "\n")
                    UserDefaults.standard.set(model.additionalCIDRs, forKey: "additionalDirectCIDRs")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || validationError != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { draft = model.additionalCIDRs }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ProxyModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Explicit Quit routes through stop. External Quit gets the same restoration behavior.
        guard let model else { return .terminateNow }
        if model.busy { return .terminateCancel }
        if model.status != nil { model.operate(start: false, quit: true); return .terminateCancel }
        return .terminateNow
    }
}

@main
struct ClimbOverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ProxyModel()

    init() {
        runServiceCommandIfRequested()
        if let position = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > position + 1 {
            let previewModel = ProxyModel()
            let view = NSHostingView(rootView: ControlPanel(model: previewModel)
                .background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
            view.frame.size = view.fittingSize
            let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[position + 1]))
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: model).onAppear { delegate.model = model; model.refresh() }
        } label: {
            Label {
                Text(model.label)
            } icon: {
                MenuBarStatusIcon(state: model.artworkState)
            }
        }
        .menuBarExtraStyle(.window)

        Window("额外直连 CIDR", id: "direct-cidrs") {
            DirectCIDREditor(model: model)
        }
        .defaultSize(width: 540, height: 420)

        Window("ClimbOver 日志", id: "logs") {
            VStack(alignment: .leading) {
                HStack {
                    Text("代理日志").font(.headline)
                    Spacer()
                    Button("刷新") { model.readLogs() }.disabled(model.busy)
                }
                ScrollView {
                    Text(model.logs.isEmpty ? "正在读取日志…" : model.logs)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).frame(minWidth: 600, minHeight: 350)
        }
        .defaultSize(width: 760, height: 500)
    }
}
