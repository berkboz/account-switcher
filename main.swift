import AppKit
import ServiceManagement

// Menu bar app for switching accounts across Claude Desktop, Claude Code (terminal) and Codex.
//
// Three different mechanisms, one menu:
//  - Claude Desktop keeps its whole login (cookies + OAuth token cache) inside its data folder
//    and hands that login to the Code tab through CLAUDE_CODE_OAUTH_TOKEN, so the Keychain is
//    never consulted there. Switching therefore means: quit Claude, swap the active data folder
//    with a parked one, reopen. The Code tab follows automatically.
//  - Claude Code in a terminal reads its OAuth token from the Keychain; claude-swap (cswap)
//    swaps which stored account is active.
//  - Codex reads ~/.codex/auth.json; codex-auth swaps which stored account is active. The Codex
//    app only reads that file at launch, so it has to be restarted to pick up a switch.

let home = NSHomeDirectory()
// ACCOUNT_SWITCHER_PATH replaces the helper search path, e.g. to see the setup window as it looks
// on a Mac without the helpers. ACCOUNT_SWITCHER_ROOT lets the swap be exercised against a
// scratch folder.
let shellPath = ProcessInfo.processInfo.environment["ACCOUNT_SWITCHER_PATH"]
    ?? "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
let appSupport = ProcessInfo.processInfo.environment["ACCOUNT_SWITCHER_ROOT"] ?? "\(home)/Library/Application Support"
let testMode = ProcessInfo.processInfo.environment["ACCOUNT_SWITCHER_ROOT"] != nil
let activeDir = "\(appSupport)/Claude"
let parkedPrefix = "Claude-Profile-"
let nameMarker = ".account-switcher-name"
let claudeBundle = "com.anthropic.claudefordesktop"
let codexBundle = "com.openai.codex"

struct Account {
    let id: String          // what the CLI's `switch` command accepts
    let email: String
    let detail: String
    let active: Bool
}

struct Profile {
    let name: String
    let dir: String
    var active: Bool { dir == activeDir }
}

/// Runs a shell command line. Only for fixed strings; anything that carries account names,
/// emails or paths goes through `run(args:)` so it is never parsed by a shell.
@discardableResult
func run(_ command: String, timeout: Double = 60) -> (output: String, ok: Bool) {
    run(args: ["/bin/zsh", "-c", command], timeout: timeout)
}

/// Runs a program (looked up in `shellPath`) with literal arguments. A helper that hangs, for
/// example on the network, is killed after `timeout` seconds so refreshes cannot pile up.
@discardableResult
func run(args: [String], timeout: Double = 60) -> (output: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = shellPath
    env["NO_COLOR"] = "1"
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return ("", false) }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus == 0)
}

func notify(_ title: String, _ body: String) {
    run(args: ["osascript", "-e", "on run argv", "-e",
               "display notification (item 1 of argv) with title (item 2 of argv)", "-e", "end run",
               body, title])
}

func isRunning(_ bundle: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
}

/// Asks an app to quit the normal way (it may still show its own "quit?" dialog) and waits up to
/// `timeout` seconds. Uses NSRunningApplication rather than AppleScript so no Automation
/// permission prompt appears.
@discardableResult
func quitApp(_ bundle: String, timeout: Double = 60) -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).forEach { $0.terminate() }
    let deadline = Date().addingTimeInterval(timeout)
    while isRunning(bundle) && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
    return !isRunning(bundle)
}

// MARK: - Claude Desktop profiles

func activeProfileName() -> String {
    (try? String(contentsOfFile: "\(activeDir)/\(nameMarker)", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Main"
}

/// The active profile first (when Claude has a data folder at all), then the parked ones.
func loadProfiles() -> [Profile] {
    var out = FileManager.default.fileExists(atPath: activeDir)
        ? [Profile(name: activeProfileName(), dir: activeDir)] : []
    let names = (try? FileManager.default.contentsOfDirectory(atPath: appSupport)) ?? []
    for n in names.sorted() where n.hasPrefix(parkedPrefix) {
        out.append(Profile(name: String(n.dropFirst(parkedPrefix.count)), dir: "\(appSupport)/\(n)"))
    }
    return out
}

func safeName(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespaces)
        .components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
}

// MARK: - Shared Code sessions
//
// Desktop Code sessions are small JSON files under claude-code-sessions/<account>/<org>/ that
// point at transcripts in ~/.claude/projects (already shared by every account). Only the folder
// path ties them to an account. To keep sessions across accounts, as Codex does:
//  - claude-code-sessions and scratch-workspaces move out of the data folders into Claude-Shared,
//    and every account folder gets a symlink to them (scratch sessions store absolute cwd paths
//    under Claude/scratch-workspaces/, which then resolve for every account);
//  - inside the shared sessions folder, every <account>/<org> folder becomes a symlink to one
//    common _all folder, so each account lists the same sessions.
// Only ever run while Claude Desktop is quit.

let sharedRoot = "\(appSupport)/Claude-Shared"
let sharedFolders = ["claude-code-sessions", "scratch-workspaces"]
let commonSessions = "_all"

func isSymlink(_ path: String) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
}

