using System.Diagnostics;
using AccountSwitcher.Core;
using Microsoft.Win32;

namespace AccountSwitcher;

/// Finds, quits and relaunches a desktop app by process name. Electron apps run many processes
/// with the same name; only the one with a main window can be asked to close.
class DesktopApp(params string[] processNames)
{
    string? lastExe;

    protected Process[] Processes() => processNames.SelectMany(Process.GetProcessesByName).ToArray();

    public bool IsRunning => Processes().Length > 0;

    /// Asks every window to close, then waits. Returns whether the app is gone.
    public bool Close(TimeSpan wait)
    {
        foreach (var p in Processes())
        {
            try { lastExe ??= p.MainModule?.FileName; } catch { }
            try { if (p.MainWindowHandle != IntPtr.Zero) p.CloseMainWindow(); } catch { }
        }
        return WaitGone(wait);
    }

    public bool Kill(TimeSpan wait)
    {
        foreach (var p in Processes())
            try { p.Kill(entireProcessTree: true); } catch { }
        return WaitGone(wait);
    }

    bool WaitGone(TimeSpan wait)
    {
        var deadline = DateTime.UtcNow + wait;
        while (IsRunning && DateTime.UtcNow < deadline) Thread.Sleep(500);
        return !IsRunning;
    }

    /// Relaunches the executable seen when closing, else the first known install location.
    public bool Launch(params string[] fallbacks)
    {
        var exe = lastExe ?? fallbacks.FirstOrDefault(File.Exists);
        if (exe == null) return false;
        try { Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true }); return true; }
        catch { return false; }
    }
}

/// Claude Desktop. Closing its window can leave it running in the tray, so when a normal close
/// does not end it, `ConfirmForceQuit` asks the user before ending the processes.
sealed class ClaudeDesktop() : DesktopApp("Claude"), IDesktopHost
{
    public Func<bool> ConfirmForceQuit { get; set; } = () => false;

    public static string[] InstallLocations =>
    [
        Path.Combine(Paths.Local, "AnthropicClaude", "claude.exe"),
        Path.Combine(Paths.Local, "Programs", "Claude", "Claude.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Claude", "Claude.exe"),
    ];

    public static bool IsInstalled =>
        InstallLocations.Any(File.Exists) || Paths.DataRoot != Paths.Roaming   // MSIX build found
        || Directory.Exists(Paths.ActiveDir);

    public bool Quit()
    {
        if (Close(TimeSpan.FromSeconds(20))) return true;
        return ConfirmForceQuit() && Kill(TimeSpan.FromSeconds(10));
    }

    public void Launch()
    {
        if (!Launch(InstallLocations))
            Tray.Notify("Claude Desktop", "Switched. Open Claude from the Start menu.");
    }
}

/// The Codex app (it may run as "Codex" or inside the ChatGPT app).
sealed class CodexApp() : DesktopApp("Codex", "ChatGPT")
{
    public bool Restart()
    {
        if (!Close(TimeSpan.FromSeconds(15))) return false;
        Thread.Sleep(500);
        return Launch();
    }
}

static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "Account Switcher";

    public static bool Enabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(Name, $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue(Name, throwOnMissingValue: false);
        }
    }
}

static class Terminal
{
    /// Opens a console window running `commands`, with the helper tools on PATH. Used for the
    /// browser sign-in flows, which need a visible terminal.
    public static void Open(string title, string commands)
    {
        var psi = new ProcessStartInfo("cmd.exe", $"/d /k \"title {title} & echo {title} & echo. & {commands}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = false,
        };
        var extra = $"{Path.Combine(Paths.Home, ".local", "bin")};{Path.Combine(Paths.Roaming, "npm")}";
        psi.Environment["PATH"] = extra + ";" + Environment.GetEnvironmentVariable("PATH");
        try { Process.Start(psi); } catch (Exception e) { Tray.Notify("Account Switcher", e.Message); }
    }
}
