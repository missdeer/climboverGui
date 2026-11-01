import Foundation
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func rejects(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected rejection: " + message) }
    catch { print("PASS: " + message) }
}

let original: [String: Any] = ["server": "example.com", "server_port": 443, "password": "secret", "protocol": "redir", "local_port": 59079, "mode": "tcp_and_udp", "outbound_proxy": "ss://user@example.net:443"]
let normalized = try Profile.normalize(original)
require(normalized["local_port"] as? Int == 59097, "PF port must match the runtime listener")
require(normalized["local_address"] as? String == "127.0.0.1", "Listener must stay local")
require(original["local_port"] as? Int == 59079, "Source configuration must stay unchanged")
require(normalized["outbound_proxy"] as? String == original["outbound_proxy"] as? String, "Chain proxy must survive normalization")
require(normalized["mode"] as? String == "tcp_only", "PF only redirects TCP")
let multi = try Profile.normalize(["servers": [["server": "example.com"]], "locals": [["protocol": "redir", "local_port": 1]]])
require((multi["locals"] as? [[String: Any]])?.first?["local_port"] as? Int == 59097, "Modern config must be normalized")
rejects("multiple listeners") { _ = try Profile.normalize(["server": "a", "locals": [["protocol": "redir"], ["protocol": "socks"]]]) }
rejects("SOCKS configuration") { _ = try Profile.normalize(["server": "a", "protocol": "socks"]) }
rejects("server-side configuration") { _ = try Profile.normalize(["local_port": 1, "protocol": "redir"]) }
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root.appendingPathComponent("conf"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
rejects("directory traversal") { _ = try Profile.url(root: root, relative: "../secret.conf") }
try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("conf/link.conf"), withDestinationURL: root.appendingPathComponent("outside.conf"))
rejects("dangling symlink") { _ = try Profile.url(root: root, relative: "link.conf") }
try Data("{}".utf8).write(to: root.appendingPathComponent("outside.conf"))
rejects("symlink escape") { _ = try Profile.url(root: root, relative: "link.conf") }
let quoted = "a'b $HOME `whoami` $(id)"
let result = try Command.run("/bin/sh", ["-c", "printf '%s' " + shellQuote(quoted)])
require(result.output == quoted, "Paths must be literal shell arguments")
let dead = ManagedProcess(pid: 0, identity: "anything")
require(!dead.alive, "Invalid PIDs must never count as managed processes")
let tableFile = root.appendingPathComponent("direct_cidr.txt")
try "127.0.0.0/8\n".write(to: tableFile, atomically: true, encoding: .utf8)
let rulesFile = root.appendingPathComponent("pf.conf")
try PFConfiguration.render(tableFile: tableFile).write(to: rulesFile, atomically: true, encoding: .utf8)
// Exercise the real macOS parser. -n only validates; it does not load rules or need root.
_ = try Command.run("/sbin/pfctl", ["-n", "-a", "com.apple/climbovergui-test", "-f", rulesFile.path])
print("PASS: generated PF rules accepted by native pfctl parser")
let processLog = root.appendingPathComponent("process.log")
let plugin = root.appendingPathComponent("obfs-local")
try "#!/bin/sh\nprintf 'plugin-started\\n'\n".write(to: plugin, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: plugin.path)
let pid = try DetachedProcess.launch(executable: URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "pwd; printf 'stdout'; printf 'stderr' >&2; obfs-local; /bin/sleep 0.3"], directory: root, log: processLog)
require(getsid(pid) == pid, "Background child must have its own session without a controlling terminal")
let birthIdentity = ManagedProcess.identity(pid)
require(birthIdentity.hasPrefix("birth:"), "Managed processes must use kernel birth identity")
let managedChild = ManagedProcess(pid: pid, identity: birthIdentity)
require(managedChild.alive, "Kernel identity must identify the live child")
require(!ManagedProcess(pid: pid, identity: "birth:0:0").alive, "A reused PID with another birth identity must not be managed")
var childStatus: Int32 = 0
require(waitpid(pid, &childStatus, 0) == pid && childStatus == 0, "Background child must execute successfully")
require(!managedChild.alive, "Exited processes must not remain healthy")
let output = try String(contentsOf: processLog, encoding: .utf8)
require(output.contains(root.path) && output.contains("stdoutstderr"), "Working directory and both log streams must be preserved")
require(output.contains("plugin-started"), "Plugins alongside the proxy must be discoverable by name")
print("PASS: detached session, child execution, working directory, plugin lookup, stdout/stderr logging")
print("PASS: normalization, chain preservation, source preservation, shell quoting, PID checks")
try testRecovery()
try testSwitching()
try testPFVerification()
try testServiceRequests()
try testConfigurationTemplates()
try testEditableTemplates()
try testDNSVariables()
try testRemoteVariables()
try testDirectCIDRs()
testBundledTools()
