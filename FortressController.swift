// Fortress Controller: menu bar app and dashboard for macOS-Fortress.
//
// All privileged work goes through fortressctl. Each call tries, in order:
//   1. sudo -n fortressctl ...   (works when install.sh added a sudoers rule)
//   2. fortressctl ...           (unprivileged; enough for many read-only views)
//   3. an admin password prompt  (interactive actions only)

import Cocoa
import UserNotifications
import WebKit

// FORTRESSCTL lets a development build use an uninstalled copy (without sudo).
let ctlPath = ProcessInfo.processInfo.environment["FORTRESSCTL"] ?? "/usr/local/libexec/fortress-controller/fortressctl"
let selfTestOutput = ProcessInfo.processInfo.environment["FC_SELFTEST"]
let launchAgentPath = NSHomeDirectory() + "/Library/LaunchAgents/local.fortress-controller.plist"

struct CmdResult {
    var code: Int32
    var out: String
    var err: String
    var dict: [String: Any] { ["code": Int(code), "out": out, "err": err] }
}

func runProcess(_ exe: String, _ args: [String]) -> CmdResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o
    p.standardError = e
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return CmdResult(code: -1, out: "", err: "\(error)") }
    // Drain both pipes concurrently so a full stderr pipe can't block stdout.
    var errData = Data()
    let g = DispatchGroup()
    g.enter()
    DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    let outData = o.fileHandleForReading.readDataToEndOfFile()
    g.wait()
    p.waitUntilExit()
    return CmdResult(code: p.terminationStatus,
                     out: String(decoding: outData, as: UTF8.self),
                     err: String(decoding: errData, as: UTF8.self))
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func isSudoRefusal(_ r: CmdResult) -> Bool { r.code != 0 && r.err.hasPrefix("sudo:") }

/// Runs fortressctl with the best privilege available. Background calls never prompt.
func ctl(_ args: [String], interactive: Bool) -> CmdResult {
    guard FileManager.default.isExecutableFile(atPath: ctlPath) else {
        return CmdResult(code: 127, out: "", err: "\(ctlPath) is not installed. Run install.sh.")
    }
    let s = runProcess("/usr/bin/sudo", ["-n", ctlPath] + args)
    if !isSudoRefusal(s) { return s }
    let u = runProcess(ctlPath, args)
    if u.code != 77 || !interactive { return u }
    return runAsAdmin(args)
}

func runAsAdmin(_ args: [String]) -> CmdResult {
    let cmd = ([ctlPath] + args).map(shellQuote).joined(separator: " ") + " 2>&1"
    let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let script = "do shell script \"\(escaped)\" with prompt \"Fortress Controller needs administrator access to change macOS-Fortress.\" with administrator privileges without altering line endings"
    let r = runProcess("/usr/bin/osascript", ["-e", script])
    if r.code == 0 { return r }
    if r.err.contains("(-128)") { return CmdResult(code: 1, out: "", err: "Cancelled") }
    // osascript reports the command's output and exit status in its error text
    return CmdResult(code: 1, out: "", err: r.err)
}

/// Whether read-only commands can run as root without a password.
func sudoReadOnlyAllowed() -> Bool {
    runProcess("/usr/bin/sudo", ["-n", "-l", ctlPath, "ro", "status"]).code == 0
}

// MARK: - Live streams (log follow, pflog)

final class LiveStream {
    let process = Process()
    let pipe = Pipe()
    var buffer = Data()
    let lock = NSLock()
    var flushTimer: Timer?

