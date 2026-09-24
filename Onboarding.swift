import AppKit
import ServiceManagement

// First-run setup window: one row per tool with its state, the single next action
// (install the helper, add an account, get a missing prerequisite) and a "Show in menu" toggle.

func hasCommand(_ name: String) -> Bool { run("command -v \(name)").ok }

/// Opens Terminal running `script` via a throwaway .command file, which needs no Automation
/// permission (unlike telling Terminal to `do script`).
func runInTerminal(_ title: String, _ script: String) {
    let path = NSTemporaryDirectory() + "account-switcher-\(UUID().uuidString.prefix(8)).command"
    let body = """
    #!/bin/zsh
    export PATH="\(shellPath):$PATH"
    clear
    echo "\(title)"
    echo
    \(script)
    echo
    echo "Done. You can close this window and go back to Account Switcher."
    rm -f "$0"
    """
    try? body.write(toFile: path, atomically: true, encoding: .utf8)
    run(args: ["chmod", "+x", path])
    run(args: ["open", "-a", "Terminal", path])
}

struct SetupState {
    var status: String
    var ok: Bool
    var action: String? = nil
    var perform: (() -> Void)? = nil
}

final class OnboardingController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    weak var app: AppDelegate?
    var poll: Timer?
    var installing: Set<String> = []
    var rows: [String: (status: NSTextField, dot: NSTextField, button: NSButton)] = [:]
    var actions: [String: () -> Void] = [:]
    var loginBox: NSButton!
    var showBoxes: [NSButton] = []      // also changed from Settings, so re-read on refresh

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // Picks up logins finished in Terminal and installs finished in the background.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ n: Notification) {
        poll?.invalidate()
        Prefs.d.set(true, forKey: "onboarded")
    }

    // MARK: Layout

    func label(_ text: String, size: CGFloat = NSFont.systemFontSize, bold: Bool = false,
               secondary: Bool = false) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        if secondary { t.textColor = .secondaryLabelColor }
        t.preferredMaxLayoutWidth = 360
        return t
    }

    func toolRow(key: String, title: String, blurb: String, showKey: String) -> NSView {
        let dot = NSTextField(labelWithString: "○")
        dot.font = .systemFont(ofSize: 16)
        let status = label("Checking…", size: NSFont.smallSystemFontSize, secondary: true)
        let button = NSButton(title: "…", target: self, action: #selector(rowAction(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.bezelStyle = .rounded
        let show = NSButton(checkboxWithTitle: "Show in menu", target: self, action: #selector(toggleShow(_:)))
        show.identifier = NSUserInterfaceItemIdentifier(showKey)
        show.state = Prefs.d.bool(forKey: showKey) ? .on : .off
        show.controlSize = .small
        show.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        showBoxes.append(show)
        rows[key] = (status, dot, button)

        let text = NSStackView(views: [label(title, bold: true),
                                       label(blurb, size: NSFont.smallSystemFontSize, secondary: true),
                                       status, show])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [dot, text, spacer, button])
        row.alignment = .top
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return row
    }

    func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return b
    }

    func build() {
        let intro = label("Switch accounts for Claude Desktop, Claude Code and Codex from the menu bar icon. Set up only the parts you use. You can come back here any time: menu → Setup…",
                          secondary: true)
        intro.preferredMaxLayoutWidth = 520
        loginBox = NSButton(checkboxWithTitle: "Open Account Switcher at login", target: self,
                            action: #selector(toggleLogin))
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [loginBox, footerSpacer, done])
        footer.widthAnchor.constraint(equalToConstant: 520).isActive = true

        let title = label("Welcome to Account Switcher", size: 20, bold: true)
        let views: [NSView] = [
            title, intro, separator(),
            toolRow(key: "desktop", title: "Claude Desktop",
                    blurb: "Switching quits and reopens Claude as the other account. Its Code tab follows, and Code sessions can be shared across accounts.",
                    showKey: "showDesktop"),
            separator(),
            toolRow(key: "claude", title: "Claude Code in a terminal",
                    blurb: "For claude in Terminal, iTerm and VS Code. Uses the free claude-swap helper.",
                    showKey: "showClaudeCode"),
            separator(),
            toolRow(key: "codex", title: "Codex",
                    blurb: "For the Codex app and CLI. Uses the free codex-auth helper.",
                    showKey: "showCodex"),
            separator(),
            footer,
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 22, right: 28)
        stack.setCustomSpacing(6, after: title)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 576, height: 10),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Account Switcher Setup"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = stack
        window = w
    }

    // MARK: State

    func refresh() {
        DispatchQueue.global().async {
            let states = ["desktop": self.desktopState(), "claude": self.claudeState(), "codex": self.codexState()]
            DispatchQueue.main.async {
                for (key, st) in states { self.apply(key, st) }
                self.loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
                for b in self.showBoxes {
                    b.state = Prefs.d.bool(forKey: b.identifier?.rawValue ?? "") ? .on : .off
                }
            }
        }
    }

    func apply(_ key: String, _ st: SetupState) {
        guard let r = rows[key] else { return }
        r.status.stringValue = st.status
        r.dot.stringValue = st.ok ? "●" : "○"
        r.dot.textColor = st.ok ? .systemGreen : .tertiaryLabelColor
        r.button.isHidden = st.action == nil
        r.button.title = st.action ?? ""
        actions[key] = st.perform
    }

    func desktopState() -> SetupState {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundle) != nil else {
            return SetupState(status: "Claude Desktop is not installed.", ok: false, action: "Get Claude…") {
                NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!)
            }
        }
        let n = loadProfiles().count
        let add: () -> Void = { [weak self] in self?.app?.newProfile() }
        switch n {
        case 0:
            return SetupState(status: "Open Claude and sign in once, then add your other account here.",
                              ok: false, action: "Open Claude") {
                run(args: ["open", "-b", claudeBundle])
            }
        case 1:
            return SetupState(status: "1 account. Add another to start switching.", ok: false, action: "Add Account…", perform: add)
        default:
            return SetupState(status: "\(n) accounts ready.", ok: true, action: "Add Account…", perform: add)
        }
    }

    func claudeState() -> SetupState {
        if installing.contains("claude") { return SetupState(status: "Installing claude-swap…", ok: false) }
        guard hasCommand("claude") else {
            return SetupState(status: "The Claude Code CLI is not installed. (Not needed for Claude Desktop.)",
                              ok: false, action: "Get Claude Code…") {
                NSWorkspace.shared.open(URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
            }
        }
        guard hasCommand("cswap") else {
            let cmd = hasCommand("uv")
                ? "uv tool install claude-swap"
                : "curl -LsSf https://astral.sh/uv/install.sh | sh && ~/.local/bin/uv tool install claude-swap"
            return SetupState(status: "The claude-swap helper is not installed.", ok: false, action: "Install") {
                [weak self] in self?.install("claude", cmd)
            }
        }
        let accounts = loadClaudeAccounts()
        let add = {
            runInTerminal("Add a Claude Code account. Sign in with that account in your browser.",
                          "claude auth login && cswap add && cswap list")
        }
        switch accounts.count {
        case 0:
            return SetupState(status: "No accounts stored yet. Store the one you are signed in with first.",
                              ok: false, action: "Store Current…") {
                runInTerminal("Storing the Claude Code account you are signed in with.", "cswap add && cswap list")
            }
        case 1:
            return SetupState(status: "1 account (\(accounts[0].email)). Add another to start switching.",
                              ok: false, action: "Add Account…", perform: add)
        default:
            return SetupState(status: "\(accounts.count) accounts ready.", ok: true, action: "Add Account…", perform: add)
        }
    }

    func codexState() -> SetupState {
        if installing.contains("codex") { return SetupState(status: "Installing codex-auth…", ok: false) }
        guard hasCommand("codex-auth") else {
            guard hasCommand("npm") else {
                return SetupState(status: "codex-auth needs Node.js, which is not installed.", ok: false,
                                  action: "Get Node.js…") {
                    NSWorkspace.shared.open(URL(string: "https://nodejs.org/en/download")!)
                }
            }
            return SetupState(status: "The codex-auth helper is not installed.", ok: false, action: "Install") {
                [weak self] in self?.install("codex", "npm install -g @loongphy/codex-auth")
            }
        }
        let accounts = loadCodexAccounts()
        let add = {
            runInTerminal("Add a Codex account. Sign in with that account in your browser.",
                          "codex-auth login && codex-auth list")
        }
        if accounts.count >= 2 {
            return SetupState(status: "\(accounts.count) accounts ready.", ok: true, action: "Add Account…", perform: add)
        }
        return SetupState(status: accounts.isEmpty ? "No accounts yet."
                                                   : "1 account (\(accounts[0].email)). Add another to start switching.",
                          ok: false, action: "Add Account…", perform: add)
    }

    func install(_ key: String, _ command: String) {
        installing.insert(key)
        refresh()
        DispatchQueue.global().async {
            let r = run(command)
            DispatchQueue.main.async {
                self.installing.remove(key)
                if !r.ok {
                    // Usually npm permissions or the network; Terminal shows the real error.
                    runInTerminal("The automatic install failed. Running it here so you can see why:", command)
                }
                self.refresh()
                self.app?.refresh()
            }
        }
    }

    // MARK: Actions

    @objc func rowAction(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        actions[key]?()
        refresh()
    }

    @objc func toggleShow(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        Prefs.d.set(sender.state == .on, forKey: key)
        app?.applySettings()
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister() } else { try s.register() }
        } catch {
            notify("Account Switcher", "Login item error: \(error.localizedDescription)")
        }
        refresh()
    }

    @objc func finish() { window?.close() }
}