func isDir(_ path: String) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
}

/// Where `merge` puts the losing side of a conflict, so a merge never deletes anything.
let conflictsDir = "\(sharedRoot)/_conflicts"

/// Moves `path` into `conflictsDir` under a name that cannot clash.
func setAside(_ path: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: conflictsDir, withIntermediateDirectories: true)
    let stamp = Int(Date().timeIntervalSince1970)
    let name = "\((path as NSString).lastPathComponent).\(stamp)-\(UUID().uuidString.prefix(8))"
    try fm.moveItem(atPath: path, toPath: "\(conflictsDir)/\(name)")
}

/// Moves everything in `src` into `dst`, recursing into folders both sides have. On a conflict
/// the newer copy takes the place and the other one is set aside in `conflictsDir`. `src` is
/// removed afterwards (it is empty by then).
func merge(_ src: String, into dst: String) throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: dst) && !isSymlink(dst) { try fm.moveItem(atPath: src, toPath: dst); return }
    for name in try fm.contentsOfDirectory(atPath: src) {
        let s = "\(src)/\(name)", d = "\(dst)/\(name)"
        if !fm.fileExists(atPath: d) && !isSymlink(d) {
            try fm.moveItem(atPath: s, toPath: d)
        } else if isDir(s) && isDir(d) && !isSymlink(s) && !isSymlink(d) {
            try merge(s, into: d)
        } else {
            let sDate = (try? fm.attributesOfItem(atPath: s)[.modificationDate] as? Date) ?? .distantPast
            let dDate = (try? fm.attributesOfItem(atPath: d)[.modificationDate] as? Date) ?? .distantPast
            if sDate > dDate && !isSymlink(d) {
                try setAside(d)
                try fm.moveItem(atPath: s, toPath: d)
            } else {
                try setAside(s)
            }
        }
    }
    try fm.removeItem(atPath: src)
}

/// Points `profileDir`'s shared folders at Claude-Shared, merging in whatever it had.
func linkShared(_ profileDir: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: sharedRoot, withIntermediateDirectories: true)
    for name in sharedFolders {
        let local = "\(profileDir)/\(name)", shared = "\(sharedRoot)/\(name)"
        if isSymlink(local) {
            // A link that resolves is left alone (it may be the user's own); a dangling one,
            // e.g. from an older shared location, holds no data and is replaced.
            if fm.fileExists(atPath: local) { continue }
            try fm.removeItem(atPath: local)
        }
        if fm.fileExists(atPath: local) { try merge(local, into: shared) }
        try fm.createDirectory(atPath: shared, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: local, withDestinationPath: shared)
    }
}

/// Makes every <account>/<org> session folder a symlink to the common one.
func unifySessions() throws {
    let fm = FileManager.default
    let root = "\(sharedRoot)/claude-code-sessions", common = "\(root)/\(commonSessions)"
    guard isDir(root) else { return }
    try fm.createDirectory(atPath: common, withIntermediateDirectories: true)
    for account in try fm.contentsOfDirectory(atPath: root) where account != commonSessions {
        let accountDir = "\(root)/\(account)"
        guard isDir(accountDir), !isSymlink(accountDir) else { continue }
        for org in try fm.contentsOfDirectory(atPath: accountDir) {
            let orgDir = "\(accountDir)/\(org)"
            if isSymlink(orgDir) || !isDir(orgDir) { continue }
            try merge(orgDir, into: common)
            try fm.createSymbolicLink(atPath: orgDir, withDestinationPath: "../\(commonSessions)")
        }
    }
}

