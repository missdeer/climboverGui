import Foundation
import Darwin

enum DirectCIDRs {
    static let maximumBytes = 65_536

    static func parse(_ text: String) throws -> [String] {
        guard text.utf8.count <= maximumBytes else { throw ControlError("额外直连 CIDR 不能超过 64 KB。") }
        var result: [String] = []
        var seen = Set<String>()
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            var address = in_addr()
            guard parts.count == 2,
                  parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let prefix = Int(parts[1]), (0...32).contains(prefix),
                  String(parts[0]).withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
                throw ControlError("第 \(index + 1) 行不是有效的 IPv4 CIDR，请使用如 192.168.1.0/24 的格式。")
            }
            let normalized = "\(parts[0])/\(prefix)"
            if seen.insert(normalized).inserted { result.append(normalized) }
        }
        return result
    }

    static func render(base: [String], endpoints: [String], additional: [String]) throws -> String {
        let validated = try parse(additional.joined(separator: "\n"))
        let servers = endpoints.filter { !$0.contains(":") }.map { $0 + "/32" }
        return (["127.0.0.0/8"] + base + servers + validated).joined(separator: "\n") + "\n"
    }
}
