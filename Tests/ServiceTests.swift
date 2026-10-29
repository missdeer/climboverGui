import Foundation

func testServiceRequests() throws {
    for operation in ["snapshot", "logs", "stop", "prepareUpdate"] {
        try ServiceRequest.validate(operation, profile: "", service: "")
    }
    try ServiceRequest.validate("start", profile: "huacloud/us-adv-iepl-2.conf", service: "Wi-Fi")
    rejects("XPC arbitrary operation") { try ServiceRequest.validate("exec", profile: "", service: "") }
    rejects("XPC absolute configuration") { try ServiceRequest.validate("start", profile: "/tmp/node.conf", service: "Wi-Fi") }
    rejects("XPC path traversal") { try ServiceRequest.validate("start", profile: "../node.conf", service: "Wi-Fi") }
    rejects("XPC unbounded request") { try ServiceRequest.validate("start", profile: String(repeating: "a", count: 1025), service: "Wi-Fi") }
    rejects("XPC embedded NUL") { try ServiceRequest.validate("start", profile: "node.conf", service: "Wi-Fi\0") }
    rejects("XPC unsupported file type") { try ServiceRequest.validate("start", profile: "node.sh", service: "Wi-Fi") }
    let requirement = ServiceIdentity.requirement(identifier: ServiceIdentity.appID)
    require(requirement.contains("anchor apple generic") && requirement.contains(BuildSettings.teamID) && requirement.contains(ServiceIdentity.appID),
        "XPC peer requirement must pin Apple signing chain, Team ID and exact app identifier")
    let path = try ExecutableLocation.current()
    require(path.lastPathComponent == "ControlTests", "Executable discovery must work independently of argv[0]")
    print("PASS: XPC request limits, fixed commands, paths and peer requirements")
}