/// Quits Claude Desktop, parks the active data folder, activates `target`, reopens Claude.
/// Returns nil on success or a human-readable error. Every step is undone on failure.
func swapDesktop(to target: Profile) -> String? {
    let fm = FileManager.default
    let current = activeProfileName()
    let parkedCurrent = "\(appSupport)/\(parkedPrefix)\(current)"
    guard !target.active else { return nil }
    guard fm.fileExists(atPath: target.dir) else { return "Profile folder is missing: \(target.dir)" }
    // No active folder happens when Claude was never opened, or when a swap was interrupted
    // between its two moves. Then there is nothing to park; just activate the target.
    let hasActive = fm.fileExists(atPath: activeDir)
    guard !hasActive || !fm.fileExists(atPath: parkedCurrent) else {
        return "Cannot park the current account: a profile named \"\(current)\" already exists."
    }

    if !testMode && isRunning(claudeBundle) {
        // Claude may ask to confirm quitting while sessions run; give the user time to answer.
        if !quitApp(claudeBundle) { return "Claude did not quit, so nothing was changed." }
        Thread.sleep(forTimeInterval: 1)
    }

    if hasActive {
        do {
            try fm.moveItem(atPath: activeDir, toPath: parkedCurrent)
        } catch {
            return "Could not park the current account: \(error.localizedDescription)"
        }
        try? current.write(toFile: "\(parkedCurrent)/\(nameMarker)", atomically: true, encoding: .utf8)
    }
    do {
        try fm.moveItem(atPath: target.dir, toPath: activeDir)
    } catch {
        if hasActive { try? fm.moveItem(atPath: parkedCurrent, toPath: activeDir) }
        return "Could not activate \(target.name): \(error.localizedDescription)"
    }
    try? target.name.write(toFile: "\(activeDir)/\(nameMarker)", atomically: true, encoding: .utf8)

    // Claude is quit, so this is the safe moment to (re)link shared Code sessions. A failure
    // here must not block the switch itself.
    var warning: String?
    if Prefs.shareCodeSessions { do {
        if hasActive { try linkShared(parkedCurrent) }
        try linkShared(activeDir)
        try unifySessions()
    } catch {
        warning = "Switched, but sharing Code sessions failed: \(error.localizedDescription)"
    } }
    if !testMode { run(args: ["open", "-b", claudeBundle]) }
    return warning
}

// MARK: - CLI-backed accounts

func pct(_ v: Any?) -> String {
    guard let n = v as? Double else { return "–" }
    return "\(Int(n.rounded()))%"
}

func loadClaudeAccounts() -> [Account] {
    let out = run("cswap list --json 2>/dev/null", timeout: 30).output
    guard let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
          let accounts = json["accounts"] as? [[String: Any]] else { return [] }
    return accounts.map { a in
        let usage = a["usage"] as? [String: Any]
        let five = (usage?["fiveHour"] as? [String: Any])?["pct"]
        let week = (usage?["sevenDay"] as? [String: Any])?["pct"]
        return Account(id: "\(a["number"] ?? "")",
                       email: a["email"] as? String ?? "?",
                       detail: "used  5h \(pct(five)) · 7d \(pct(week))",
                       active: a["active"] as? Bool ?? false)
    }
}

