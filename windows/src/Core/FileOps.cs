using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AccountSwitcher.Core;

/// File moves that never lose data: conflicts are merged (JSON) or the losing copy is set aside
/// in Paths.ConflictsDir. Nothing here deletes a real file or folder.
public static class FileOps
{
    /// True for symlinks and, on Windows, directory junctions. Never follows the link.
    public static bool IsLink(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.LinkTarget != null || (info.Exists || Directory.Exists(path))
                && File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint);
        }
        catch { return false; }
    }

    public static bool IsDir(string path) => Directory.Exists(path);   // follows links
    public static bool Exists(string path) => File.Exists(path) || Directory.Exists(path) || IsLink(path);

    /// Removes a link itself, never what it points to.
    public static void RemoveLink(string path)
    {
        if (!IsLink(path)) throw new IOException($"Refusing to remove a non-link: {path}");
        try { File.Delete(path); }
        catch { Directory.Delete(path, recursive: false); }
    }

    public static void Move(string src, string dst)
    {
        if (Directory.Exists(src)) Directory.Move(src, dst);
        else File.Move(src, dst);
    }

    /// A link from `link` to the folder `target`. On Windows a directory junction, which (unlike a
    /// symlink) needs neither admin rights nor Developer Mode; junctions must be absolute.
    /// Elsewhere a relative symlink.
    public static void CreateDirLink(string link, string target)
    {
        if (OperatingSystem.IsWindows())
        {
            var psi = new ProcessStartInfo("cmd.exe", $"/d /c mklink /J \"{link}\" \"{Path.GetFullPath(target)}\"")
            {
                CreateNoWindow = true, UseShellExecute = false,
                RedirectStandardOutput = true, RedirectStandardError = true,
            };
            using var p = Process.Start(psi)!;
            p.WaitForExit();
            if (p.ExitCode != 0) throw new IOException($"mklink /J failed: {p.StandardError.ReadToEnd()}");
        }
        else
        {
            var relative = Path.GetRelativePath(Path.GetDirectoryName(link)!, target);
            Directory.CreateSymbolicLink(link, relative);
        }
    }

    /// Moves `path` into the conflicts folder under a name that cannot clash.
    public static void SetAside(string path)
    {
        Directory.CreateDirectory(Paths.ConflictsDir);
        var name = $"{Path.GetFileName(path)}.{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}-{Guid.NewGuid().ToString()[..8]}";
        Move(path, Path.Combine(Paths.ConflictsDir, name));
    }

    /// Deep-merges two JSON values: objects key by key, arrays as a union (objects deduplicated
    /// by "id"/"taskId"/"sessionId" when present), plain values from `newer`. Each account keeps
    /// same-named state files next to its sessions (scheduled-tasks.json, archived-sessions.idx);
    /// "newer wins" would let a freshly signed-in account's empty file wipe another's schedules.
    public static JsonNode? MergeJson(JsonNode? newer, JsonNode? older)
    {
        if (newer is JsonObject n && older is JsonObject o)
        {
            var result = (JsonObject)o.DeepClone();
            foreach (var (key, value) in n)
                result[key] = result.ContainsKey(key) ? MergeJson(value, result[key]) : value?.DeepClone();
            return result;
        }
        if (newer is JsonArray na && older is JsonArray oa)
        {
            static string Key(JsonNode? x) =>
                x is JsonObject obj && (obj["id"] ?? obj["taskId"] ?? obj["sessionId"]) is { } id
                    ? "id:" + id.ToJsonString()
                    : x?.ToJsonString() ?? "null";
            var result = new JsonArray();
            var seen = new HashSet<string>();
            foreach (var x in na.Concat(oa))
                if (seen.Add(Key(x))) result.Add(x?.DeepClone());
            return result;
        }
        return newer?.DeepClone();
    }

    /// Writes the merge of two JSON files into `dst`. False when either side is not JSON.
    public static bool MergeJsonFiles(string newer, string older, string dst)
    {
        try
        {
            var n = JsonNode.Parse(File.ReadAllText(newer));
            var o = JsonNode.Parse(File.ReadAllText(older));
            var merged = MergeJson(n, o);
            var tmp = dst + ".tmp-" + Guid.NewGuid().ToString()[..8];
            File.WriteAllText(tmp, merged?.ToJsonString() ?? "null");
            File.Move(tmp, dst, overwrite: true);
            return true;
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { return false; }
    }

    static DateTime Modified(string path) =>
        Directory.Exists(path) ? Directory.GetLastWriteTimeUtc(path) : File.GetLastWriteTimeUtc(path);

    /// Moves everything in `src` into `dst`, recursing into folders both sides have. On a conflict
    /// JSON files are merged; otherwise the newer copy takes the place. The other copy is always
    /// set aside. Links are moved as links and never recursed into. `src` is removed afterwards.
    public static void Merge(string src, string dst)
    {
        if (!Exists(dst)) { Move(src, dst); return; }
        foreach (var s in Directory.EnumerateFileSystemEntries(src).ToList())
        {
            var d = Path.Combine(dst, Path.GetFileName(s));
            bool sLink = IsLink(s), dLink = IsLink(d);
            if (!Exists(d))
            {
                if (sLink && !Exists(s)) RemoveLink(s);   // dangling link: holds no data
                else Move(s, d);
            }
            else if (IsDir(s) && IsDir(d) && !sLink && !dLink)
            {
                Merge(s, d);
            }
            else
            {
                bool files = !IsDir(s) && !IsDir(d) && !sLink && !dLink;
                bool sNewer = Modified(s) > Modified(d);
                if (files && MergeJsonFiles(sNewer ? s : d, sNewer ? d : s, d))
                {
                    SetAside(s);
                }
                else if (sNewer && !dLink && files)
                {
                    SetAside(d);
                    Move(s, d);
                }
                else
                {
                    SetAside(s);   // keep what is in place; mismatched kinds or older copy
                }
            }
        }
        Directory.Delete(src, recursive: false);   // empty by now; throws rather than lose anything
    }
}