    init(args: [String], onData: @escaping (String) -> Void, onEnd: @escaping (Int32) -> Void) {
        if sudoReadOnlyAllowed() {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", ctlPath] + args
        } else {
            process.executableURL = URL(fileURLWithPath: ctlPath)
            process.arguments = args
        }
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self = self, !d.isEmpty else { return }
            self.lock.lock(); self.buffer.append(d); self.lock.unlock()
        }
        // Batch output to the page a few times a second.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock(); let d = self.buffer; self.buffer = Data(); self.lock.unlock()
            if !d.isEmpty { onData(String(decoding: d, as: UTF8.self)) }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self = self else { return }
                self.pipe.fileHandleForReading.readabilityHandler = nil
                self.flushTimer?.invalidate()
                self.lock.lock(); let d = self.buffer; self.buffer = Data(); self.lock.unlock()
                if !d.isEmpty { onData(String(decoding: d, as: UTF8.self)) }
                onEnd(p.terminationStatus)
            }
        }
        do { try process.run() } catch {
            onData("Could not start: \(error)\n")
            flushTimer?.invalidate()
            onEnd(-1)
        }
    }

    func stop() { if process.isRunning { process.terminate() } }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate,
    WKScriptMessageHandler, WKUIDelegate, UNUserNotificationCenterDelegate {

    var statusItem: NSStatusItem!
    var window: NSWindow?
    var webView: WKWebView?
    var timer: Timer?
    var polling = false
    var lastStatus: [String: Any]?
    var lastStatusJSON = "null"
    var prevIssues: [String: String]?
    var prevBruteforce: Int?
    var prevLogErrors: Int?
    var streams: [Int: LiveStream] = [:]
    var nextStreamId = 1
    var notificationsAuthorized = false

    let defaults = UserDefaults.standard
    var pollInterval: Double { max(15, defaults.double(forKey: "poll") == 0 ? 60 : defaults.double(forKey: "poll")) }
    var notifyEnabled: Bool { defaults.object(forKey: "notify") as? Bool ?? true }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(level: "unknown")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        if selfTestOutput == nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { ok, _ in self.notificationsAuthorized = ok }
        }

        scheduleTimer()
        refresh()

        // FC_SELFTEST=<file>: open the dashboard, dump what it rendered, quit.
        if let out = selfTestOutput {
            openDashboard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                self.js("document.getElementById('logLoad').click(); document.getElementById('cfgLoad').click();")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                self.webView?.evaluateJavaScript("document.querySelectorAll('main section').forEach(s => s.classList.remove('hidden')); JSON.stringify({errors: window.__errors || [], text: document.body.innerText})") { v, e in
                    try? ((v as? String) ?? "evaluate failed: \(String(describing: e))").write(toFile: out, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: Status polling

    func refresh() {
        if polling { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            let r = ctl(["ro", "status"], interactive: false)
            let json = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            DispatchQueue.main.async {
                self.polling = false
                if let obj = obj {
                    self.handleStatus(obj, json: json)
                } else {
                    let msg = r.err.isEmpty ? "fortressctl returned no status" : r.err
                    self.lastStatus = nil
                    self.lastStatusJSON = (try? String(decoding: JSONSerialization.data(withJSONObject: ["error": msg]), as: UTF8.self)) ?? "null"
                    self.setIcon(level: "error")
                    self.rebuildMenu(error: msg)
                    self.pushStatusToPage()
                }
            }
        }
    }

    func issues(_ s: [String: Any]) -> [[String: String]] {
        (s["issues"] as? [[String: Any]] ?? []).map { i in
            ["level": i["level"] as? String ?? "", "key": i["key"] as? String ?? "", "message": i["message"] as? String ?? ""]
        }
    }

    func handleStatus(_ s: [String: Any], json: String) {
        lastStatus = s
        lastStatusJSON = json
        let list = issues(s)
        let level = list.contains { $0["level"] == "error" } ? "error" : (list.isEmpty ? "ok" : "warn")
        setIcon(level: level)
        rebuildMenu()
        pushStatusToPage()
        notifyChanges(s, list)
    }

    func notifyChanges(_ s: [String: Any], _ list: [[String: String]]) {
        var current: [String: String] = [:]
        for i in list { current[i["key"]!] = (i["level"] == "error" ? "Error: " : "Warning: ") + i["message"]! }

        if let prev = prevIssues {
            for (k, msg) in current where prev[k] == nil { notify(title: "Fortress problem", body: msg) }
            for (k, msg) in prev where current[k] == nil {
                notify(title: "Fortress: resolved", body: msg.replacingOccurrences(of: "Error: ", with: "").replacingOccurrences(of: "Warning: ", with: ""))
            }
        } else if !current.isEmpty {
            notify(title: "Fortress: \(current.count) problem\(current.count == 1 ? "" : "s")",
                   body: current.values.sorted().joined(separator: "\n"))
        }
        prevIssues = current

        if let pf = s["pf"] as? [String: Any], let tables = pf["tables"] as? [[String: Any]],
           let bf = tables.first(where: { $0["name"] as? String == "bruteforce" })?["entries"] as? Int {
            if let prev = prevBruteforce, bf > prev {
                notify(title: "PF blocked a new attacker", body: "\(bf - prev) new address\(bf - prev == 1 ? "" : "es") in the bruteforce table (\(bf) total)")
            }
            prevBruteforce = bf
        }

        if let fl = s["fortress_log"] as? [String: Any], let n = fl["error_count"] as? Int {
            if let prev = prevLogErrors, n > prev {
                notify(title: "Blocklist update error", body: fl["last_error"] as? String ?? "See the fortress log")
            }
            prevLogErrors = n
        }
    }

    func notify(title: String, body: String, force: Bool = false) {
        guard (notifyEnabled || force) && selfTestOutput == nil else { return }
        if notificationsAuthorized {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        } else {
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            DispatchQueue.global().async {
                _ = runProcess("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.openDashboard() }
        completionHandler()
    }

    // MARK: Menu bar

    func setIcon(level: String) {
        let name: String, color: NSColor?
        switch level {
        case "ok": name = "checkmark.shield"; color = nil
        case "warn": name = "exclamationmark.shield"; color = .systemOrange
        case "error": name = "xmark.shield"; color = .systemRed
        default: name = "shield"; color = nil
        }
        var img = NSImage(systemSymbolName: name, accessibilityDescription: "Fortress")
        if let color = color {
            img = img?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
            img?.isTemplate = false
        } else {
            img?.isTemplate = true
        }
        statusItem.button?.image = img
        statusItem.button?.toolTip = "Fortress Controller"
    }

    func item(_ title: String, _ action: Selector?, _ key: String = "", rep: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.representedObject = rep
        return i
    }

    func info(_ ok: Bool?, _ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: (ok == nil ? "○ " : ok! ? "● " : "✕ ") + text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func rebuildMenu(error: String? = nil) {
        let m = statusItem.menu!
        m.removeAllItems()
        let s = lastStatus
        let list = s.map(issues) ?? []

        if let error = error {
            m.addItem(info(false, "Status unavailable: " + error.prefix(80)))
        } else if s == nil {
            m.addItem(info(nil, "Checking…"))
        } else if list.isEmpty {
            m.addItem(info(true, "macOS-Fortress: all good"))
        } else {
            m.addItem(info(false, "macOS-Fortress: \(list.count) problem\(list.count == 1 ? "" : "s")"))
            for i in list { m.addItem(info(false, "   " + i["message"]!)) }
        }

        if let s = s {
            m.addItem(.separator())
            let checks = s["checks"] as? [String: String] ?? [:]
            let okCode = { (c: String?) in (c ?? "").range(of: "^[23][0-9][0-9]$", options: .regularExpression) != nil }
            let sp = s["system_proxy"] as? [String: Any] ?? [:]
            let pacOn = sp["pac_enabled"] as? Bool ?? false
            m.addItem(info(pacOn, "System proxy: " + (pacOn ? "on" : "off")))
            m.addItem(info(okCode(checks["privoxy_http"]), "Privoxy: " + (okCode(checks["privoxy_http"]) ? "running" : "not answering")))
            m.addItem(info(checks["block_http"] == "403", "Ad blocking (HTTP): " + (checks["block_http"] == "403" ? "working" : "not working")))
            m.addItem(info(okCode(checks["https_inspection"]), "HTTPS inspection: " + (okCode(checks["https_inspection"]) ? "working" : "failing")))
            m.addItem(info(okCode(checks["blackhole_http"]), "Blackhole server: " + (okCode(checks["blackhole_http"]) ? "running" : "down")))
            m.addItem(info(okCode(checks["pac_http"]), "proxy.pac server: " + (okCode(checks["pac_http"]) ? "running" : "down")))
            if let pf = s["pf"] as? [String: Any] {
                let en = pf["enabled"] as? Bool ?? false
                let rules = pf["rules"] as? Int ?? 0
                m.addItem(info(en && rules > 0, "PF firewall: " + (!en ? "disabled" : rules == 0 ? "enabled but no rules loaded" : "enabled, \(pf["attacks"] as? Int ?? 0) attack sources")))
            } else {
                m.addItem(info(nil, "PF firewall: needs sudo rule to read"))
            }

            m.addItem(.separator())
            let proxyMenu = NSMenu()
            for svc in sp["services"] as? [[String: Any]] ?? [] {
                guard let name = svc["name"] as? String else { continue }
                let on = svc["pac_enabled"] as? Bool ?? false
                let i = item(name, #selector(toggleSysProxy(_:)), rep: [on ? "off" : "on", name])
                i.state = on ? .on : .off
                proxyMenu.addItem(i)
            }
            let pm = NSMenuItem(title: "System proxy", action: nil, keyEquivalent: "")
            pm.submenu = proxyMenu
            m.addItem(pm)
        }

        m.addItem(item("Open Dashboard…", #selector(openDashboardAction), "d"))
        m.addItem(.separator())
        m.addItem(item("Restart Privoxy", #selector(runAction(_:)), rep: ["privoxy", "restart"]))
        m.addItem(item("Reload PF Firewall", #selector(runAction(_:)), rep: ["pf", "reload"]))
        m.addItem(item("Update All Blocklists", #selector(runAction(_:)), rep: ["update", "all"]))
        m.addItem(item("Reload Whole Fortress", #selector(runAction(_:)), rep: ["fortress", "reload"]))
        m.addItem(.separator())
        m.addItem(item("Refresh Now", #selector(refreshAction), "r"))
        let n = item("Notifications", #selector(toggleNotify))
        n.state = notifyEnabled ? .on : .off
        m.addItem(n)
        let l = item("Start at Login", #selector(toggleLogin))
        l.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
        m.addItem(l)
        m.addItem(item("Quit Fortress Controller", #selector(NSApplication.terminate(_:)), "q"))
    }

    @objc func refreshAction() { refresh() }
    @objc func openDashboardAction() { openDashboard() }

    @objc func toggleNotify() {
        defaults.set(!notifyEnabled, forKey: "notify")
        rebuildMenu()
    }

    @objc func toggleLogin() {
        setLogin(!FileManager.default.fileExists(atPath: launchAgentPath))
        rebuildMenu()
    }

    @objc func runAction(_ sender: NSMenuItem) {
        guard let args = sender.representedObject as? [String] else { return }
        perform(args)
    }

    @objc func toggleSysProxy(_ sender: NSMenuItem) {
        guard let rep = sender.representedObject as? [String] else { return }
        if rep[0] == "on", let checks = lastStatus?["checks"] as? [String: String],
           (checks["https_inspection"] ?? "").range(of: "^[23][0-9][0-9]$", options: .regularExpression) == nil {
            let a = NSAlert()
            a.messageText = "HTTPS inspection is failing"
            a.informativeText = "With the proxy on, most HTTPS sites won't load until HTTPS inspection works. Turn the proxy on for \(rep[1]) anyway?"
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Turn On")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertSecondButtonReturn { return }
        }
        perform(["sysproxy", rep[0], rep[1]])
    }

    func perform(_ args: [String]) {
        DispatchQueue.global().async {
            let r = ctl(args, interactive: true)
            DispatchQueue.main.async {
                let text = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                if r.code == 0 {
                    self.notify(title: "Done: " + args.joined(separator: " "), body: String(text.suffix(300)), force: true)
                } else if r.err != "Cancelled" {
                    self.notify(title: "Failed: " + args.joined(separator: " "), body: String(text.suffix(300)), force: true)
                }
                self.refresh()
            }
        }
    }

    func setLogin(_ on: Bool) {
        if on {
            let exe = Bundle.main.executablePath ?? ""
            let plist: [String: Any] = ["Label": "local.fortress-controller", "ProgramArguments": [exe], "RunAtLoad": true]
            try? FileManager.default.createDirectory(atPath: (launchAgentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            (plist as NSDictionary).write(toFile: launchAgentPath, atomically: true)
        } else {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        }
    }

    // MARK: Dashboard window

    func openDashboard() {
        if window == nil {
            let cfg = WKWebViewConfiguration()
            cfg.userContentController.add(self, name: "fc")
            let wv = WKWebView(frame: .zero, configuration: cfg)
            wv.uiDelegate = self
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Fortress Controller"
            w.contentView = wv
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("FortressDashboard")
            if w.frame.origin == .zero { w.center() }
            if let url = Bundle.main.url(forResource: "dashboard", withExtension: "html") {
                wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
            webView = wv
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        for s in streams.values { s.stop() }
        streams.removeAll()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "fc")
        webView = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func js(_ code: String) { webView?.evaluateJavaScript(code, completionHandler: nil) }

    func jsonLiteral(_ v: Any) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) {
            return String(decoding: d, as: UTF8.self)
        }
        return "null"
    }

    func reply(_ id: Int, _ v: Any) { js("FC._reply(\(id), \(jsonLiteral(v)))") }
    func replyRaw(_ id: Int, _ json: String) { js("FC._reply(\(id), \(json))") }

    func pushStatusToPage() { js("FC.onStatus(\(lastStatusJSON))") }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let b = message.body as? [String: Any], let op = b["op"] as? String, let id = b["id"] as? Int else { return }
        switch op {
        case "ctl":
            let args = b["args"] as? [String] ?? []
            let interactive = b["interactive"] as? Bool ?? true
            DispatchQueue.global().async {
                let r = ctl(args, interactive: interactive)
                DispatchQueue.main.async { self.reply(id, r.dict) }
            }
        case "status":
            replyRaw(id, lastStatusJSON)
        case "refresh":
            refresh()
            reply(id, true)
        case "streamStart":
            let args = b["args"] as? [String] ?? []
            let sid = nextStreamId
            nextStreamId += 1
            reply(id, sid)
            streams[sid] = LiveStream(args: args, onData: { [weak self] text in
                self?.js("FC.streamData(\(sid), \(self?.jsonLiteral(text) ?? "''"))")
            }, onEnd: { [weak self] code in
                self?.streams[sid] = nil
                self?.js("FC.streamEnd(\(sid), \(code))")
            })
        case "streamStop":
            if let sid = b["sid"] as? Int { streams[sid]?.stop() }
            reply(id, true)
        case "saveConfig":
            let name = b["name"] as? String ?? ""
            let content = b["content"] as? String ?? ""
            DispatchQueue.global().async {
                let tmp = NSTemporaryDirectory() + "fortress-config-\(UUID().uuidString)"
                var r: CmdResult
                do {
                    try content.write(toFile: tmp, atomically: true, encoding: .utf8)
                    r = ctl(["config-install", name, tmp], interactive: true)
                } catch {
                    r = CmdResult(code: 1, out: "", err: "Could not write temp file: \(error)")
                }
                try? FileManager.default.removeItem(atPath: tmp)
                DispatchQueue.main.async { self.reply(id, r.dict) }
            }
        case "openConsole":
            if let path = b["path"] as? String {
                NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                        withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            reply(id, true)
        case "settingsGet":
            reply(id, ["poll": Int(pollInterval), "notify": notifyEnabled, "login": FileManager.default.fileExists(atPath: launchAgentPath)])
        case "settingsSet":
            if let p = b["poll"] as? Double { defaults.set(max(15, p), forKey: "poll") }
            if let n = b["notify"] as? Bool { defaults.set(n, forKey: "notify") }
            if let l = b["login"] as? Bool { setLogin(l) }
            scheduleTimer()
            rebuildMenu()
            reply(id, true)
        case "testNotify":
            notify(title: "Fortress Controller", body: "Notifications are working.", force: true)
            reply(id, true)
        default:
            reply(id, ["code": 2, "out": "", "err": "unknown op \(op)"])
        }
    }

    // JavaScript alert/confirm need a UI delegate inside WKWebView.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
