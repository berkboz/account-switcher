using System.Text.Json;
using System.Text.Json.Nodes;

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
// real folder, and on each switch every session file's newest copy is copied into all of them, so
// every account lists the same sessions. They must not be links: Claude refuses to save into a
// junction or symlink there ("Refusing non-directory at private dir path"), while still reading
// through it, so new sessions lived only in memory and were gone after the next quit. 1.1.0 used
// a shared _all folder behind junctions; SyncSessions migrates it.
public static class DesktopProfiles
{
    public static readonly string[] SharedFolders = ["claude-code-sessions", "scratch-workspaces"];
    public const string CommonSessions = "_all";
    public const string ArchiveIndex = "archived-sessions.idx";

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
                SyncSessions(Paths.ActiveDir);
            }
            catch (Exception e) { warning = $"Switched, but sharing Code sessions failed: {e.Message}"; }
        }
        else if (SessionsNeedRepair())
        {
            // Sharing is off, but junctions left by 1.1.0 would still stop Claude from saving.
            try { SyncSessions(Paths.ActiveDir); }
            catch (Exception e) { warning = $"Switched, but repairing Code sessions failed: {e.Message}"; }
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

    /// The real <account>\<org> session folders under `root`, turning a linked one (the 1.1.0
    /// layout) into an empty real folder first. Removing a link never touches its target.
    public static List<string> SessionFolders(string root)
    {
        var list = new List<string>();
        if (!Directory.Exists(root)) return list;
        foreach (var accountDir in Directory.EnumerateDirectories(root).ToList())
        {
            if (Path.GetFileName(accountDir) == CommonSessions || FileOps.IsLink(accountDir)) continue;
            foreach (var orgDir in Directory.EnumerateDirectories(accountDir).ToList())
            {
                if (FileOps.IsLink(orgDir))
                {
                    FileOps.RemoveLink(orgDir);
                    Directory.CreateDirectory(orgDir);
                }
                list.Add(orgDir);
            }
        }
        return list;
    }

    /// Makes every <account>\<org> session folder hold the same sessions: for each file the newest
    /// copy wins, small state files (scheduled-tasks.json) are merged, the archive list is rebuilt, and a
    /// session deleted in one folder since the last sync is removed from the others (set aside,
    /// never deleted). Subfolders only Claude knows about are left alone.
    public static void SyncSessions(string active)
    {
        var root = Path.Combine(active, "claude-code-sessions");
        if (!Directory.Exists(root)) return;
        var folders = SessionFolders(root);
        var legacy = Path.Combine(root, CommonSessions);
        var sources = new List<string>(folders);
        if (Directory.Exists(legacy) && !FileOps.IsLink(legacy)) sources.Add(legacy);
        if (sources.Count == 0) return;

        string Key(string folder) => Path.GetRelativePath(root, folder).Replace('\\', '/');
        static HashSet<string> Files(string folder) => Directory.EnumerateFiles(folder)
            .Where(f => !FileOps.IsLink(f)).Select(f => Path.GetFileName(f))
            .Where(n => !n.StartsWith('.') && !n.Contains(".as-tmp-")).ToHashSet();
        var present = sources.ToDictionary(f => f, Files);

        // Sessions that disappeared from a folder since the last sync were deleted there by Claude.
        var previous = ReadManifest();
        var deleted = new HashSet<string>();
        foreach (var folder in folders)
            if (previous.TryGetValue(Key(folder), out var before))
                deleted.UnionWith(before.Where(n => n.StartsWith("local_") && !present[folder].Contains(n)));

        foreach (var name in present.Values.SelectMany(x => x).Distinct().Where(n => n != ArchiveIndex).ToList())
        {
            var copies = sources.Where(f => present[f].Contains(name)).Select(f => Path.Combine(f, name))
                                .OrderByDescending(File.GetLastWriteTimeUtc).ToList();
            if (deleted.Contains(name))
            {
                foreach (var c in copies) FileOps.SetAside(c);
                continue;
            }
            var newest = copies[0];
            // State files sit next to the sessions under the same name in every folder; merge them
            // so one account's schedules or archive list do not replace another's.
            string? merged = null;
            if (!name.StartsWith("local_") && copies.Count > 1)
            {
                try
                {
                    var values = copies.Select(c => JsonNode.Parse(File.ReadAllText(c))).ToList();
                    merged = values.Skip(1).Aggregate(values[0], (acc, v) => FileOps.MergeJson(acc, v))?.ToJsonString() ?? "null";
                }
                catch (JsonException) { merged = null; }
            }
            foreach (var folder in folders)
            {
                var d = Path.Combine(folder, name);
                if (merged != null)
                {
                    if (!File.Exists(d) || File.ReadAllText(d) != merged) FileOps.WriteAtomic(d, merged);
                }
                else if (d != newest && (!File.Exists(d) || !FileOps.SameContent(d, newest)))
                {
                    FileOps.CopyReplacing(newest, d);
                }
            }
        }

        // Claude's archive list is only a loading hint for the isArchived flag inside each session
        // file. Merging the lists would bring back an archive entry for a session unarchived on the
        // other account, so rebuild it from the sessions as they are now (identical in every folder).
        if (folders.Count > 0 && sources.Any(f => present[f].Contains(ArchiveIndex)))
        {
            var archived = Directory.EnumerateFiles(folders[0], "local_*.json")
                .Where(f =>
                {
                    try { return JsonNode.Parse(File.ReadAllText(f))?["isArchived"]?.GetValue<bool>() == true; }
                    catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException) { return false; }
                })
                .Select(f => Path.GetFileNameWithoutExtension(f)).OrderBy(n => n, StringComparer.Ordinal);
            var index = new JsonObject { ["archived"] = new JsonArray(archived.Select(n => (JsonNode)n).ToArray()), ["v"] = 1 }.ToJsonString();
            foreach (var folder in folders)
            {
                var d = Path.Combine(folder, ArchiveIndex);
                if (!File.Exists(d) || File.ReadAllText(d) != index) FileOps.WriteAtomic(d, index);
            }
        }

        // Every session now lives in the real folders; keep the old shared folder aside, not deleted.
        if (sources.Contains(legacy) && folders.Count > 0) FileOps.SetAside(legacy);
        WriteManifest(folders.ToDictionary(Key, f => Files(f).OrderBy(n => n, StringComparer.Ordinal).ToList()));
    }

    static Dictionary<string, List<string>> ReadManifest()
    {
        try { return JsonSerializer.Deserialize<Dictionary<string, List<string>>>(File.ReadAllText(Paths.SessionManifest)) ?? []; }
        catch { return []; }
    }

    static void WriteManifest(Dictionary<string, List<string>> manifest)
    {
        Directory.CreateDirectory(Paths.AppDir);
        FileOps.WriteAtomic(Paths.SessionManifest, JsonSerializer.Serialize(manifest));
    }

    /// True when a session folder is still a link, which Claude can no longer save into.
    public static bool SessionsNeedRepair()
    {
        var root = Path.Combine(Paths.ActiveDir, "claude-code-sessions");
        try
        {
            return Directory.Exists(root) && Directory.EnumerateDirectories(root)
                .Where(a => Path.GetFileName(a) != CommonSessions && !FileOps.IsLink(a))
                .SelectMany(Directory.EnumerateDirectories).Any(FileOps.IsLink);
        }
        catch { return false; }
    }

    /// Turns linked session folders back into real ones without switching accounts: quits Claude,
    /// syncs, reopens.
    public static string? RepairSessions(IDesktopHost host)
    {
        var wasRunning = host.IsRunning;
        if (wasRunning)
        {
            if (!host.Quit()) return "Claude did not quit, so nothing was changed.";
            Thread.Sleep(1000);
        }
        string? error = null;
        try { SyncSessions(Paths.ActiveDir); }
        catch (Exception e) { error = $"Could not repair Code sessions: {e.Message}"; }
        if (wasRunning) host.Launch();
        return error;
    }
}
