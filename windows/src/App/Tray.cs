using System.Reflection;
using AccountSwitcher.Core;

namespace AccountSwitcher;

/// The tray icon and its menu: Claude Desktop accounts, Claude Code (terminal) accounts via
/// claude-swap, Codex accounts via codex-auth. Mirrors the macOS menu bar app.
sealed class Tray : ApplicationContext
{
    static Tray? instance;

    readonly NotifyIcon icon;
    readonly ContextMenuStrip menu = new();
    readonly SynchronizationContext ui;
    readonly System.Windows.Forms.Timer timer = new();
    readonly ClaudeDesktop desktop = new();
    readonly CodexApp codexApp = new();

    public Settings Settings { get; private set; } = Settings.Load();
    List<Profile> profiles = [];
    List<Account> claude = [], codex = [];
    bool codexAuto, busy;
    string? lastCodexActive;   // to notice switches made by codex-auth's background daemon
    SettingsForm? settingsForm;
    SetupForm? setupForm;

    public Tray(string[] args)
    {
        instance = this;
        ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        desktop.ConfirmForceQuit = () => OnUi(() => MessageBox.Show(
            "Claude is still running (it may be in the system tray). End it now to finish the switch?",
            "Account Switcher", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes);

        icon = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "Account Switcher",
            ContextMenuStrip = menu,
            Visible = true,
        };
        // Left click opens the same menu as right click.
        icon.MouseUp += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)
                ?.Invoke(icon, null);
        };
        menu.Opening += (_, _) => Refresh();
        timer.Tick += (_, _) => Refresh();

        ApplySettings();
        if (args.Contains("--setup") || !Settings.Onboarded) ShowSetup();
        if (args.Contains("--settings")) ShowSettings();
    }

    static Icon LoadIcon()
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("AppIcon.ico");
        return s != null ? new Icon(s, SystemInformation.SmallIconSize) : SystemIcons.Application;
    }

    public static void Notify(string title, string text) =>
        instance?.ui.Post(_ => instance.icon.ShowBalloonTip(5000, title, text, ToolTipIcon.None), null);

    T OnUi<T>(Func<T> f)
    {
        T result = default!;
        ui.Send(_ => result = f(), null);
        return result;
    }

    public void SaveSettings(Settings s)
    {
        Settings = s;
        s.Save();
        ApplySettings();
    }

    public void ApplySettings()
    {
        timer.Interval = Math.Max(10, Settings.RefreshSeconds) * 1000;
        timer.Start();
        Rebuild();
        Refresh();
    }

    public void Refresh()
    {
        Task.Run(() =>
        {
            var p = DesktopProfiles.Load();
            var c = Settings.ShowClaudeCode ? Cli.LoadClaude() : [];
            var x = Settings.ShowCodex ? Cli.LoadCodex() : [];
            var a = Settings.ShowCodex && Cli.LoadCodexAuto().On;
            ui.Post(_ =>
            {
                profiles = p; claude = c; codex = x; codexAuto = a;
                NoticeBackgroundCodexSwitch();
                Rebuild();
            }, null);
        });
    }

    // MARK: Menu

    void Header(string title, string? note = null)
    {
        var label = new ToolStripLabel(title) { Font = new Font(menu.Font, FontStyle.Bold) };
        if (note != null) label.ToolTipText = note;
        menu.Items.Add(label);
    }

    ToolStripMenuItem Item(string text, Action onClick, bool enabled = true, string? detail = null, bool check = false)
    {
        var item = new ToolStripMenuItem(text) { Enabled = enabled, Checked = check };
        if (detail != null) { item.ShortcutKeyDisplayString = detail; item.ToolTipText = detail; }
        item.Click += (_, _) => onClick();
        menu.Items.Add(item);
        return item;
    }

    void Rebuild()
    {
        menu.SuspendLayout();
        menu.Items.Clear();

        if (Settings.ShowDesktop)
        {
            Header("Claude Desktop", "Includes its Code tab");
            foreach (var p in profiles)
                Item(p.Name, () => SwitchDesktop(p), !busy && !p.Active,
                     p.Active ? "signed in now" : "quits and reopens Claude", p.Active);
            Item("Next Claude Desktop Account", () => SwitchDesktop(profiles[1]), profiles.Count > 1 && !busy);
            Item("Add Claude Desktop Account…", AddDesktopAccount, !busy);
            menu.Items.Add(new ToolStripSeparator());
        }
        if (Settings.ShowClaudeCode)
        {
            Section("Claude Code (Terminal)", claude, "claude");
            menu.Items.Add(new ToolStripSeparator());
        }
        if (Settings.ShowCodex)
        {
            Section("Codex", codex, "codex");
            Item("Codex Auto-Switch", ToggleCodexAuto, codex.Count > 0 && !busy, check: codexAuto).ToolTipText =
                "codex-auth moves you to another account when the current one is nearly out of quota. It also undoes manual switches to an account below the threshold.";
            menu.Items.Add(new ToolStripSeparator());
        }
        Item("Setup…", ShowSetup);
        Item("Settings…", ShowSettings);
        Item("Help", () => Open("https://github.com/berkboz/account-switcher/blob/main/windows/README.md"));
        Item("Refresh", Refresh);
        Item("Quit", () => { icon.Visible = false; Application.Exit(); });
        menu.ResumeLayout();
    }

    void Section(string title, List<Account> accounts, string tool)
    {
        Header(title);
        if (accounts.Count == 0) Item("   Not set up — open Setup", ShowSetup);
        foreach (var a in accounts)
            Item(a.Email, () => SwitchCli(tool, a), !busy && !a.Active, a.Detail, a.Active);
        Item($"Next {title} Account", () =>
        {
            var i = accounts.FindIndex(a => a.Active);
            SwitchCli(tool, accounts[(i + 1) % accounts.Count]);
        }, accounts.Count > 1 && !busy);
    }

    static void Open(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { }
    }

    void SetBusy(bool value) { busy = value; Rebuild(); }

    // MARK: Claude Desktop

    void SwitchDesktop(Profile target)
    {
        if (target.Active) return;
        if (desktop.IsRunning && Settings.ConfirmDesktopSwitch &&
            MessageBox.Show($"Claude will quit and reopen signed in as {target.Name}. Running chats and Code sessions stop; they are still there when you switch back.",
                            $"Switch Claude Desktop to {target.Name}?", MessageBoxButtons.OKCancel,
                            MessageBoxIcon.Question) != DialogResult.OK)
            return;
        RunSwap(target, cleanupOnError: false);
    }

    void RunSwap(Profile target, bool cleanupOnError)
    {
        SetBusy(true);
        var share = Settings.ShareCodeSessions;
        Task.Run(() =>
        {
            var error = DesktopProfiles.Swap(target, desktop, share);
            if (error != null && cleanupOnError)
                try { Directory.Delete(target.Dir); } catch { }   // only if still empty
            Notify("Claude Desktop", error ?? $"Switched to {target.Name}");
            ui.Post(_ => { SetBusy(false); Refresh(); }, null);
        });
    }

    public void AddDesktopAccount()
    {
        var needsCurrentName = DesktopProfiles.ActiveName() == "Main";
        using var dialog = new AddAccountDialog(needsCurrentName);
        if (dialog.ShowDialog() != DialogResult.OK) return;
        var name = DesktopProfiles.SafeName(dialog.NewName);
        if (name.Length == 0 || profiles.Any(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
        {
            MessageBox.Show("Pick a new, non-empty name.", "Account Switcher");
            return;
        }
        if (needsCurrentName && DesktopProfiles.SafeName(dialog.CurrentName) is { Length: > 0 } current && current != name)
            DesktopProfiles.NameActive(current);
        RunSwap(DesktopProfiles.CreateEmpty(name), cleanupOnError: true);
    }

    // MARK: Claude Code / Codex

    void SwitchCli(string tool, Account target)
    {
        if (target.Active) return;
        SetBusy(true);
        Task.Run(() =>
        {
            var (output, ok) = tool == "claude" ? Cli.SwitchClaude(target.Id) : Cli.SwitchCodex(target.Id);
            var message = ok ? $"Switched to {target.Email}" : $"Switch failed: {Tail(output)}";
            string? nowActive = null;
            if (ok && tool == "claude")
                message += " — terminal sessions only; use Claude Desktop for the app";
            if (ok && tool == "codex")
            {
                // codex-auth's auto-switch undoes a manual switch to an account below its
                // threshold. Check, and say so instead of failing silently.
                Thread.Sleep(4000);
                nowActive = Cli.LoadCodex().FirstOrDefault(a => a.Active)?.Email;
                if (nowActive != null && nowActive != target.Email)
                    message = $"Auto-Switch moved you back to {nowActive}: {target.Email} is nearly out of quota. Turn off Codex Auto-Switch to force it.";
            }
            Notify(tool == "claude" ? "Claude Code" : "Codex", message);
            ui.Post(_ =>
            {
                if (tool == "codex") lastCodexActive = nowActive;
                SetBusy(false);
                Refresh();
                if (tool == "codex" && ok && nowActive == target.Email && codexApp.IsRunning) OfferCodexRestart();
            }, null);
        });
    }

    static string Tail(string s) => s.Trim().Length > 160 ? s.Trim()[^160..] : s.Trim();

    void OfferCodexRestart()
    {
        switch (Settings.CodexRestart)
        {
            case CodexRestart.Never: return;
            case CodexRestart.Ask when MessageBox.Show(
                "The Codex app keeps using the previous account until it restarts. Running Codex tasks will stop. (Change this in Settings.)",
                "Restart the Codex app?", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK:
                return;
        }
        Task.Run(() =>
        {
            if (!codexApp.Restart()) Notify("Codex", "Could not restart the Codex app. Close and reopen it yourself.");
        });
    }

    /// The auto-switch daemon only rewrites codex's auth file; a running Codex app keeps the old
    /// account. Tell the user.
    void NoticeBackgroundCodexSwitch()
    {
        var now = codex.FirstOrDefault(a => a.Active)?.Email;
        var before = lastCodexActive;
        lastCodexActive = now;
        if (!Settings.NotifyCodexBackgroundSwitch || busy || before == null || now == null || now == before) return;
        if (codexApp.IsRunning)
            Notify("Codex", $"Auto-Switch moved you from {before} to {now}. Restart the Codex app to use it.");
    }

    void ToggleCodexAuto()
    {
        var enable = !codexAuto;
        SetBusy(true);
        Task.Run(() =>
        {
            Cli.SetCodexAuto(enable);
            ui.Post(_ => { SetBusy(false); Refresh(); }, null);
        });
    }

    // MARK: Windows

    public void ShowSettings()
    {
        if (settingsForm is { IsDisposed: false }) { settingsForm.Activate(); return; }
        settingsForm = new SettingsForm(this);
        settingsForm.Show();
    }

    public void ShowSetup()
    {
        if (setupForm is { IsDisposed: false }) { setupForm.Activate(); return; }
        setupForm = new SetupForm(this);
        setupForm.FormClosed += (_, _) =>
        {
            if (!Settings.Onboarded) { Settings.Onboarded = true; Settings.Save(); }
        };
        setupForm.Show();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { icon.Visible = false; icon.Dispose(); menu.Dispose(); timer.Dispose(); }
        base.Dispose(disposing);
    }
}
