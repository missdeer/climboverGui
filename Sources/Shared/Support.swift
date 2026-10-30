import Foundation
import Darwin

struct ControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct CommandResult {
    let status: Int32
    let output: String
}

private final class CommandCapture: @unchecked Sendable {
    // One background writer; the caller reads only after its DispatchGroup has completed.
    var data = Data()
}

enum Command {
    // Read while the process runs: CoreDNS/PF output must never fill a pipe and deadlock.
    static func run(_ path: String, _ arguments: [String], checked: Bool = true, stdoutOnly: Bool = false) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LANG": "en_US.UTF-8"]
        let pipe = Pipe()
        let errorPipe = stdoutOnly ? Pipe() : nil
        process.standardOutput = pipe
        process.standardError = errorPipe ?? pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let errors = CommandCapture()
        let drained = DispatchGroup()
        if let errorPipe {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                errors.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                drained.leave()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        drained.wait()
        let result = CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        if checked && result.status != 0 {
            let details = result.output + String(decoding: errors.data, as: UTF8.self)
            throw ControlError("\(URL(fileURLWithPath: path).lastPathComponent) 执行失败：\(details.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result
    }
}

enum DetachedProcess {
    static func launch(executable: URL, arguments: [String], directory: URL, log: URL) throws -> Int32 {
        func check(_ status: Int32) throws {
            if status != 0 { throw ControlError("创建代理进程失败：\(String(cString: strerror(status)))") }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session survives the authorization shell. No controlling terminal is required.
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        if #available(macOS 26.0, *) {
            try check(posix_spawn_file_actions_addchdir(&actions, directory.path))
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600))
        try check(posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO))
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let environment = ["PATH=\(directory.path):/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LANG=en_US.UTF-8"]
        var envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp))
        return pid
    }
}

enum ExecutableLocation {
    static func current() throws -> URL {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else {
            throw ControlError("无法定位后台可执行文件。")
        }
        return URL(fileURLWithPath: String(cString: buffer))
    }
}

enum Profile {
    static func url(root: URL, relative: String) throws -> URL {
        let directory = root.appendingPathComponent("conf").resolvingSymlinksInPath()
        let file = directory.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.path + "/"), ["conf", "json"].contains(file.pathExtension) else {
            throw ControlError("配置文件必须位于项目 conf 目录内。")
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ControlError("配置文件不存在或符号链接目标无效。")
        }
        return file
    }

    static func read(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ControlError("不是有效的 JSON 客户端配置。")
        }
        return try normalize(object)
    }

    static func normalize(_ input: [String: Any]) throws -> [String: Any] {
        var object = input
        guard let listener = try JSONSerialization.jsonObject(with: Data(ConfigurationTemplates.sslocal.utf8)) as? [String: Any] else {
            throw ControlError("内置 sslocal 模板无效。")
        }
        let servers = object["servers"] as? [[String: Any]]
        guard object["server"] is String || servers?.isEmpty == false else {
            throw ControlError("配置缺少代理服务器。")
        }
        if let locals = object["locals"] as? [[String: Any]] {
            guard locals.count == 1, locals[0]["protocol"] as? String == "redir" else {
                throw ControlError("仅支持一个 redir 本地监听的客户端配置。")
            }
            var local = locals[0]
            local.merge(listener) { _, template in template }
            object["locals"] = [local]
        } else {
            guard object["protocol"] as? String == "redir" else {
                throw ControlError("仅支持 redir 透明代理配置。")
            }
            object.merge(listener) { _, template in template }
        }
        object["mode"] = listener["mode"]
        return object
    }

    static func names(root: URL) -> [String] {
        let directory = root.appendingPathComponent("conf")
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { item -> String? in
            guard let url = item as? URL, ["conf", "json"].contains(url.pathExtension) else { return nil }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            guard let checked = try? Self.url(root: root, relative: relative), (try? read(checked)) != nil else { return nil }
            return relative
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct ManagedProcess: Codable {
    let pid: Int32
    let identity: String

    static func identity(_ pid: Int32) -> String {
        guard pid > 1 else { return "" }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != UInt32(SZOMB) else { return "" }
        // Kernel birth time survives exec and distinguishes PID reuse down to microseconds.
        return "birth:\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    var alive: Bool {
        if identity.hasPrefix("birth:") { return Self.identity(pid) == identity }
        // Compatibility with sessions recorded by the previous version.
        guard pid > 1, !identity.isEmpty else { return false }
        return (try? Command.run("/bin/ps", ["-p", String(pid), "-o", "lstart=,comm="], checked: false).output
            .trimmingCharacters(in: .whitespacesAndNewlines)) == identity
    }
}

struct SessionState: Codable {
    var profile: String
    var service: String
    var originalDNS: [String]
    var processes: [ManagedProcess] = []
    var pfToken: String? = nil
    var dnsChanged = false
    // Optional for compatibility with a session created by the previous app version.
    var sessionID: String? = nil
    var owner: ManagedProcess? = nil
    var watchdog: ManagedProcess? = nil
    var phase: SessionPhase? = nil
    var recoveryReason: String? = nil
    var companions: [ManagedProcess]? = nil
    var additionalCIDRs: [String]? = nil
}

enum SessionPhase: String, Codable { case starting, ready, recovering }

enum Runtime {
    static let directory = URL(fileURLWithPath: "/var/run/climbover-gui")
    static let state = directory.appendingPathComponent("state.json")
    static let summary = directory.appendingPathComponent("summary.json")
    static let event = directory.appendingPathComponent("recovery.json")
    static let legacyToken = "/var/run/climbover-pf.token"
    static let anchor = "com.apple/climbovergui"
}

struct PublicStatus: Codable {
    var profile: String
    var service: String
    var processes: [ManagedProcess]
    var ready: Bool
    var watchdog: ManagedProcess? = nil
    var lastChecked: Date? = nil

    func healthy(at now: Date = Date()) -> Bool {
        guard ready, processes.count == 2, watchdog != nil, let lastChecked else { return false }
        return abs(now.timeIntervalSince(lastChecked)) < 12
    }
}

struct RecoveryEvent: Codable {
    let date: Date
    let message: String
    let completed: Bool
}

func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
