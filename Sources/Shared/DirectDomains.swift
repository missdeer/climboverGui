import Foundation

enum DirectDomains {
    static let maximumBytes = 65_536
    static let preferencesKey = "additionalDirectDomains"

    static func parse(_ text: String) throws -> [String] {
        guard text.utf8.count <= maximumBytes else { throw ControlError("额外直连域名不能超过 64 KB。") }
        var result: [String] = []
        var seen = Set<String>()
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            var value = line.trimmingCharacters(in: .whitespaces).lowercased()
            if value.isEmpty { continue }
            if value.hasSuffix(".") { value.removeLast() }
            let labels = value.split(separator: ".", omittingEmptySubsequences: false)
            guard value.utf8.count <= 253, !isIPAddress(value), labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }) else {
                throw ControlError("第 \(index + 1) 行不是有效域名，请每行输入一个域名，如 example.com；中文域名请使用 Punycode。")
            }
            if seen.insert(value).inserted { result.append(value) }
        }
        return result
    }
}
