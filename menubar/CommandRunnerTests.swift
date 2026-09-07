import Foundation

@main
struct CommandRunnerTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("verbose.log")
        let result = await CommandRunner.run(executable: "/bin/bash", arguments: ["-c", "head -c 4194304 /dev/zero; printf 'stderr-finish' >&2; exit 7"], logURL: log)
        precondition(result.1 == 7, "Must preserve child failure")
        precondition(result.0.hasSuffix("stderr-finish"), "Must capture stderr after verbose output")
        precondition(result.0.utf8.count <= 65536, "Tail must stay bounded")
        let size = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as! NSNumber
        precondition(size.intValue > 4194304, "Full output must be retained")
        let literal = "space ' quote $HOME $(not-a-command)"
        let args = await CommandRunner.run(executable: "/usr/bin/printf", arguments: ["%s", literal], logURL: root.appendingPathComponent("args.log"))
        precondition(args.1 == 0 && args.0 == literal, "Arguments must remain literal")
        let absent = await CommandRunner.run(executable: "/missing/menubar-test", arguments: [], logURL: root.appendingPathComponent("absent.log"))
        precondition(absent.1 == 127, "Missing executable must fail")
        let expectedHome = ProcessInfo.processInfo.environment["HOME"]!
        let inherited = await CommandRunner.run(executable: "/bin/bash", arguments: ["-uc", "printf '%s' \"$HOME\""], logURL: root.appendingPathComponent("inherited.log"))
        precondition(inherited.1 == 0 && inherited.0 == expectedHome, "Default environment must inherit HOME for discovery")
        let explicit = await CommandRunner.run(executable: "/bin/bash", arguments: ["-uc", "printf '%s' \"$HOME\""], environment: ["HOME": "/fixture-home"], logURL: root.appendingPathComponent("explicit.log"))
        precondition(explicit.1 == 0 && explicit.0 == "/fixture-home", "Explicit environment must still take precedence")
        let directory = root.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let discovery = directory.appendingPathComponent("discovery.log")
        try Data("[]".utf8).write(to: discovery)
        precondition(RunLogHistory.load(in: directory).latest == nil, "Discovery must not masquerade as an operation")
        let buildLog = directory.appendingPathComponent("build.log")
        try Data("build".utf8).write(to: buildLog)
        precondition(URL(fileURLWithPath: RunLogHistory.load(in: directory).latest!).resolvingSymlinksInPath() == buildLog.resolvingSymlinksInPath(), "Existing operation logs must be recovered")
        try RunLogHistory.record(log: buildLog, plugin: "dsh-files")
        let reloadLog = directory.appendingPathComponent("reload.log")
        try Data("reload".utf8).write(to: reloadLog)
        try RunLogHistory.record(log: reloadLog)
        let history = RunLogHistory.load(in: directory)
        precondition(history.latest == reloadLog.path && history.plugins["dsh-files"] == buildLog.path,
                     "A reload must not overwrite the plugin's build log")
        print("PASS: 4 MiB output, bounded tail, stderr, exit status, literal arguments, spawn failure, inherited and explicit environments, persistent log selection")
    }
}
