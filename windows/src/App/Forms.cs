using System.Diagnostics;
using AccountSwitcher.Core;

namespace AccountSwitcher;

/// Shared layout helpers: a vertical, auto-sized column of controls.
abstract class ColumnForm : Form
{
    protected readonly FlowLayoutPanel Column = new()
    {
        FlowDirection = FlowDirection.TopDown,
        WrapContents = false,
        AutoSize = true,
        AutoSizeMode = AutoSizeMode.GrowAndShrink,
        Padding = new Padding(20, 16, 20, 16),
        Dock = DockStyle.Fill,
    };

    protected ColumnForm(string title)
    {
        Text = title;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Font = SystemFonts.MessageBoxFont ?? Font;
        ShowInTaskbar = true;
        Controls.Add(Column);
    }

    protected Label Heading(string text, float size = 11)
    {
        var l = new Label { Text = text, AutoSize = true, Font = new Font(Font.FontFamily, size, FontStyle.Bold), Margin = new Padding(0, 12, 0, 4) };
        Column.Controls.Add(l);
        return l;
    }

    protected Label Note(string text, int width = 440)
    {
        var l = new Label { Text = text, AutoSize = true, MaximumSize = new Size(width, 0), ForeColor = SystemColors.GrayText, Margin = new Padding(0, 0, 0, 6) };
        Column.Controls.Add(l);
        return l;
    }

    protected CheckBox Check(string text, bool value, Action<bool> changed)
    {
        var c = new CheckBox { Text = text, Checked = value, AutoSize = true };
        c.CheckedChanged += (_, _) => changed(c.Checked);
        Column.Controls.Add(c);
        return c;
    }

    protected ComboBox Choice(string label, string[] items, int selected, Action<int> changed)
    {
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 2, 0, 2) };
        row.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, 6, 8, 0) });
        var box = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 130 };
        box.Items.AddRange(items);
        box.SelectedIndex = Math.Clamp(selected, 0, items.Length - 1);
        box.SelectedIndexChanged += (_, _) => changed(box.SelectedIndex);
        row.Controls.Add(box);
        Column.Controls.Add(row);
        return box;
    }
}

sealed class SettingsForm : ColumnForm
{
    static readonly int[] RefreshChoices = [30, 60, 300];
    static readonly int[] FiveHourChoices = [5, 10, 15, 20, 25, 30];
    static readonly int[] WeeklyChoices = [2, 5, 10, 15, 20];

    public SettingsForm(Tray tray) : base("Account Switcher Settings")
    {
        var s = tray.Settings;
        void Save() => tray.SaveSettings(s);

        Heading("General");
        Note("Show in menu:");
        Check("Claude Desktop", s.ShowDesktop, v => { s.ShowDesktop = v; Save(); });
        Check("Claude Code (Terminal)", s.ShowClaudeCode, v => { s.ShowClaudeCode = v; Save(); });
        Check("Codex", s.ShowCodex, v => { s.ShowCodex = v; Save(); });
        Check("Open at sign-in", Autostart.Enabled, v => Autostart.Enabled = v);
        Choice("Refresh accounts every", ["30 seconds", "1 minute", "5 minutes"],
               Array.IndexOf(RefreshChoices, s.RefreshSeconds) is var i and >= 0 ? i : 1,
               v => { s.RefreshSeconds = RefreshChoices[v]; Save(); });

        Heading("Claude Desktop");
        Check("Share Code sessions across accounts", s.ShareCodeSessions, v => { s.ShareCodeSessions = v; Save(); });
        Note("Every account sees the same Code sessions. Applied at the next switch. Turning it off stops new sharing; sessions already shared stay with the account that is active then.");
        Check("Ask before quitting Claude to switch", s.ConfirmDesktopSwitch, v => { s.ConfirmDesktopSwitch = v; Save(); });

        Heading("Codex");
        Choice("Restart the Codex app after a switch:", ["Ask", "Always", "Never"], (int)s.CodexRestart,
               v => { s.CodexRestart = (CodexRestart)v; Save(); });
        Note("The Codex app keeps the old account until it restarts. Restarting stops running Codex tasks.");
        Check("Notify when Auto-Switch changes the account in the background", s.NotifyCodexBackgroundSwitch,
              v => { s.NotifyCodexBackgroundSwitch = v; Save(); });

        var auto = Cli.LoadCodexAuto();
        ComboBox? five = null, week = null;
        void Thresholds()
        {
            if (five == null || week == null) return;
            if (!Cli.SetCodexThresholds(FiveHourChoices[five.SelectedIndex], WeeklyChoices[week.SelectedIndex]))
                Tray.Notify("Codex", "Could not save the Auto-Switch thresholds.");
        }
        Check("Auto-Switch when an account is nearly out of quota", auto.On, v =>
        {
            Cli.SetCodexAuto(v);
            five!.Enabled = week!.Enabled = v;
            tray.Refresh();
        });
        Note("Handled by codex-auth. It also undoes a manual switch to an account below these limits.");
        five = Choice("Switch when 5-hour quota left is below", FiveHourChoices.Select(x => $"{x}%").ToArray(),
                      Array.IndexOf(FiveHourChoices, auto.FiveHour) is var f and >= 0 ? f : 1, _ => Thresholds());
        week = Choice("or weekly quota left is below", WeeklyChoices.Select(x => $"{x}%").ToArray(),
                      Array.IndexOf(WeeklyChoices, auto.Weekly) is var w and >= 0 ? w : 1, _ => Thresholds());
        five.Enabled = week.Enabled = auto.On;
    }
}

