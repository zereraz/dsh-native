// DSH Menubar — watches ~/.dsh/update-state.json and automates the whole
// update → apply cycle for the DeepSeek Harness native app, so the terminal
// is never involved:
//
//   - icon: dash when checking, red X when the host is down, cycle arrows when
//     an update is installed but not yet running, check when up-to-date
//   - "Check & Update" runs scripts/update-app.sh in the background and posts a
//     macOS notification with the outcome
//   - "Apply & Restart" runs scripts/restart-app.sh (activity gate → graceful
//     quit → drain → relaunch → health → rollback); with active chats it asks
//     before forcing
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

    private var timer: Timer?
    private var updateRunning = false
    private var applyRunning = false

    var needsApply: Bool {
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
        if health == .down { return "DeepSeek Harness host is down" }
        if needsApply, let v = state.version { return "v\(v) installed — restart to apply" }
        if let v = state.version { return "v\(v) running" }
        return "Host up (no update state)"
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func poll() {
        state = readState() ?? UpdateState()
        activeSessions = countActiveSessions(minutes: 10)
        // file flag wins (the app menu writes the file, not UserDefaults)
        if let s = try? String(contentsOfFile: autoApplyFlagFile, encoding: .utf8) {
            let flagOn = s.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
            if flagOn != autoApply { autoApply = flagOn }
        }
        Task {
            let code = await healthCheck()
            health = (code == 200) ? .up : .down
            if autoApply && health == .up && needsApply && activeSessions == 0 && !applyRunning && !updateRunning {
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
        p.arguments = ["http://127.0.0.1:41730"]
        try? p.run()
    }

    func checkUpdate() {
        guard !updateRunning else { return }
        updateRunning = true; lastLine = "Updating: pull + build + gate…"
        Task {
            let (out, code) = await runBash("HARNESS_REPO=\"$HOME/Code/ds4/deepseek-harness\" bash \"\(dshShellRoot())/scripts/update-app.sh\"")
            updateRunning = false
            let tail = lastLines(out, 2)
            lastLine = code == 0 ? "Update installed — restart to apply." : "Update FAILED (log: ~/.dsh/menubar.log)"
            poll()
            notify(code == 0 ? "DSH update installed" : "DSH update failed", tail)
        }
    }

    func applyUpdateTapped() {
        if activeSessions > 0 {
            // No dialogs (2026-08-28 product decision): applying while chats
            // are active silently becomes "apply when idle" — the user asked
            // for automatic, the gate enforces when it's actually safe.
            queueIdleApply(reason: "\(activeSessions) chat(s) active — will apply automatically when they go quiet")
            return
        }
        applyUpdate(force: false)
    }

    private func queueIdleApply(reason: String) {
        if !autoApply {
            autoApply = true   // flips flag + UserDefaults via didSet/syncFlagFile
            lastLine = "Queued: \(reason)."
        } else {
            lastLine = "Already queued: \(reason)."
        }
        notify("Apply & Restart queued", reason)
    }

    func applyUpdate(force: Bool) {
        guard !applyRunning else { return }
        applyRunning = true; lastLine = "Applying: graceful restart…"
        Task {
            let flag = force ? "--force" : ""
            let (out, code) = await runBash("bash \"\(dshShellRoot())/scripts/restart-app.sh\" \(flag)")
            applyRunning = false
            let tail = lastLines(out, 2)
            lastLine = code == 0 ? "Applied & verified." : (tail.isEmpty ? "Apply failed (log)" : tail)
            poll()
            notify(code == 0 ? "DSH restart done" : "DSH restart failed", tail)
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

    private func healthCheck() async -> Int {
        await withCheckedContinuation { cont in
            var req = URLRequest(url: URL(string: "http://127.0.0.1:41730/")!)
            req.timeoutInterval = 3
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                cont.resume(returning: (resp as? HTTPURLResponse)?.statusCode ?? 0)
            }.resume()
        }
    }

    private func runBash(_ cmd: String) async -> (String, Int32) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", cmd]
            // dsh-local fix 2026-08: the old form piped through "| tail -8",
            // so terminationStatus was TAIL's (always 0) — every failed
            // update/restart was reported to the user as success.
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                appendLog("=== \(isoDate.string(from: Date())): \(cmd)\n\(String(text.suffix(4000)))\nexit=\(proc.terminationStatus)")
                cont.resume(returning: (text, proc.terminationStatus))
            }
            do { try p.run() } catch { cont.resume(returning: ("spawn failed: \(error)", 127)) }
        }
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
                Button("Check & Update…") { model.checkUpdate() }
                Button("Apply & Restart…") { model.applyUpdateTapped() }.disabled(!model.needsApply)
            }
            Toggle("Auto-apply when idle", isOn: $model.autoApply)
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { model.start() }
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
