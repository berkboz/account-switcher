using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace AccountSwitcher.Core;

public sealed record Account(string Id, string Email, string Detail, bool Active);

/// Runs the helper CLIs (claude-swap = `cswap`, codex-auth) and parses their output.
public static class Cli
{
    /// Where uv and npm put their tools, which a GUI app's PATH usually lacks.
    static string SearchPath()
    {
        var extra = OperatingSystem.IsWindows()
            ? new[] { Path.Combine(Paths.Home, ".local", "bin"), Path.Combine(Paths.Roaming, "npm") }
            : new[] { Path.Combine(Paths.Home, ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin" };
        return string.Join(Path.PathSeparator, extra.Append(Environment.GetEnvironmentVariable("PATH") ?? ""));
    }

    /// Quotes one argument for the platform shell. Account ids and emails only, but still safe.
    public static string Q(string s) => OperatingSystem.IsWindows()
        ? "\"" + s.Replace("\"", "") + "\""
        : "'" + s.Replace("'", "'\\''") + "'";

    /// Runs a command line through cmd.exe (so npm's .cmd shims resolve) or /bin/sh.
    /// Output is stdout+stderr; a timeout kills the process and counts as failure.
    public static (string Output, bool Ok) Run(string command, int timeoutSeconds = 20)
    {
        var psi = OperatingSystem.IsWindows()
            ? new ProcessStartInfo("cmd.exe", $"/d /s /c \"{command}\"")
            : new ProcessStartInfo("/bin/sh", ["-c", command]);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = psi.StandardErrorEncoding = Encoding.UTF8;
        psi.Environment["PATH"] = SearchPath();
        psi.Environment["NO_COLOR"] = "1";
        try
        {
            using var p = Process.Start(psi)!;
            var output = new StringBuilder();
            p.OutputDataReceived += (_, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
            p.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            if (!p.WaitForExit(timeoutSeconds * 1000))
            {
                try { p.Kill(entireProcessTree: true); } catch { }
                return (output.ToString(), false);
            }
            p.WaitForExit();
            return (output.ToString(), p.ExitCode == 0);
        }
        catch (Exception e) { return (e.Message, false); }
    }

    public static bool Has(string command) =>
        Run(OperatingSystem.IsWindows() ? $"where {command}" : $"command -v {command}", 10).Ok;

    // MARK: Claude Code (claude-swap)

    static string Pct(JsonElement e, string window) =>
        e.TryGetProperty("usage", out var u) && u.ValueKind == JsonValueKind.Object
        && u.TryGetProperty(window, out var w) && w.ValueKind == JsonValueKind.Object
        && w.TryGetProperty("pct", out var p) && p.ValueKind == JsonValueKind.Number
            ? $"{Math.Round(p.GetDouble())}%" : "–";

    public static List<Account> ParseClaude(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("accounts", out var accounts)) return [];
            return accounts.EnumerateArray().Select(a => new Account(
                a.TryGetProperty("number", out var n) ? n.ToString() : "",
                a.TryGetProperty("email", out var e) ? e.GetString() ?? "?" : "?",
                $"used  5h {Pct(a, "fiveHour")} · 7d {Pct(a, "sevenDay")}",
                a.TryGetProperty("active", out var act) && act.ValueKind == JsonValueKind.True)).ToList();
        }
        catch (JsonException) { return []; }
    }

    public static List<Account> LoadClaude() => ParseClaude(Run("cswap list --json", 30).Output);
    public static (string Output, bool Ok) SwitchClaude(string id) => Run($"cswap switch {Q(id)}", 30);

    // MARK: Codex (codex-auth)

    /// Rows look like: "* 01 me@x.com  Business  82% (15:59)  97% (10:59 on 24 Sep)  Now".
    public static List<Account> ParseCodex(string text)
    {
        var list = new List<Account>();
        foreach (var line in text.Split('\n'))
        {
            var t = line.Trim('\r').Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
            var active = t.FirstOrDefault() == "*";
            if (active) t.RemoveAt(0);
            if (t.Count < 3 || !int.TryParse(t[0], out _) || !t[1].Contains('@')) continue;
            var usage = t.Skip(3).Where(x => x.EndsWith('%') || x == "-").ToList();
            list.Add(new Account(t[1], t[1],
                $"{t[2]} · left  5h {usage.ElementAtOrDefault(0) ?? "–"} · wk {usage.ElementAtOrDefault(1) ?? "–"}",
                active));
        }
        return list;
    }

    public static List<Account> LoadCodex() => ParseCodex(Run("codex-auth list --skip-api").Output);
    public static (string Output, bool Ok) SwitchCodex(string email) => Run($"codex-auth switch {Q(email)}", 30);

    public sealed record CodexAuto(bool On, int FiveHour, int Weekly);

    /// From `codex-auth status`: "auto-switch: ON" and "thresholds: 5h<10%, weekly<5%".
    public static CodexAuto ParseCodexAuto(string status)
    {
        static int Num(string s, string prefix, int fallback)
        {
            var i = s.IndexOf(prefix, StringComparison.Ordinal);
            if (i < 0) return fallback;
            var digits = new string(s[(i + prefix.Length)..].TakeWhile(char.IsDigit).ToArray());
            return int.TryParse(digits, out var v) ? v : fallback;
        }
        return new CodexAuto(status.Contains("auto-switch: ON"), Num(status, "5h<", 10), Num(status, "weekly<", 5));
    }

    public static CodexAuto LoadCodexAuto() => ParseCodexAuto(Run("codex-auth status").Output);
    public static bool SetCodexAuto(bool on) => Run($"codex-auth config auto {(on ? "enable" : "disable")}").Ok;
    public static bool SetCodexThresholds(int fiveHour, int weekly) =>
        Run($"codex-auth config auto --5h {fiveHour} --weekly {weekly}").Ok;
}
