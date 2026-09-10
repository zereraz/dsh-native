// DSH Menubar — watches ~/.dsh/update-state.json and automates the whole
// update → apply cycle for the DeepSeek Harness native app, so the terminal
// is never involved:
//
//   - icon: dash when checking, red X when the host is down, cycle arrows when
//     an update is installed but not yet running, check when up-to-date
//   - "Check & Update" runs scripts/update-app.sh in the background and posts a
//     macOS notification with the outcome
//   - "Apply & Restart" runs scripts/restart-app.sh (activity gate → graceful
//     quit → drain → relaunch → health → rollback); reload respects recent activity
//   - "Auto-apply when idle" restarts by itself once an update is installed and
//     no chat has written to its log for 10 minutes
//
// Single file, no Xcode project; built by menubar/build.sh with plain swiftc.
import SwiftUI

struct UpdateState: Codable {
    var version: String?
    var installedAt: Date?
    var appliedAt: Date?
    var lastAction: String?
    var lastActionStatus: String?
}

struct PluginStatus: Decodable, Identifiable {
    var name: String
    var source: String
    var revision: String
    var detail: String
    var canBuild: Bool
    var staged: Bool
    var id: String { name }
}

enum HostHealth { case up, down, checking }

func dshShellRoot() -> String { NSHomeDirectory() + "/Code/Zereraz/voice/apps/dsh-shell" }

func appendLog(_ s: String) {
    let f = NSHomeDirectory() + "/.dsh/menubar.log"
    let fm = FileManager.default
    if !fm.fileExists(atPath: f) {
        fm.createFile(atPath: f, contents: s.data(using: .utf8)); return
    }
    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: f)) {
        h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); h.closeFile()
    }
}
let isoDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"; return f }()

