import Foundation

enum SwitchFailureKind { case unchanged, restored, stopped, cleanupPending }

struct SwitchFailure: LocalizedError {
    let kind: SwitchFailureKind
    let message: String
    var errorDescription: String? { message }
}

struct SwitchActions {
    var validate: () throws -> Void
    var stop: () throws -> Void
    var connect: () throws -> Void
    var restore: (() throws -> Void)?
}

enum ServerSwitch {
    static func run(previous: String?, actions: SwitchActions) throws {
        do { try actions.validate() } catch {
            throw SwitchFailure(kind: .unchanged, message: "新节点准备失败：\(error.localizedDescription)\n" +
                (previous.map { "已保留当前节点：\($0)。" } ?? "代理保持停止。"))
        }
        do { try actions.stop() } catch {
            throw SwitchFailure(kind: .cleanupPending, message: "旧会话清理未完成，未启动新节点：\(error.localizedDescription)")
        }
        do { try actions.connect(); return } catch {
            let candidateError = error.localizedDescription
            do { try actions.stop() } catch {
                throw SwitchFailure(kind: .cleanupPending, message: "新节点失败：\(candidateError)\n清理未完成，暂无法回退：\(error.localizedDescription)")
            }
            guard let previous, let restore = actions.restore else {
                throw SwitchFailure(kind: .stopped, message: "启动失败：\(candidateError)\n代理已停止，原 DNS 已恢复。")
            }
            do { try restore() } catch {
                let rollbackError = error.localizedDescription
                do { try actions.stop() } catch {
                    throw SwitchFailure(kind: .cleanupPending, message: "新节点失败：\(candidateError)\n旧节点也无法恢复：\(rollbackError)\n清理仍需重试：\(error.localizedDescription)")
                }
                throw SwitchFailure(kind: .stopped, message: "新节点失败：\(candidateError)\n旧节点也无法恢复：\(rollbackError)\n代理已停止，原 DNS 已恢复。")
            }
            throw SwitchFailure(kind: .restored, message: "新节点失败：\(candidateError)\n已自动恢复旧节点：\(previous)。")
        }
    }
}

enum ProbeConfiguration {
    static let port = 59098

    static func addingListener(to input: [String: Any], acl: URL) -> [String: Any] {
        var output = input
        var locals = (input["locals"] as? [[String: Any]] ?? []).filter {
            !($0["protocol"] as? String == "socks" && $0["local_port"] as? Int == port)
        }
        locals.append(["protocol": "socks", "local_address": "127.0.0.1", "local_port": port,
            "mode": "tcp_only", "acl": acl.path])
        output["locals"] = locals
        return output
    }
}

enum ConnectionCheck {
    static func verify(resolve: () throws -> Bool, https: (String) throws -> Bool) throws {
        var failures: [String] = []
        var dnsReady = false
        for _ in 0..<2 {
            do { if try resolve() { dnsReady = true; break } }
            catch { failures.append(error.localizedDescription) }
        }
        guard dnsReady else {
            throw ControlError("本地 DNS 检查失败：\n" + failures.joined(separator: "\n"))
        }
        failures.removeAll()
        for url in ["https://www.gstatic.com/generate_204", "https://example.com/"] {
            do { if try https(url) { return } }
            catch { failures.append(error.localizedDescription) }
        }
        throw ControlError("通过所选代理的 HTTPS 检查失败：\n" + failures.joined(separator: "\n"))
    }
}
