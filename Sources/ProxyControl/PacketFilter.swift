import Foundation

enum PacketFilter {
    static func flush(_ kind: String) throws {
        _ = try Command.run("/sbin/pfctl", ["-a", Runtime.anchor, "-F", kind])
    }

    static func snapshot() throws -> PFAnchorSnapshot {
        let rules = try Command.run("/sbin/pfctl", ["-a", Runtime.anchor, "-sr"], stdoutOnly: true).output
        let nat = try Command.run("/sbin/pfctl", ["-a", Runtime.anchor, "-sn"], stdoutOnly: true).output
        let tables = try Command.run("/sbin/pfctl", ["-a", Runtime.anchor, "-s", "Tables"], stdoutOnly: true).output
        return PFAnchorSnapshot(rules: rules, nat: nat, tables: tables)
    }

    static func verifyEmpty() throws {
        try snapshot().requireEmpty()
    }

    static func verifyActive(token: String) throws {
        try snapshot().requireProxyRules()
        let status = try Command.run("/sbin/pfctl", ["-s", "info"], stdoutOnly: true).output
        guard status.contains("Status: Enabled"), let value = UInt64(token), try references().contains(value) else {
            throw ControlError("PF 未启用或本应用的 PF 引用已丢失。")
        }
    }

    static func references() throws -> Set<UInt64> {
        try PFVerification.references(Command.run("/sbin/pfctl", ["-s", "References"], stdoutOnly: true).output)
    }

    static func release(_ token: String) throws {
        try PFVerification.release(token, references: references, perform: {
            _ = try Command.run("/sbin/pfctl", ["-X", $0])
        })
    }
}