/// First-run setup: one row per tool with its state, the next action, and "Show in menu".
sealed class SetupForm : ColumnForm
{
    sealed record State(string Status, bool Ok, string? Action = null, Action? Perform = null);

    readonly Tray tray;
    readonly Dictionary<string, (Label Status, Label Dot, Button Button)> rows = [];
    readonly Dictionary<string, Action?> actions = [];
    readonly HashSet<string> installing = [];
    readonly System.Windows.Forms.Timer poll = new() { Interval = 3000 };

    public SetupForm(Tray tray) : base("Account Switcher Setup")
    {
        this.tray = tray;
        Heading("Welcome to Account Switcher", 15);
        Note("Switch accounts for Claude Desktop, Claude Code and Codex from the tray icon. Set up only the parts you use. You can come back here any time: tray menu → Setup…", 520);
        Row("desktop", "Claude Desktop",
            "Switching quits and reopens Claude as the other account. Its Code tab follows, and Code sessions can be shared across accounts.",
            tray.Settings.ShowDesktop, v => tray.Settings.ShowDesktop = v);
        Row("claude", "Claude Code in a terminal",
            "For claude in Windows Terminal, PowerShell and VS Code. Uses the free claude-swap helper.",
            tray.Settings.ShowClaudeCode, v => tray.Settings.ShowClaudeCode = v);
        Row("codex", "Codex", "For the Codex app and CLI. Uses the free codex-auth helper.",
            tray.Settings.ShowCodex, v => tray.Settings.ShowCodex = v);

        var footer = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 14, 0, 0) };
        var login = new CheckBox { Text = "Open Account Switcher at sign-in", Checked = Autostart.Enabled, AutoSize = true, Margin = new Padding(0, 6, 180, 0) };
        login.CheckedChanged += (_, _) => Autostart.Enabled = login.Checked;
        var done = new Button { Text = "Done", AutoSize = true, DialogResult = DialogResult.OK };
        done.Click += (_, _) => Close();
        footer.Controls.Add(login);
        footer.Controls.Add(done);
        Column.Controls.Add(footer);
        AcceptButton = done;

        poll.Tick += (_, _) => RefreshStates();   // picks up sign-ins finished in the console
        Shown += (_, _) => { RefreshStates(); poll.Start(); };
        FormClosed += (_, _) => poll.Dispose();
    }

    void Row(string key, string title, string blurb, bool show, Action<bool> setShow)
    {
        var row = new TableLayoutPanel { ColumnCount = 3, AutoSize = true, Margin = new Padding(0, 10, 0, 0), Width = 540 };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 24));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 380));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var dot = new Label { Text = "○", AutoSize = true, Font = new Font(Font.FontFamily, 12), ForeColor = SystemColors.GrayText };
        var text = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true };
        text.Controls.Add(new Label { Text = title, AutoSize = true, Font = new Font(Font, FontStyle.Bold) });
        text.Controls.Add(new Label { Text = blurb, AutoSize = true, MaximumSize = new Size(370, 0), ForeColor = SystemColors.GrayText });
        var status = new Label { Text = "Checking…", AutoSize = true, MaximumSize = new Size(370, 0), Margin = new Padding(3, 4, 3, 0) };
        text.Controls.Add(status);
        var box = new CheckBox { Text = "Show in menu", Checked = show, AutoSize = true };
        box.CheckedChanged += (_, _) => { setShow(box.Checked); tray.SaveSettings(tray.Settings); };
        text.Controls.Add(box);
        var button = new Button { Text = "…", AutoSize = true, Visible = false };
        button.Click += (_, _) => { actions.GetValueOrDefault(key)?.Invoke(); RefreshStates(); };
        row.Controls.Add(dot, 0, 0);
        row.Controls.Add(text, 1, 0);
        row.Controls.Add(button, 2, 0);
        rows[key] = (status, dot, button);
        Column.Controls.Add(new Label { BorderStyle = BorderStyle.Fixed3D, Height = 2, Width = 540, Margin = new Padding(0, 8, 0, 0) });
        Column.Controls.Add(row);
    }

    void RefreshStates()
    {
        Task.Run(() => new Dictionary<string, State>
        {
            ["desktop"] = DesktopState(), ["claude"] = ClaudeState(), ["codex"] = CodexState(),
        }).ContinueWith(t =>
        {
            if (IsDisposed || t.Result == null) return;
            foreach (var (key, st) in t.Result)
            {
                var r = rows[key];
                r.Status.Text = st.Status;
                r.Dot.Text = st.Ok ? "●" : "○";
                r.Dot.ForeColor = st.Ok ? Color.SeaGreen : SystemColors.GrayText;
                r.Button.Visible = st.Action != null;
                r.Button.Text = st.Action ?? "";
                actions[key] = st.Perform;
            }
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    static void Open(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });

    State DesktopState()
    {
        if (!ClaudeDesktop.IsInstalled)
            return new("Claude Desktop is not installed.", false, "Get Claude…", () => Open("https://claude.ai/download"));
        var n = DesktopProfiles.Load().Count;
        Action add = () => BeginInvoke(tray.AddDesktopAccount);
        return n < 2
            ? new("1 account. Add another to start switching.", false, "Add Account…", add)
            : new($"{n} accounts ready.", true, "Add Account…", add);
    }

    State ClaudeState()
    {
        if (installing.Contains("claude")) return new("Installing claude-swap…", false);
        if (!Cli.Has("claude"))
            return new("The Claude Code CLI is not installed. (Not needed for Claude Desktop.)", false,
                       "Get Claude Code…", () => Open("https://docs.claude.com/en/docs/claude-code/setup"));
        if (!Cli.Has("cswap"))
        {
            var cmd = Cli.Has("uv")
                ? "uv tool install claude-swap"
                : "powershell -NoProfile -ExecutionPolicy ByPass -c \"irm https://astral.sh/uv/install.ps1 | iex\" && \"%USERPROFILE%\\.local\\bin\\uv.exe\" tool install claude-swap";
            return new("The claude-swap helper is not installed.", false, "Install", () => Install("claude", cmd));
        }
        var accounts = Cli.LoadClaude();
        Action add = () => Terminal.Open("Add a Claude Code account", "claude auth login && cswap add && cswap list");
        return accounts.Count switch
        {
            0 => new("No accounts stored yet. Store the one you are signed in with first.", false, "Store Current…",
                     () => Terminal.Open("Store the current Claude Code account", "cswap add && cswap list")),
            1 => new($"1 account ({accounts[0].Email}). Add another to start switching.", false, "Add Account…", add),
            var n => new($"{n} accounts ready.", true, "Add Account…", add),
        };
    }

    State CodexState()
    {
        if (installing.Contains("codex")) return new("Installing codex-auth…", false);
        if (!Cli.Has("codex-auth"))
        {
            if (!Cli.Has("npm"))
                return new("codex-auth needs Node.js, which is not installed.", false, "Get Node.js…",
                           () => Open("https://nodejs.org/en/download"));
            return new("The codex-auth helper is not installed.", false, "Install",
                       () => Install("codex", "npm install -g @loongphy/codex-auth"));
        }
        var accounts = Cli.LoadCodex();
        Action add = () => Terminal.Open("Add a Codex account", "codex-auth login && codex-auth list");
        return accounts.Count >= 2
            ? new($"{accounts.Count} accounts ready.", true, "Add Account…", add)
            : new(accounts.Count == 0 ? "No accounts yet." : $"1 account ({accounts[0].Email}). Add another to start switching.",
                  false, "Add Account…", add);
    }

    void Install(string key, string command)
    {
        installing.Add(key);
        Task.Run(() => Cli.Run(command, 300)).ContinueWith(t =>
        {
            installing.Remove(key);
            // Usually npm permissions or the network; the console shows the real error.
            if (!t.Result.Ok) Terminal.Open("The automatic install failed. Running it here so you can see why", command);
            RefreshStates();
            tray.Refresh();
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }
}

sealed class AddAccountDialog : ColumnForm
{
    readonly TextBox newName = new() { Width = 260, PlaceholderText = "e.g. Work" };
    readonly TextBox currentName = new() { Width = 260, PlaceholderText = "e.g. Personal" };

    public string NewName => newName.Text;
    public string CurrentName => currentName.Text;

    public AddAccountDialog(bool askCurrentName) : base("Add a Claude Desktop Account")
    {
        ShowInTaskbar = false;
        Note("Claude will quit and reopen on its sign-in screen. Sign in with the new account. Your current account is kept and stays one click away in the tray menu.", 300);
        Column.Controls.Add(new Label { Text = "Name for the new account", AutoSize = true });
        Column.Controls.Add(newName);
        if (askCurrentName)
        {
            Column.Controls.Add(new Label { Text = "Name for the current account", AutoSize = true, Margin = new Padding(3, 10, 3, 0) });
            Column.Controls.Add(currentName);
        }
        var buttons = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(0, 14, 0, 0) };
        var ok = new Button { Text = "Quit && Add", DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true };
        buttons.Controls.Add(ok);
        buttons.Controls.Add(cancel);
        Column.Controls.Add(buttons);
        AcceptButton = ok;
        CancelButton = cancel;
    }
}
