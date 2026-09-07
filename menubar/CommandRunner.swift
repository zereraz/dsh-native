import Foundation

/// Writes output directly to disk so a verbose child cannot block on a full pipe.
/// Returns a bounded tail and the child's actual exit status.
enum CommandRunner {
    static func run(executable: String, arguments: [String], environment: [String: String]? = nil,
                    logURL: URL) async -> (String, Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                           withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let output = try FileHandle(forWritingTo: logURL)
                    defer { try? output.close() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.environment = environment ?? ProcessInfo.processInfo.environment
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = output
                    process.standardError = output
                    try process.run()
                    process.waitUntilExit()
                    let input = try FileHandle(forReadingFrom: logURL)
                    defer { try? input.close() }
                    let size = try input.seekToEnd()
                    try input.seek(toOffset: size > 65536 ? size - 65536 : 0)
                    let tail = String(decoding: try input.readToEnd() ?? Data(), as: UTF8.self)
                    continuation.resume(returning: (tail, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("Command failed: \(error.localizedDescription)", 127))
                }
            }
        }
    }
}

/// Remembers operation logs across menubar launches; discovery is not an operation.
struct RunLogHistory: Codable {
    var latest: String?
    var plugins: [String: String] = [:]

    static func load(in directory: URL) -> RunLogHistory {
        let file = directory.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: file),
           let history = try? JSONDecoder().decode(RunLogHistory.self, from: data) { return history }
        // Recover logs written before the history index existed.
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.pathExtension == "log" && $0.lastPathComponent != "discovery.log" }
            .max { a, b in
                let first = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first < second
            }
        return RunLogHistory(latest: newest?.path)
    }

    static func record(log: URL, plugin: String? = nil) throws {
        let directory = log.deletingLastPathComponent()
        var history = load(in: directory)
        history.latest = log.path
        if let plugin { history.plugins[plugin] = log.path }
        try JSONEncoder().encode(history).write(to: directory.appendingPathComponent("history.json"), options: .atomic)
    }
}
