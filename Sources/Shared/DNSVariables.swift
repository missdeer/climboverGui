import Foundation
import Darwin

// nil keeps using the bundled list; an explicit empty string clears that variable.
struct DNSVariables: Codable, Equatable {
    var directDomains: String?
    var bogusResponses: String?
    var appleDomains: String?
    var blocklistContent: String?

    var byteCount: Int {
        [directDomains, bogusResponses, appleDomains, blocklistContent]
            .compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
    }

    func validate() throws {
        for text in [directDomains, appleDomains].compactMap({ $0 }) {
            for token in text.split(whereSeparator: { $0.isWhitespace }) {
                guard token.utf8.count <= 253, token.first != "-",
                      token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else {
                    throw ControlError("域名列表仅接受域名，每行一个或以空白分隔；不支持注释及 Corefile 指令。")
                }
            }
        }
        if let bogusResponses {
            guard bogusResponses.split(whereSeparator: { $0.isWhitespace }).allSatisfy({ isIPAddress(String($0)) }) else {
                throw ControlError("BOGUS_RESPONSES 仅接受 IP 地址，每行一个或以空白分隔。")
            }
        }
        if let blocklistContent, blocklistContent.contains("\0") {
            throw ControlError("屏蔽列表不能包含 NUL 字符。")
        }
    }
}

func isIPAddress(_ value: String) -> Bool {
    guard !value.contains("\0") else { return false }
    var v4 = in_addr()
    var v6 = in6_addr()
    return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
}
