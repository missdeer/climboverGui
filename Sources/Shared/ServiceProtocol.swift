import Foundation

enum ServiceIdentity {
    static let name = "com.dfordsoft.climbover.daemon"
    static let plist = name + ".plist"
    static let appID = "com.dfordsoft.climbover.gui"

    static func requirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(BuildSettings.teamID)\""
    }
}

@objc protocol ProxyServiceProtocol {
    func perform(_ operation: String, profile: String, service: String, additionalCIDRs: String, reply: @escaping (Data?, String?) -> Void)
}

struct ServiceSnapshot: Codable {
    var status: PublicStatus?
    var recovery: RecoveryEvent?
    var services: [String]
    var legacy: Bool
}

enum ServiceRequest {
    static func validate(_ operation: String, profile: String, service: String, additionalCIDRs: String = "") throws {
        guard ["start", "stop", "snapshot", "logs", "prepareUpdate"].contains(operation),
              profile.utf8.count <= 1024, service.utf8.count <= 256,
              !profile.contains("\0"), !service.contains("\0"),
              !profile.contains("\n"), !service.contains("\n") else { throw ControlError("无效的后台请求。") }
        _ = try DirectCIDRs.parse(additionalCIDRs)
        if operation == "start" {
            guard !profile.isEmpty, !profile.hasPrefix("/"), !profile.split(separator: "/").contains(".."),
                  ["conf", "json"].contains(URL(fileURLWithPath: profile).pathExtension) else {
                throw ControlError("配置必须是 conf 目录中的相对路径。")
            }
        }
    }
}
