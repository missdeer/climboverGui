import Foundation
import ServiceManagement

private final class PendingServiceReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    let connection: NSXPCConnection

    init(connection: NSXPCConnection, continuation: CheckedContinuation<Data, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        pending.resume(with: result)
    }
}

enum ServiceClient {
    static func call(_ operation: String, profile: String = "", service: String = "", additionalCIDRs: String = "") async throws -> Data {
        try ServiceRequest.validate(operation, profile: profile, service: service, additionalCIDRs: additionalCIDRs)
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: ServiceIdentity.name, options: .privileged)
            connection.setCodeSigningRequirement(ServiceIdentity.requirement(identifier: ServiceIdentity.name))
            connection.remoteObjectInterface = NSXPCInterface(with: ProxyServiceProtocol.self)
            let pending = PendingServiceReply(connection: connection, continuation: continuation)
            connection.interruptionHandler = { pending.finish(.failure(ControlError("后台连接中断。请刷新状态后重试。"))) }
            connection.invalidationHandler = { pending.finish(.failure(ControlError("无法连接后台服务，请确认已在系统设置中允许 ClimbOver。"))) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { pending.finish(.failure($0)) } as? ProxyServiceProtocol
            guard let proxy else { pending.finish(.failure(ControlError("后台接口不可用。"))); return }
            proxy.perform(operation, profile: profile, service: service, additionalCIDRs: additionalCIDRs) { data, message in
                if let message { pending.finish(.failure(ControlError(message))) }
                else if let data { pending.finish(.success(data)) }
                else { pending.finish(.failure(ControlError("后台没有返回结果。"))) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + (operation == "snapshot" ? 8 : 150)) {
                pending.finish(.failure(ControlError("后台操作超时。操作可能仍在执行，请先刷新状态。")))
            }
        }
    }
}

@MainActor
enum BackgroundService {
    static var instance: SMAppService { SMAppService.daemon(plistName: ServiceIdentity.plist) }

    static var label: String {
        switch instance.status {
        case .enabled: return "后台服务已启用"
        case .requiresApproval: return "请在系统设置中允许后台服务"
        case .notRegistered: return "尚未启用后台服务"
        case .notFound: return "后台服务文件缺失，请重新构建"
        @unknown default: return "后台服务状态未知"
        }
    }

    static func register() throws {
        guard Bundle.main.bundlePath == "/Applications/ClimbOver.app" else {
            throw ControlError("请先运行 install.sh，将已签名的 ClimbOver.app 安装到 /Applications 后再启用后台服务。")
        }
        if instance.status != .enabled && instance.status != .requiresApproval {
            do { try instance.register() } catch {
                // macOS may return EPERM while successfully recording a pending approval.
                guard instance.status == .requiresApproval else { throw error }
            }
        }
        if instance.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    static func unregister() async throws {
        // Cleanup must be confirmed before macOS is asked to unload the root daemon.
        if instance.status == .enabled { _ = try await ServiceClient.call("prepareUpdate") }
        try await instance.unregister()
    }
}
