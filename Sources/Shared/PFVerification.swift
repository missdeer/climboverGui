import Foundation

struct PFAnchorSnapshot {
    let rules: String
    let nat: String
    let tables: String

    func requireEmpty() throws {
        let remaining = [("过滤规则", rules), ("NAT 规则", nat), ("地址表", tables)]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.0)
        guard remaining.isEmpty else { throw ControlError("本应用 PF anchor 仍有残留：" + remaining.joined(separator: "、")) }
    }

    func requireProxyRules() throws {
        let filter = rules.split(whereSeparator: \.isNewline).map(String.init)
        let redirect = nat.split(whereSeparator: \.isNewline).map(String.init)
        let names = tables.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let outgoing = filter.contains { $0.contains("pass out route-to (lo0 127.0.0.1)") && $0.contains("to ! <direct_cidr>") && $0.contains("no state") }
        let incoming = filter.contains { $0.contains("pass in on lo0") && $0.contains("to 127.0.0.1") && $0.range(of: #"port\s+(=\s+)?59097\b"#, options: .regularExpression) != nil && $0.contains("no state") }
        guard filter.count == 2, outgoing, incoming, names == ["direct_cidr"], redirect.count == 1,
              redirect[0].contains("rdr on lo0"), redirect[0].contains("to ! <direct_cidr>"),
              redirect[0].contains("-> 127.0.0.1 port 59097") else {
            throw ControlError("PF 回读与代理规则不匹配，连接尚未确认。")
        }
    }
}

enum PFVerification {
    static func clear(flush: (String) throws -> Void, verify: () throws -> Void) throws {
        var errors: [String] = []
        for kind in ["nat", "rules", "Tables"] {
            do { try flush(kind) } catch { errors.append("\(kind)：\(error.localizedDescription)") }
        }
        do { try verify() } catch {
            throw ControlError((errors + [error.localizedDescription]).joined(separator: "\n"))
        }
        // A failed/no-op flush is harmless only when readback proves the anchor is already empty.
    }

    static func references(_ output: String) throws -> Set<UInt64> {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines == ["No pf starter references held"] { return [] }
        guard lines.first == "TOKENS:", lines.count >= 3, lines[1].contains("TOKEN"), lines[1].contains("TIMESTAMP") else {
            throw ControlError("无法确认 PF 引用列表，保留会话状态以便重试。")
        }
        var tokens = Set<UInt64>()
        for line in lines.dropFirst(2) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            // Process names may contain spaces. TOKEN precedes the final 'N days HH:MM:SS' fields.
            guard fields.count >= 6, UInt64(fields[0]) != nil,
                  UInt64(fields[fields.count - 3]) != nil, fields[fields.count - 2] == "days",
                  fields.last?.split(separator: ":").count == 3,
                  let token = UInt64(fields[fields.count - 4]) else {
                throw ControlError("无法解析 PF 引用记录，保留会话状态以便重试。")
            }
            tokens.insert(token)
        }
        return tokens
    }

    static func release(_ token: String, references: () throws -> Set<UInt64>, perform: (String) throws -> Void) throws {
        guard let value = UInt64(token) else { throw ControlError("会话的 PF 令牌格式无效。") }
        if try references().contains(value) {
            do { try perform(token) } catch {
                // Another controller may have disabled PF or already invalidated this token.
                if try references().contains(value) { throw error }
            }
        }
        guard try !references().contains(value) else { throw ControlError("本应用的 PF 启用令牌仍存在，停止尚未完成。") }
    }
}