@MainActor
final class MenubarModel: ObservableObject {
    @Published var state = UpdateState()
    @Published var stagedAppVersion: String?
    @Published var health: HostHealth = .checking
    @Published var lastLine = ""
    @Published var activeSessions = 0
    // Auto-apply source of truth: ~/.dsh/autoapply.enabled (shared with the
    // app's menu toggle). UserDefaults kept only for pre-file consumers.
    let autoApplyFlagFile = NSHomeDirectory() + "/.dsh/autoapply.enabled"
    // Default ON (2026-08-28 product decision: updates should be automatic;
    // file flag or explicit defaults override). Toggle off is one click.
    @Published var autoApply: Bool = UserDefaults.standard.object(forKey: "autoApply") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "autoApply") {
        didSet {
            UserDefaults.standard.set(autoApply, forKey: "autoApply")
            syncFlagFile()
        }
    }
    private func syncFlagFile() {
        // content-bearing flag: "1"/"0" (existence alone could not encode OFF
        // under the new ON-by-default semantics).
        try? (autoApply ? "1" : "0").write(toFile: autoApplyFlagFile, atomically: true, encoding: .utf8)
    }

    @Published var plugins: [PluginStatus] = []
    @Published private(set) var pluginRunning = false
    @Published private(set) var pluginMessage = ""
    private var pluginLogs: [String: URL] = [:]
    private var pluginPollRunning = false
    private var timer: Timer?
    @Published private(set) var updateRunning = false
    @Published private(set) var applyRunning = false
    @Published private(set) var currentLog: URL?
    private var pollRunning = false
    private var attemptedAutoApply: String?
    private var stagedAppPath: String?
    var busy: Bool { updateRunning || applyRunning || pluginRunning }

    init() {
        let directory = URL(fileURLWithPath: NSHomeDirectory() + "/.dsh/menubar-runs")
        let history = RunLogHistory.load(in: directory)
        if let latest = history.latest, FileManager.default.fileExists(atPath: latest) {
            currentLog = URL(fileURLWithPath: latest)
        }
        for (name, path) in history.plugins where FileManager.default.fileExists(atPath: path) {
            pluginLogs[name] = URL(fileURLWithPath: path)
        }
        start()
    }

    var needsApply: Bool {
        if stagedAppVersion != nil { return true }
        guard let i = state.installedAt else { return false }
        guard let a = state.appliedAt else { return true }
        return a < i
    }
    var icon: String {
        switch health {
        case .down: return "xmark.circle.fill"
        case .checking: return "circle.dashed"
        case .up: return needsApply ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill"
        }
    }
    var statusText: String {
        if pluginRunning { return "Checking plugin…" }
        if updateRunning { return "Building and checking update…" }
        if applyRunning { return "Restarting DeepSeek Harness…" }
        if let version = stagedAppVersion { return "v\(version) staged — reload to activate" }
        if health == .down { return "DeepSeek Harness host is down" }
        if needsApply, let v = state.version { return "v\(v) installed — restart to apply" }
        if let v = state.version { return "v\(v) applied" }
        return "Host up (no update state)"
    }

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func poll() {
        guard !pollRunning else { return }
        pollRunning = true
        refreshPlugins()
        let candidateURL = URL(fileURLWithPath: NSHomeDirectory() + "/.dsh/app-candidate.json")
        if let data = try? Data(contentsOf: candidateURL),
           let candidate = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            stagedAppVersion = candidate["version"]; stagedAppPath = candidate["path"]
        } else { stagedAppVersion = nil; stagedAppPath = nil }
        state = readState() ?? UpdateState()
        activeSessions = countActiveSessions(minutes: 10)
        // file flag wins (the app menu writes the file, not UserDefaults)
        if let s = try? String(contentsOfFile: autoApplyFlagFile, encoding: .utf8) {
            let flagOn = s.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
            if flagOn != autoApply { autoApply = flagOn }
        }
        Task {
            defer { pollRunning = false }
            let code = await healthCheck()
            health = (code == 200) ? .up : .down
            if autoApply && health == .up && needsApply && activeSessions == 0 && !busy && attemptedAutoApply != (stagedAppPath ?? state.installedAt?.description) {
                attemptedAutoApply = stagedAppPath ?? state.installedAt?.description
                applyUpdate(force: false)
            }
        }
    }

    // MARK: actions

    func openApp() {
        // The Open button must open THE APP, not a sibling browser tab —
        // "I clicked and only a browser tab opened" (2026-08-28).
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "/Applications/DeepSeek Harness.app"]
        try? p.run()
    }

    func openWeb() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [liveURL()]
        try? p.run()
    }

    func checkUpdate() {
        guard !busy else { return }
        updateRunning = true; lastLine = "Updating: pull + build + gate…"
        Task {
            let (out, code) = await runScript("update-app.sh", arguments: [])
            updateRunning = false
            let tail = lastLines(out, 2)
            lastLine = code == 0 ? "Update staged — reload when idle to activate." : "Update FAILED (log: ~/.dsh/menubar.log)"
            poll()
            if code != 0 { notify("DSH update failed", tail) }
        }
    }

    func applyUpdateTapped() { applyUpdate(force: false) }

    func applyUpdateNowTapped() { applyUpdate(force: true) }

    func refreshPlugins() {
        guard !pluginPollRunning && !busy else { return }
        pluginPollRunning = true
        Task {
            defer { pluginPollRunning = false }
            let log = URL(fileURLWithPath: NSHomeDirectory() + "/.dsh/menubar-runs/discovery.log")
            let result = await CommandRunner.run(executable: "/bin/bash",
                arguments: [dshShellRoot() + "/scripts/plugin-control.sh", "status"], logURL: log)
            if result.1 == 0, let rows = try? JSONDecoder().decode([PluginStatus].self, from: Data(result.0.utf8)) {
                plugins = rows; pluginMessage = ""
            } else {
                currentLog = log
                let detail = result.1 == 0 ? "Unexpected discovery response" : lastLines(result.0, 2)
                pluginMessage = "Plugin discovery failed (exit \(result.1)): \(detail). Open Log for details."
            }
        }
    }

    func preparePlugin(_ plugin: PluginStatus, update: Bool) {
        guard !busy else { return }
        pluginRunning = true
        lastLine = "\(update ? "Updating" : "Building") \(plugin.name)…"
        Task {
            let result = await runScript("plugin-control.sh", arguments: [update ? "update" : "build", plugin.name])
            if let log = currentLog { pluginLogs[plugin.name] = log }
            pluginRunning = false
            lastLine = result.1 == 0 ? "\(plugin.name) checked — Reload Backend to activate." : lastLines(result.0, 2)
            if result.1 != 0 { notify("Plugin checks failed", lastLine) }
            refreshPlugins()
        }
    }

    func hasPluginLog(_ plugin: PluginStatus) -> Bool { pluginLogs[plugin.name] != nil }

    func pluginLog(_ plugin: PluginStatus) {
        if let log = pluginLogs[plugin.name] { NSWorkspace.shared.open(log) }
        else { lastLine = "No build or update log for \(plugin.name) yet." }
    }

    func applyUpdate(force: Bool) {
        guard !busy else { return }
        applyRunning = true; lastLine = "Applying: graceful restart…"
        Task {
            let (out, code) = await runScript("restart-app.sh", arguments: force ? ["--force"] : [])
            applyRunning = false
            let tail = lastLines(out, 2)
            lastLine = code == 0 ? "Backend reloaded — test the plugin in the app." : (tail.isEmpty ? "Reload failed — open log." : tail)
            poll()
            if code != 0 && code != 3 { notify("DSH reload failed", tail) }
        }
    }

    // MARK: helpers

    private func readState() -> UpdateState? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.dsh/update-state.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .formatted(isoDate)
        return try? dec.decode(UpdateState.self, from: d)
    }

    private func countActiveSessions(minutes: Int) -> Int {
        // mirror restart-app.sh's gate: any session log written recently
        let fm = FileManager.default
        let root = NSHomeDirectory() + "/.dsh/sessions"
        guard let slugs = try? fm.contentsOfDirectory(atPath: root) else { return 0 }
        var n = 0
        let cutoff = Date().addingTimeInterval(TimeInterval(-minutes * 60))
        for slug in slugs {
            guard let sess = try? fm.contentsOfDirectory(atPath: "\(root)/\(slug)") else { continue }
            for s in sess {
                let f = "\(root)/\(slug)/\(s)/session.jsonl.zstd"
                if let attr = try? fm.attributesOfItem(atPath: f),
                   let m = attr[.modificationDate] as? Date, m > cutoff { n += 1 }
            }
        }
        return n
    }

    /// The authoritative URL (alpha+ includes the session token) is written by
    /// the supervisor: use it when present — bare "/" is 401 on gated hosts.
    private func liveURL() -> String {
        let p = NSHomeDirectory() + "/.dsh/web-url.txt"
        if let raw = try? String(contentsOfFile: p, encoding: .utf8) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: t), url.scheme == "http",
               url.host == "127.0.0.1", url.port == 41730 { return t }
        }
        return "http://127.0.0.1:41730/"
    }

    private func healthCheck() async -> Int {
        await withCheckedContinuation { cont in
            var req = URLRequest(url: URL(string: liveURL())!)
            req.timeoutInterval = 3
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                cont.resume(returning: (resp as? HTTPURLResponse)?.statusCode ?? 0)
            }.resume()
        }
    }

    private func runScript(_ name: String, arguments: [String]) async -> (String, Int32) {
        let log = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".dsh/menubar-runs/\(UUID().uuidString).log")
        currentLog = log
        var environment = ProcessInfo.processInfo.environment
        environment["HARNESS_REPO"] = NSHomeDirectory() + "/Code/ds4/deepseek-harness"
        let result = await CommandRunner.run(executable: "/bin/bash",
            arguments: [dshShellRoot() + "/scripts/" + name] + arguments,
            environment: environment, logURL: log)
        let plugin = name == "plugin-control.sh" && arguments.count > 1 ? arguments[1] : nil
        try? RunLogHistory.record(log: log, plugin: plugin)
        appendLog("=== \(isoDate.string(from: Date())): \(name)\nlog: \(log.path)\n\(String(result.0.suffix(4000)))\nexit=\(result.1)")
        return result
    }

    func openLog() {
        NSWorkspace.shared.open(currentLog ?? URL(fileURLWithPath: NSHomeDirectory() + "/.dsh/menubar-runs/discovery.log"))
    }

    private func lastLines(_ s: String, _ n: Int) -> String {
        let parts = s.split(separator: "\n").suffix(n).map(String.init)
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func notify(_ title: String, _ body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        try? p.run()
    }

}