func loadCodexAccounts() -> [Account] {
    let out = run("codex-auth list --skip-api 2>/dev/null", timeout: 30).output
    // Rows look like: "* 01 me@x.com  Business  82% (15:59)  97% (10:59 on 24 Sep)  Now"
    return out.split(separator: "\n").compactMap { line -> Account? in
        var t = line.split(separator: " ").map(String.init)
        let active = t.first == "*"
        if active { t.removeFirst() }
        guard t.count >= 3, Int(t[0]) != nil, t[1].contains("@") else { return nil }
        let usage = t.dropFirst(3).filter { $0.hasSuffix("%") || $0 == "-" }
        return Account(id: t[1], email: t[1],
                       detail: "\(t[2]) · left  5h \(usage.first ?? "–") · wk \(usage.dropFirst().first ?? "–")",
                       active: active)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Settings

enum CodexRestart: Int, CaseIterable {
    case ask, always, never
    var title: String { ["Ask", "Always", "Never"][rawValue] }
}

/// User preferences, stored in UserDefaults. Codex Auto-Switch lives in codex-auth's own config.
enum Prefs {
    static let d = UserDefaults.standard
    static let refreshChoices = [30, 60, 300]
    /// Menu bar glyphs: (title, SF Symbol, point size). Filled shapes sit at the same visual weight
    /// as the system's own menu bar icons; the outlined original looks small next to them.
    static let icons: [(title: String, symbol: String, size: CGFloat)] = [
        ("People (circle)", "person.2.circle.fill", 17),
        ("People", "person.2.fill", 15),
        ("Switch (circle)", "arrow.triangle.2.circlepath.circle.fill", 17),
        ("Swap (circle)", "arrow.left.arrow.right.circle.fill", 17),
        ("People linked", "person.line.dotted.person.fill", 14),
        ("Repeat", "arrow.2.squarepath", 15),
        ("Swap windows", "rectangle.2.swap", 15),
        ("Classic (outline)", "person.2.circle", 15),
    ]

    static func register() {
        d.register(defaults: [
            "showDesktop": true, "showClaudeCode": true, "showCodex": true,
            "refreshSeconds": 60, "menuIcon": "person.2.circle.fill",
            "shareCodeSessions": true, "confirmDesktopSwitch": true,
            "codexRestart": CodexRestart.ask.rawValue, "notifyCodexBackgroundSwitch": true,
        ])
    }

    static var showDesktop: Bool { d.bool(forKey: "showDesktop") }
    static var showClaudeCode: Bool { d.bool(forKey: "showClaudeCode") }
    static var showCodex: Bool { d.bool(forKey: "showCodex") }
    static var refreshSeconds: Int { max(10, d.integer(forKey: "refreshSeconds")) }
    static var menuIcon: String { d.string(forKey: "menuIcon") ?? icons[0].symbol }
    static var shareCodeSessions: Bool { d.bool(forKey: "shareCodeSessions") }
    static var confirmDesktopSwitch: Bool { d.bool(forKey: "confirmDesktopSwitch") }
    static var codexRestart: CodexRestart { CodexRestart(rawValue: d.integer(forKey: "codexRestart")) ?? .ask }
    static var notifyCodexBackgroundSwitch: Bool { d.bool(forKey: "notifyCodexBackgroundSwitch") }
}

/// codex-auth's auto-switch state, e.g. "auto-switch: ON" / "thresholds: 5h<10%, weekly<5%".
struct CodexAuto {
    var on = false, fiveHour = 10, weekly = 5

    static func load() -> CodexAuto {
        let out = run("codex-auth status 2>/dev/null", timeout: 30).output
        func num(_ pattern: String) -> Int? {
            guard let r = out.range(of: pattern, options: .regularExpression) else { return nil }
            return Int(out[r].filter(\.isNumber))
        }
        return CodexAuto(on: out.contains("auto-switch: ON"),
                         fiveHour: num(#"5h<\d+"#) ?? 10, weekly: num(#"weekly<\d+"#) ?? 5)
    }
}

final class SettingsController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    let onChange: () -> Void
    // Controls that are re-read or re-synced; everything else writes straight to Prefs.
    var loginBox, autoBox: NSButton!
    var fiveHourPopup, weeklyPopup: NSPopUpButton!
    var prefBoxes: [NSButton] = []      // also changed from the setup window, so re-read on show
    let fiveHourChoices = [5, 10, 15, 20, 25, 30], weeklyChoices = [2, 5, 10, 15, 20]

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func show() {
        if window == nil { build() }
        sync()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    func check(_ title: String, key: String, note: String? = nil) -> NSView {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggled(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(key)
        b.state = Prefs.d.bool(forKey: key) ? .on : .off
        prefBoxes.append(b)
        return withNote(b, note)
    }

    func withNote(_ control: NSView, _ note: String?) -> NSView {
        guard let note else { return control }
        let label = NSTextField(wrappingLabelWithString: note)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 400
        let s = NSStackView(views: [control, label])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        label.setContentHuggingPriority(.required, for: .vertical)
        return s
    }

    func popup(_ titles: [String], selected: Int, action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.selectItem(at: max(0, selected))
        p.target = self
        p.action = action
        return p
    }

    func row(_ label: String, _ control: NSView) -> NSView {
        let s = NSStackView(views: [NSTextField(labelWithString: label), control])
        s.spacing = 8
        return s
    }

    func heading(_ text: String) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        return t
    }

    func build() {
        loginBox = NSButton(checkboxWithTitle: "Open at login", target: self, action: #selector(toggleLogin))
        autoBox = NSButton(checkboxWithTitle: "Auto-Switch when an account is nearly out of quota",
                           target: self, action: #selector(toggleAuto))
        fiveHourPopup = popup(fiveHourChoices.map { "\($0)%" }, selected: 1, action: #selector(thresholdChanged))
        weeklyPopup = popup(weeklyChoices.map { "\($0)%" }, selected: 1, action: #selector(thresholdChanged))
        let refresh = popup(["30 seconds", "1 minute", "5 minutes"],
                            selected: Prefs.refreshChoices.firstIndex(of: Prefs.refreshSeconds) ?? 1,
                            action: #selector(refreshChanged(_:)))
        let restart = popup(CodexRestart.allCases.map(\.title), selected: Prefs.codexRestart.rawValue,
                            action: #selector(restartChanged(_:)))
        let icon = popup(Prefs.icons.map(\.title),
                         selected: Prefs.icons.firstIndex { $0.symbol == Prefs.menuIcon } ?? 0,
                         action: #selector(iconChanged(_:)))
        for (i, entry) in Prefs.icons.enumerated() {
            icon.item(at: i)?.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
        }

        let views: [NSView] = [
            heading("General"),
            NSTextField(labelWithString: "Show in menu:"),
            check("Claude Desktop", key: "showDesktop"),
            check("Claude Code (Terminal)", key: "showClaudeCode"),
            check("Codex", key: "showCodex"),
            loginBox,
            row("Menu bar icon", icon),
            row("Refresh accounts every", refresh),

            heading("Claude Desktop"),
            check("Share Code sessions across accounts", key: "shareCodeSessions",
                  note: "Every account sees the same Code sessions, like Codex chats. Applied at the next switch. Turning it off stops new sharing; sessions already shared stay in the shared list."),
            check("Ask before quitting Claude to switch", key: "confirmDesktopSwitch"),

            heading("Codex"),
            withNote(row("Restart the Codex app after a switch:", restart),
                     "The Codex app keeps the old account until it restarts. Restarting stops running Codex tasks."),
            check("Notify when Auto-Switch changes the account in the background",
                  key: "notifyCodexBackgroundSwitch"),
            withNote(autoBox, "Handled by codex-auth. It also undoes a manual switch to an account below these limits."),
            row("Switch when 5-hour quota left is below", fiveHourPopup),
            row("or weekly quota left is below", weeklyPopup),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        for h in views where (h as? NSTextField)?.font?.pointSize ?? 0 > NSFont.systemFontSize {
            stack.setCustomSpacing(4, after: h)
            if let i = stack.arrangedSubviews.firstIndex(of: h), i > 0 {
                stack.setCustomSpacing(18, after: stack.arrangedSubviews[i - 1])
            }
        }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Account Switcher Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = stack
        window = w
    }

    /// Re-reads the checkboxes other windows can change and the settings that live outside
    /// UserDefaults. codex-auth runs off the main thread; its controls stay disabled until it answers.
    func sync() {
        for b in prefBoxes { b.state = Prefs.d.bool(forKey: b.identifier?.rawValue ?? "") ? .on : .off }
        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        [autoBox, fiveHourPopup, weeklyPopup].forEach { $0?.isEnabled = false }
        DispatchQueue.global().async {
            let installed = hasCommand("codex-auth"), auto = CodexAuto.load()
            DispatchQueue.main.async {
                self.autoBox.state = auto.on ? .on : .off
                self.fiveHourPopup.selectItem(at: self.fiveHourChoices.firstIndex(of: auto.fiveHour) ?? 1)
                self.weeklyPopup.selectItem(at: self.weeklyChoices.firstIndex(of: auto.weekly) ?? 1)
                self.autoBox.isEnabled = installed
                self.fiveHourPopup.isEnabled = installed && auto.on
                self.weeklyPopup.isEnabled = installed && auto.on
            }
        }
    }

    // MARK: Actions

    @objc func toggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        Prefs.d.set(sender.state == .on, forKey: key)
        onChange()
    }

    @objc func refreshChanged(_ sender: NSPopUpButton) {
        Prefs.d.set(Prefs.refreshChoices[sender.indexOfSelectedItem], forKey: "refreshSeconds")
        onChange()
    }

    @objc func iconChanged(_ sender: NSPopUpButton) {
        Prefs.d.set(Prefs.icons[sender.indexOfSelectedItem].symbol, forKey: "menuIcon")
        onChange()
    }

    @objc func restartChanged(_ sender: NSPopUpButton) {
        Prefs.d.set(sender.indexOfSelectedItem, forKey: "codexRestart")
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister() } else { try s.register() }
        } catch {
            notify("Account Switcher", "Login item error: \(error.localizedDescription)")
        }
        sync()
    }

    /// Runs a codex-auth config change off the main thread, then re-reads what it stored.
    func codexConfig(_ args: [String], failure: String) {
        [autoBox, fiveHourPopup, weeklyPopup].forEach { $0?.isEnabled = false }
        DispatchQueue.global().async {
            let r = run(args: ["codex-auth", "config", "auto"] + args)
            if !r.ok { notify("Codex", "\(failure): \(r.output.suffix(120))") }
            DispatchQueue.main.async { self.sync(); self.onChange() }
        }
    }

    @objc func toggleAuto() {
        codexConfig([autoBox.state == .on ? "enable" : "disable"], failure: "Could not change Auto-Switch")
    }

    @objc func thresholdChanged() {
        codexConfig(["--5h", "\(fiveHourChoices[fiveHourPopup.indexOfSelectedItem])",
                     "--weekly", "\(weeklyChoices[weeklyPopup.indexOfSelectedItem])"],
                    failure: "Could not save thresholds")
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var profiles: [Profile] = []
    var claude: [Account] = []
    var codex: [Account] = []
    var codexAuto = false
    var busy = false
    var lastCodexActive: String?    // to notice switches made by codex-auth's background daemon
    var timer: Timer?
    lazy var settings = SettingsController { [weak self] in self?.applySettings() }
    lazy var onboarding: OnboardingController = {
        let o = OnboardingController()
        o.app = self
        return o
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false   // otherwise AppKit ignores every isEnabled set below
        item.menu = menu
        applySettings()
        if CommandLine.arguments.contains("--settings") { settings.show() }
        if CommandLine.arguments.contains("--setup") || !Prefs.d.bool(forKey: "onboarded") { onboarding.show() }
    }

    /// Called at launch and whenever a setting changes.
    func applySettings() {
        let entry = Prefs.icons.first { $0.symbol == Prefs.menuIcon } ?? Prefs.icons[0]
        let image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: "Account Switcher")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: entry.size, weight: .regular))
        image?.isTemplate = true
        item.button?.image = image
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Prefs.refreshSeconds), repeats: true) {
            [weak self] _ in self?.refresh()
        }
        rebuild()
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        DispatchQueue.global().async {
            let p = loadProfiles(), c = loadClaudeAccounts(), x = loadCodexAccounts(), a = CodexAuto.load().on
            DispatchQueue.main.async {
                self.profiles = p; self.claude = c; self.codex = x; self.codexAuto = a
                self.noticeBackgroundCodexSwitch()
                self.rebuild()
            }
        }
    }

    // MARK: Menu construction

    func header(_ title: String, _ note: String? = nil) {
        let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let s = NSMutableAttributedString(string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        if let note {
            s.append(NSAttributedString(string: "  " + note, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor]))
        }
        h.attributedTitle = s
        h.isEnabled = false
        menu.addItem(h)
    }

    func twoLine(_ item: NSMenuItem, _ title: String, _ detail: String) {
        let s = NSMutableAttributedString(string: title + "\n")
        s.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = s
        item.toolTip = detail
    }

    func add(_ title: String, _ action: Selector, key: String = "", object: Any? = nil,
             enabled: Bool = true) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        mi.representedObject = object
        mi.isEnabled = enabled
        menu.addItem(mi)
        return mi
    }

    func rebuild() {
        menu.removeAllItems()

        if Prefs.showDesktop { desktopSection(); menu.addItem(.separator()) }
        if Prefs.showClaudeCode {
            section("Claude Code (Terminal)", claude, tool: "claude", nextKey: "l")
            menu.addItem(.separator())
        }
        if Prefs.showCodex {
            section("Codex", codex, tool: "codex", nextKey: "x")
            let auto = add("Codex Auto-Switch", #selector(toggleCodexAuto), enabled: !codex.isEmpty && !busy)
            auto.state = codexAuto ? .on : .off
            auto.toolTip = "codex-auth moves you to another account when the current one is nearly out of quota. It also undoes manual switches to an account below the threshold."
            menu.addItem(.separator())
        }

        _ = add("Setup…", #selector(openSetup))
        _ = add("Settings…", #selector(openSettings), key: ",")
        _ = add("Help / Setup Guide", #selector(openHelp), key: "?")
        _ = add("Refresh", #selector(refreshAction), key: "r")
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func desktopSection() {
        header("Claude Desktop", "incl. its Code tab")
        for p in profiles {
            let mi = add(p.name, #selector(switchDesktop(_:)), object: p.dir, enabled: !busy)
            mi.state = p.active ? .on : .off
            twoLine(mi, p.name, p.active ? "signed in now" : "click to quit Claude and reopen as this account")
        }
        _ = add("Next Claude Desktop Account", #selector(nextDesktop), key: "d",
                enabled: profiles.count > 1 && !busy)
        _ = add("Add Claude Desktop Account…", #selector(newProfile), key: "n", enabled: !busy)
    }

    func section(_ title: String, _ accounts: [Account], tool: String, nextKey: String) {
        header(title)
        if accounts.isEmpty {
            _ = add("  Not set up — see Help", #selector(openHelp))
        }
        for a in accounts {
            let mi = add(a.email, #selector(switchTo(_:)), object: [tool, a.id, a.email], enabled: !busy)
            mi.state = a.active ? .on : .off
            twoLine(mi, a.email, a.detail)
        }
        _ = add("Next \(title) Account", #selector(nextAccount(_:)), key: nextKey, object: tool,
                enabled: accounts.count > 1 && !busy)
    }

    // MARK: Claude Desktop actions

    func confirm(_ title: String, _ text: String, _ button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        // A menu bar app is often not allowed to come to the front (macOS 14+), and an alert
        // hidden behind other windows would silently block the app.
        a.window.level = .floating
        return a.runModal() == .alertFirstButtonReturn
    }

    @objc func switchDesktop(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String,
              let target = profiles.first(where: { $0.dir == dir }), !target.active else { return }
        startDesktopSwap(to: target)
    }

    @objc func nextDesktop() {
        guard let target = profiles.first(where: { !$0.active }) else { return }
        startDesktopSwap(to: target)
    }

    func startDesktopSwap(to target: Profile) {
        if isRunning(claudeBundle) && Prefs.confirmDesktopSwitch {
            guard confirm("Switch Claude Desktop to \(target.name)?",
                          "Claude will quit and reopen signed in as \(target.name). Running chats and Code sessions stop; they are still there when you switch back.",
                          "Quit & Switch") else { return }
        }
        busy = true
        rebuild()
        DispatchQueue.global().async {
            let err = swapDesktop(to: target)
            notify("Claude Desktop", err ?? "Switched to \(target.name)")
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }

    @objc func newProfile() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add a Claude Desktop Account"
        alert.informativeText = "Claude will quit and reopen on its sign-in screen. Sign in with the new account. Your current account is kept and stays one click away in this menu."
        alert.addButton(withTitle: "Quit & Add")
        alert.addButton(withTitle: "Cancel")

        let named = activeProfileName() != "Main"
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: named ? 44 : 96))
        stack.orientation = .vertical
        stack.alignment = .leading
        func field(_ label: String, _ placeholder: String, _ value: String = "") -> NSTextField {
            stack.addArrangedSubview(NSTextField(labelWithString: label))
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            f.placeholderString = placeholder
            f.stringValue = value
            f.widthAnchor.constraint(equalToConstant: 260).isActive = true
            stack.addArrangedSubview(f)
            return f
        }
        let newField = field("Name for the new account", "e.g. Work")
        let currentField = named ? nil : field("Name for the current account", "e.g. Personal", "")
        alert.accessoryView = stack
        alert.window.initialFirstResponder = newField
        alert.window.level = .floating
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // The disk is case-insensitive, so "work" would land on Claude-Profile-Work.
        let taken = { (name: String) in self.profiles.contains { $0.name.lowercased() == name.lowercased() } }
        let newName = safeName(newField.stringValue)
        let cur = safeName(currentField?.stringValue ?? "")
        guard !newName.isEmpty, !taken(newName),
              cur.isEmpty || (cur.lowercased() != newName.lowercased() && !taken(cur)) else {
            notify("Claude Desktop", "Pick new, different, non-empty names.")
            return
        }
        let fm = FileManager.default
        let dir = "\(appSupport)/\(parkedPrefix)\(newName)"
        // Must not exist yet: a failed switch deletes this folder again.
        do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: false) } catch {
            notify("Claude Desktop", "Could not create \(dir): \(error.localizedDescription)")
            return
        }
        if !cur.isEmpty { try? cur.write(toFile: "\(activeDir)/\(nameMarker)", atomically: true, encoding: .utf8) }
        busy = true
        rebuild()
        DispatchQueue.global().async {
            let err = swapDesktop(to: Profile(name: newName, dir: dir))
            // Still there and empty means the switch did not happen; remove the placeholder.
            if (try? fm.contentsOfDirectory(atPath: dir))?.isEmpty == true { try? fm.removeItem(atPath: dir) }
            notify("Claude Desktop", err ?? "Sign in as \(newName) in the Claude window")
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }

    // MARK: CLI account actions

    @objc func switchTo(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [String], sender.state != .on else { return }
        perform(tool: v[0], id: v[1], label: v[2])
    }

    @objc func nextAccount(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? String else { return }
        let list = tool == "claude" ? claude : codex
        guard list.count > 1 else { return }
        let i = list.firstIndex { $0.active } ?? -1
        let target = list[(i + 1) % list.count]
        perform(tool: tool, id: target.id, label: target.email)
    }

    func perform(tool: String, id: String, label: String) {
        busy = true
        rebuild()
        let cmd = [tool == "claude" ? "cswap" : "codex-auth", "switch", id]
        DispatchQueue.global().async {
            let result = run(args: cmd)
            var message = result.ok ? "Switched to \(label)" : "Switch failed: \(result.output.suffix(160))"
            if tool == "claude" && result.ok {
                message += " — terminal sessions only; use Claude Desktop above for the app"
            }
            if tool == "codex" && result.ok {
                // codex-auth's background auto-switch undoes a manual switch to an account
                // that is below its threshold. Check, and say so instead of failing silently.
                Thread.sleep(forTimeInterval: 4)
                if let now = loadCodexAccounts().first(where: { $0.active }), now.email != label {
                    message = "Auto-Switch moved you back to \(now.email): \(label) is nearly out of quota. Turn off Codex Auto-Switch to force it."
                }
            }
            notify(tool == "claude" ? "Claude Code" : "Codex", message)
            let active = tool == "codex" ? loadCodexAccounts().first(where: { $0.active })?.email : nil
            DispatchQueue.main.async {
                if tool == "codex" { self.lastCodexActive = active }
                self.busy = false
                self.refresh()
                // Only when the switch stuck: after an Auto-Switch revert the app is already right.
                if tool == "codex" && result.ok && active == label && isRunning(codexBundle) {
                    switch Prefs.codexRestart {
                    // Via the run loop, not this dispatch block: a modal alert inside it would hold
                    // up the main queue, and with it the refresh that clears the busy state.
                    case .ask: RunLoop.main.perform { self.offerCodexRestart() }
                    case .always: self.restartCodex()
                    case .never: break
                    }
                }
            }
        }
    }

    /// The auto-switch daemon only rewrites ~/.codex/auth.json; a running Codex app keeps the old
    /// account (and codex-auth then attributes its usage to the wrong account). Tell the user.
    func noticeBackgroundCodexSwitch() {
        let now = codex.first(where: { $0.active })?.email
        defer { lastCodexActive = now }
        guard Prefs.notifyCodexBackgroundSwitch, !busy, let before = lastCodexActive, let now, now != before,
              isRunning(codexBundle) else { return }
        notify("Codex", "Auto-Switch moved you from \(before) to \(now). Restart the Codex app to use it.")
    }

    func offerCodexRestart() {
        guard confirm("Restart the Codex app?",
                      "The Codex app keeps using the previous account until it restarts. Running Codex tasks will stop. (Change this in Settings.)",
                      "Restart Codex") else { return }
        restartCodex()
    }

    func restartCodex() {
        DispatchQueue.global().async {
            quitApp(codexBundle, timeout: 30)
            run(args: ["open", "-b", codexBundle])
        }
    }

    @objc func toggleCodexAuto() {
        busy = true
        rebuild()
        let enable = !codexAuto
        DispatchQueue.global().async {
            run(args: ["codex-auth", "config", "auto", enable ? "enable" : "disable"])
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }

    // MARK: Misc

    @objc func refreshAction() { refresh() }

    /// The guide the installer copied, or the online README (the DMG installs no local copy).
    @objc func openHelp() {
        let readme = "\(home)/.local/share/account-switcher/README.md"
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: readme)
            ? URL(fileURLWithPath: readme)
            : URL(string: "https://github.com/berkboz/account-switcher#readme")!)
    }

    @objc func openSettings() { settings.show() }
    @objc func openSetup() { onboarding.show() }
}

Prefs.register()

if CommandLine.arguments.contains("--dump") {
    loadProfiles().forEach { print("Desktop", $0.active ? "*" : " ", $0.name, "|", $0.dir) }
    loadClaudeAccounts().forEach { print("Claude ", $0.active ? "*" : " ", $0.email, "|", $0.detail) }
    loadCodexAccounts().forEach { print("Codex  ", $0.active ? "*" : " ", $0.email, "|", $0.detail) }
    print("Codex auto-switch:", CodexAuto.load().on ? "on" : "off")
    exit(0)
}

// Needs ACCOUNT_SWITCHER_ROOT. Add `-shareCodeSessions NO` to test without session sharing.
if let i = CommandLine.arguments.firstIndex(of: "--test-swap"), i + 1 < CommandLine.arguments.count, testMode {
    let name = CommandLine.arguments[i + 1]
    guard let p = loadProfiles().first(where: { $0.name == name }) else { print("no profile", name); exit(1) }
    print(swapDesktop(to: p) ?? "ok")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
