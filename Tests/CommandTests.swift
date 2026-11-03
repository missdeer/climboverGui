import Foundation
import Darwin

func testCommandResources() throws {
    func descriptorCount() -> Int {
        (0..<getdtablesize()).reduce(0) { $0 + (fcntl($1, F_GETFD) == -1 ? 0 : 1) }
    }

    // Warm up Foundation's process machinery, then mimic the watchdog's long-running loop
    // without draining an autorelease pool between commands.
    _ = try Command.run("/bin/sh", ["-c", "printf ready"], stdoutOnly: true)
    let before = descriptorCount()
    for _ in 0..<32 {
        let merged = try Command.run("/bin/sh", ["-c", "printf out; printf err >&2"])
        require(merged.output == "outerr", "Merged command output must survive pipe cleanup")
        let separated = try Command.run("/bin/sh", ["-c", "printf out; printf err >&2; exit 7"], checked: false, stdoutOnly: true)
        require(separated.output == "out" && separated.status == 7, "Unchecked commands must preserve stdout and exit status")
        do {
            _ = try Command.run("/bin/sh", ["-c", "printf diagnostic >&2; exit 7"], stdoutOnly: true)
            fatalError("Expected nonzero command rejection")
        } catch {
            require(error.localizedDescription.contains("diagnostic"), "Checked failures must preserve stderr")
        }
        do {
            _ = try Command.run("/nonexistent-climbover-test/command", [], stdoutOnly: true)
            fatalError("Expected process launch rejection")
        } catch { }
    }
    let after = descriptorCount()
    require(after <= before + 2, "Command pipe descriptors must not accumulate: before=\(before), after=\(after)")
    print("PASS: command descriptors remain bounded across successful, failed and rejected launches (\(before) -> \(after))")
}
