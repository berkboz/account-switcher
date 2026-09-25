namespace AccountSwitcher.Core;

public sealed record Profile(string Name, string Dir)
{
    public bool Active => string.Equals(Path.GetFullPath(Dir), Path.GetFullPath(Paths.ActiveDir),
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
}

/// Quitting and launching Claude Desktop, kept behind an interface so tests run without it.
public interface IDesktopHost
{
    bool IsRunning { get; }
    /// Asks Claude to quit and waits. False if it is still running afterwards.
    bool Quit();
    void Launch();
}

/// For tests and ACCOUNT_SWITCHER_ROOT runs: Claude is never touched.
public sealed class NoDesktopHost : IDesktopHost
{
    public bool IsRunning => false;
    public bool Quit() => true;
    public void Launch() { }
}

// Claude Desktop keeps its whole login inside its data folder and hands it to the Code tab, so
// switching accounts means: quit Claude, park the active data folder as Claude-Profile-<name>,
// move the target into place, reopen.
//
// Shared Code sessions: claude-code-sessions and scratch-workspaces travel with the active
// account — moved, not linked, on every switch — so their real path is always …\Claude\….
// Claude Code files transcripts and project memory under the resolved cwd, so a path that
// changes would split transcripts. Inside the sessions folder every <account>\<org> folder is a
// link to one common _all folder, so every account lists the same sessions.
public static class DesktopProfiles
{
    public static readonly string[] SharedFolders = ["claude-code-sessions", "scratch-workspaces"];
    public const string CommonSessions = "_all";

    public static string ActiveName()
    {
        try
        {
            var name = File.ReadAllText(Path.Combine(Paths.ActiveDir, Paths.NameMarker)).Trim();
            return name.Length > 0 ? name : "Main";
        }
        catch { return "Main"; }
    }

    /// The active profile first, then the parked ones by name.
    public static List<Profile> Load()
    {
        var list = new List<Profile> { new(ActiveName(), Paths.ActiveDir) };
        if (!Directory.Exists(Paths.DataRoot)) return list;
        foreach (var dir in Directory.EnumerateDirectories(Paths.DataRoot, Paths.ParkedPrefix + "*")
                                     .OrderBy(d => d, StringComparer.OrdinalIgnoreCase))
            list.Add(new Profile(Path.GetFileName(dir)[Paths.ParkedPrefix.Length..], dir));
        return list;
    }

    public static string SafeName(string s)
    {
        var bad = Path.GetInvalidFileNameChars().Concat(['/', '\\', ':']).ToHashSet();
        return new string(s.Trim().Select(c => bad.Contains(c) ? '-' : c).ToArray());
    }

    /// Creates an empty parked profile for a new account. Switching to it opens Claude on its
    /// sign-in screen.
    public static Profile CreateEmpty(string name)
    {
        var dir = Path.Combine(Paths.DataRoot, Paths.ParkedPrefix + SafeName(name));
        Directory.CreateDirectory(dir);
        return new Profile(SafeName(name), dir);
    }

    /// Names the active account the first time (it is "Main" until then).
    public static void NameActive(string name)
    {
        if (Directory.Exists(Paths.ActiveDir))
            File.WriteAllText(Path.Combine(Paths.ActiveDir, Paths.NameMarker), SafeName(name));
    }

    /// Quits Claude, parks the active folder, activates `target`, reopens Claude. Returns null on
    /// success, otherwise a message. Every move is undone on failure; a failure while sharing
    /// sessions is reported but does not undo the switch.
    public static string? Swap(Profile target, IDesktopHost host, bool shareSessions)
    {
        var current = ActiveName();
        var parkedCurrent = Path.Combine(Paths.DataRoot, Paths.ParkedPrefix + current);
        if (target.Active) return null;
        if (!Directory.Exists(target.Dir)) return $"Profile folder is missing: {target.Dir}";
        // No active folder: Claude was never opened, or an earlier swap stopped between its two
        // moves. Nothing to park then; just activate the target.
        var hasActive = Directory.Exists(Paths.ActiveDir);
        if (hasActive && FileOps.Exists(parkedCurrent))
            return $"Cannot park the current account: a profile named \"{current}\" already exists.";

        if (host.IsRunning)
        {
            if (!host.Quit()) return "Claude did not quit, so nothing was changed.";
            Thread.Sleep(1000);   // let it release its files
        }

        if (hasActive)
        {
            try { Directory.Move(Paths.ActiveDir, parkedCurrent); }
            catch (Exception e) { return $"Could not park the current account: {e.Message}"; }
            TryWrite(Path.Combine(parkedCurrent, Paths.NameMarker), current);
        }
        try { Directory.Move(target.Dir, Paths.ActiveDir); }
        catch (Exception e)
        {
            if (hasActive) try { Directory.Move(parkedCurrent, Paths.ActiveDir); } catch { }
            return $"Could not activate {target.Name}: {e.Message}";
        }
        TryWrite(Path.Combine(Paths.ActiveDir, Paths.NameMarker), target.Name);

        string? warning = null;
        if (shareSessions)
        {
            try
            {
                CarryShared(hasActive ? parkedCurrent : null, Paths.ActiveDir);
                UnifySessions(Paths.ActiveDir);
            }
            catch (Exception e) { warning = $"Switched, but sharing Code sessions failed: {e.Message}"; }
        }
        host.Launch();
        return warning;
    }

    static void TryWrite(string path, string text)
    {
        try { File.WriteAllText(path, text); } catch { }
    }

    /// Gathers the shared folders into `active` as real folders: the outgoing account's copy
    /// plus whatever `active` had of its own.
    public static void CarryShared(string? parked, string active)
    {
        foreach (var name in SharedFolders)
        {
            var dest = Path.Combine(active, name);
            if (FileOps.IsLink(dest)) FileOps.RemoveLink(dest);
            if (parked == null) continue;
            var src = Path.Combine(parked, name);
            if (FileOps.IsLink(src)) { FileOps.RemoveLink(src); continue; }
            if (Directory.Exists(src)) FileOps.Merge(src, dest);
        }
    }

    /// Makes every <account>\<org> session folder a link to the common one.
    public static void UnifySessions(string active)
    {
        var root = Path.Combine(active, "claude-code-sessions");
        var common = Path.Combine(root, CommonSessions);
        if (!Directory.Exists(root)) return;
        Directory.CreateDirectory(common);
        foreach (var accountDir in Directory.EnumerateDirectories(root).ToList())
        {
            if (Path.GetFileName(accountDir) == CommonSessions || FileOps.IsLink(accountDir)) continue;
            foreach (var orgDir in Directory.EnumerateDirectories(accountDir).ToList())
            {
                if (FileOps.IsLink(orgDir))
                {
                    // Junctions are absolute; one pointing anywhere but the current _all is stale.
                    var t = new DirectoryInfo(orgDir).LinkTarget;
                    if (t == null || Path.GetFullPath(t, accountDir).TrimEnd('\\', '/') == Path.GetFullPath(common).TrimEnd('\\', '/'))
                        continue;
                    FileOps.RemoveLink(orgDir);
                }
                else
                {
                    FileOps.Merge(orgDir, common);
                }
                FileOps.CreateDirLink(orgDir, common);
            }
        }
    }
}
