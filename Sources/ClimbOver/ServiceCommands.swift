import Foundation
import ServiceManagement

@MainActor
func runServiceCommandIfRequested() {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first, ["--service-register", "--service-unregister", "--service-status", "--service-smoke"].contains(command) else { return }
    Task { @MainActor in
        do {
            switch command {
            case "--service-register":
                try BackgroundService.register()
                print(BackgroundService.label)
            case "--service-unregister":
                try await BackgroundService.unregister()
                print("后台服务已注销。")
            case "--service-smoke": try await runServiceSmoke(args: args)
            default:
                print(BackgroundService.label)
                if BackgroundService.instance.status == .enabled {
                    let data = try await ServiceClient.call("snapshot")
                    print(String(decoding: data, as: UTF8.self))
                }
            }
            fflush(stdout)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    RunLoop.current.run()
    exit(1)
}

@MainActor
private func runServiceSmoke(args: [String]) async throws {
    let profile = args.count > 1 ? args[1] : "huacloud/us-adv-iepl-2.conf"
    let service = args.count > 2 ? args[2] : "Wi-Fi"
    let before = try JSONDecoder().decode(ServiceSnapshot.self, from: await ServiceClient.call("snapshot"))
    guard before.status == nil && !before.legacy else { throw ControlError("请先停止已有代理再执行 XPC 测试。") }
    do {
        let connected = try JSONDecoder().decode(ServiceSnapshot.self,
            from: await ServiceClient.call("start", profile: profile, service: service))
        guard connected.status?.healthy() == true else { throw ControlError("后台未返回健康的代理状态。") }
        guard let processes = connected.status?.processes, processes.count == 2 else { throw ControlError("代理进程记录不完整。") }
        for (process, name) in zip(processes, ["sslocal", "coredns"]) {
            let path = try Command.run("/bin/ps", ["-p", String(process.pid), "-o", "comm="], stdoutOnly: true)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path
            guard path == expected else { throw ControlError("\(name) 未从当前应用包启动：\(path)") }
        }
        print("PASS: sslocal and CoreDNS execute from the installed app bundle")
        print("PASS: signed GUI -> XPC -> proxy start, DNS/HTTPS/PF verified")
        _ = try await ServiceClient.call("logs")
        print("PASS: privileged logs fetched through XPC")
        let stopped = try JSONDecoder().decode(ServiceSnapshot.self, from: await ServiceClient.call("stop"))
        guard stopped.status == nil else { throw ControlError("停止后会话仍存在。") }
        print("PASS: XPC Stop -> DNS restored, PF cleared and reference released")
    } catch {
        do { _ = try await ServiceClient.call("stop") }
        catch { FileHandle.standardError.write(Data("测试清理失败：\(error.localizedDescription)\n".utf8)) }
        throw error
    }
}