// MARK: UI

struct MenuContent: View {
    @ObservedObject var model: MenubarModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.statusText).font(.headline)
            if !model.lastLine.isEmpty { Text(model.lastLine).font(.caption).foregroundStyle(.secondary) }
            Text(model.activeSessions > 0 ? "\(model.activeSessions) chat(s) active in last 10 min" : "Idle").font(.caption2).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Open") { model.openApp() }
                Button("Update") { model.checkUpdate() }.disabled(model.busy)
                Button(model.stagedAppVersion != nil ? "Activate v\(model.stagedAppVersion ?? "")" : "Reload Backend") { model.applyUpdateTapped() }.disabled(model.busy)
                if model.stagedAppVersion != nil && model.activeSessions > 0 {
                    Button("Now") { model.applyUpdateNowTapped() }.disabled(model.busy)
                }
            }
            Text(reloadCaption).font(.caption2).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup("Plugins (\(model.plugins.count))") {
                if !model.pluginMessage.isEmpty { Text(model.pluginMessage).font(.caption) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.plugins) { plugin in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(plugin.name) · source \(plugin.revision)").font(.subheadline)
                                Text(plugin.detail).font(.caption2).foregroundStyle(.secondary)
                                HStack {
                                    Button("Update & Check") { model.preparePlugin(plugin, update: true) }.disabled(model.busy || !plugin.canBuild)
                                    Button("Log") { model.pluginLog(plugin) }.disabled(!model.hasPluginLog(plugin))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: 230, alignment: .leading)
            }
            .font(.subheadline)
            Divider()
            DisclosureGroup("Advanced") {
                Toggle("Auto-apply when idle", isOn: $model.autoApply)
                Button(model.currentLog == nil || model.currentLog?.lastPathComponent == "discovery.log" ? "Discovery Log" : "Latest Run Log") { model.openLog() }
            }
            .font(.subheadline)
        }
        .padding(12)
        .frame(width: 380)
        .onAppear { model.start() }
    }

    private var reloadCaption: String {
        if model.stagedAppVersion == nil { return "Reload restarts the backend as-is." }
        return model.activeSessions > 0
            ? "Activate waits for chat to go quiet — Now cuts immediately."
            : "Backend is idle — activates immediately."
    }
}

@main
struct DSHMenubarApp: App {
    @StateObject private var model = MenubarModel()
    var body: some Scene {
        MenuBarExtra("DeepSeek Harness", systemImage: model.icon) {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
