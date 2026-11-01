import Foundation
import CryptoKit

enum RemoteTemplateVariable: String, CaseIterable, Identifiable {
    case directDomains = "DIRECT_DOMAINS"
    case bogusResponses = "BOGUS_RESPONSES"
    case appleDomains = "APPLE_DOMAINS"
    case blocklistFile = "BLOCKLIST_FILE"

    var id: String { rawValue }

    var contentKey: WritableKeyPath<DNSVariables, String?> {
        switch self {
        case .directDomains: return \.directDomains
        case .bogusResponses: return \.bogusResponses
        case .appleDomains: return \.appleDomains
        case .blocklistFile: return \.blocklistContent
        }
    }

    func validatedContent(_ text: String) throws -> String {
        // Plain domain/IP lists commonly include blank lines and # comments.
        let content = self == .blocklistFile ? text : text.components(separatedBy: .newlines)
            .map { String($0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]) }
            .joined(separator: "\n")
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlError("下载的 \(rawValue) 内容为空。")
        }
        var variables = DNSVariables()
        variables[keyPath: contentKey] = content
        try variables.validate()
        return content
    }
}

struct DownloadedTemplateVariable: Codable, Equatable {
    let url: String
    let content: String
    let downloadedAt: Date
}

enum RemoteTemplateVariables {
    static let maximumDownloadBytes = 16 * 1024 * 1024
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClimbOver/TemplateCache", isDirectory: true)
    }

    static func sourceURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, !text.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
            throw ControlError("变量下载地址必须是有效的 HTTP 或 HTTPS URL。")
        }
        return url
    }

    static func validateURLs(_ sources: [String: String]) throws {
        for (key, source) in sources {
            guard RemoteTemplateVariable(rawValue: key) != nil else { throw ControlError("未知的模板变量：\(key)") }
            if !source.isEmpty { _ = try sourceURL(source) }
        }
    }

    private static func cacheFile(_ variable: RemoteTemplateVariable, source: String, directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(variable.rawValue)-\(digest).json")
    }

    static func cached(_ variable: RemoteTemplateVariable, source: String, directory: URL = cacheDirectory) throws -> DownloadedTemplateVariable? {
        let file = cacheFile(variable, source: source, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let cache = try JSONDecoder().decode(DownloadedTemplateVariable.self, from: Data(contentsOf: file))
        guard cache.url == source, cache.content.utf8.count <= maximumDownloadBytes else {
            throw ControlError("变量缓存无效，请重新下载。")
        }
        _ = try variable.validatedContent(cache.content)
        return cache
    }

    static func download(_ variable: RemoteTemplateVariable, source: String, directory: URL = cacheDirectory,
                         session: URLSession = .shared) async throws -> DownloadedTemplateVariable {
        var request = URLRequest(url: try sourceURL(source), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw ControlError("下载 \(variable.rawValue) 失败，HTTP 状态：\((response as? HTTPURLResponse)?.statusCode ?? 0)。")
        }
        _ = try sourceURL(response.url?.absoluteString ?? "")
        guard data.count <= maximumDownloadBytes else { throw ControlError("单份变量内容不能超过 16 MB。") }
        guard let text = String(data: data, encoding: .utf8) else { throw ControlError("下载内容必须是 UTF-8 文本。") }
        let cleaned = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        let content = try variable.validatedContent(cleaned)
        let cache = DownloadedTemplateVariable(url: source, content: content, downloadedAt: Date())
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(cache).write(to: cacheFile(variable, source: source, directory: directory), options: .atomic)
        return cache
    }

    static func resolve(_ templates: EditableTemplates, directory: URL = cacheDirectory, session: URLSession = .shared) async throws -> EditableTemplates {
        try templates.validate()
        var result = templates
        var variables = templates.dnsVariables ?? DNSVariables()
        for variable in RemoteTemplateVariable.allCases {
            guard let source = templates.variableURLs?[variable.rawValue], !source.isEmpty else { continue }
            let content: String
            if let cache = try? cached(variable, source: source, directory: directory) { content = cache.content }
            else { content = try await download(variable, source: source, directory: directory, session: session).content }
            variables[keyPath: variable.contentKey] = content
        }
        result.dnsVariables = variables == DNSVariables() ? nil : variables
        _ = try result.encoded()
        return result
    }
}
