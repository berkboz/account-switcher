// Runs the Core logic against scratch folders (ACCOUNT_SWITCHER_ROOT), never the real Claude data.
// `dotnet run --project tests/CoreTests` — exits non-zero on the first failure. CI runs this on
// windows-latest, where session links are real directory junctions.
using System.Text.Json.Nodes;
using AccountSwitcher.Core;

var failures = 0;
void Check(bool ok, string what)
{
    Console.WriteLine($"  {(ok ? "ok  " : "FAIL")} {what}");
    if (!ok) failures++;
}

string NewRoot()
{
    var root = Path.Combine(Path.GetTempPath(), "as-test-" + Guid.NewGuid().ToString()[..8]);
    Directory.CreateDirectory(root);
    Environment.SetEnvironmentVariable("ACCOUNT_SWITCHER_ROOT", root);
    return root;
}

void Write(string path, string text)
{
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    File.WriteAllText(path, text);
}

Profile Named(string name) => DesktopProfiles.Load().Single(p => p.Name == name);
var host = new NoDesktopHost();

Console.WriteLine("Swap without sharing");
{
    var root = NewRoot();
    Write(Path.Combine(root, "Claude", "file"), "main-data");
    Write(Path.Combine(root, "Claude-Profile-Work", "file"), "work-data");
    Check(DesktopProfiles.Swap(Named("Work"), host, shareSessions: false) == null, "swap to Work succeeds");
    Check(File.ReadAllText(Path.Combine(root, "Claude", "file")) == "work-data", "Work data is active");
    Check(DesktopProfiles.ActiveName() == "Work", "active name is Work");
    Check(Directory.Exists(Path.Combine(root, "Claude-Profile-Main")), "Main is parked");
    Check(DesktopProfiles.Swap(Named("Main"), host, false) == null, "swap back succeeds");
    Check(File.ReadAllText(Path.Combine(root, "Claude", "file")) == "main-data", "Main data is active again");
    Directory.CreateDirectory(Path.Combine(root, "Claude-Profile-Main"));
    var err = DesktopProfiles.Swap(Named("Work"), host, false);
    Check(err != null && err.Contains("already exists"), "name collision is refused");
    Check(File.ReadAllText(Path.Combine(root, "Claude", "file")) == "main-data", "nothing moved on refusal");
    Directory.Delete(root, true);
}

Console.WriteLine("Swap with shared Code sessions");
{
    var root = NewRoot();
    var a = Path.Combine(root, "Claude", "claude-code-sessions", "acctA", "orgA");
    var b = Path.Combine(root, "Claude-Profile-Work", "claude-code-sessions", "acctB", "orgB");
    Write(Path.Combine(a, "local_s1.json"), """{"sessionId":"s1"}""");
    Write(Path.Combine(b, "local_s2.json"), """{"sessionId":"s2"}""");
    Write(Path.Combine(root, "Claude", "scratch-workspaces", "acctA", "orgA", "ws1", "f"), "work");
    // The failure that actually happened on macOS: a fresh account's empty scheduled-tasks.json,
    // newer than the other account's, must not wipe its schedules.
    Write(Path.Combine(a, "scheduled-tasks.json"), """{"scheduledTasks":[{"id":"daily","cron":"0 9 * * *"}],"flag":true}""");
    File.SetLastWriteTimeUtc(Path.Combine(a, "scheduled-tasks.json"), DateTime.UtcNow.AddDays(-7));
    Write(Path.Combine(b, "scheduled-tasks.json"), """{"scheduledTasks":[],"flag":false}""");
    Write(Path.Combine(a, "archived-sessions.idx"), """{"v":1,"archived":["local_a1"]}""");
    Write(Path.Combine(b, "archived-sessions.idx"), """{"v":1,"archived":["local_b1"]}""");

    Check(DesktopProfiles.Swap(Named("Work"), host, shareSessions: true) == null, "swap to Work succeeds");
    var active = Path.Combine(root, "Claude");
    var all = Path.Combine(active, "claude-code-sessions", DesktopProfiles.CommonSessions);
    var seenByWork = Directory.GetFiles(Path.Combine(active, "claude-code-sessions", "acctB", "orgB"))
                              .Select(Path.GetFileName).ToHashSet();
    Check(seenByWork.Contains("local_s1.json") && seenByWork.Contains("local_s2.json"), "Work sees both sessions");
    Check(FileOps.IsLink(Path.Combine(active, "claude-code-sessions", "acctA", "orgA")), "acctA/orgA is a link");
    Check(!FileOps.IsLink(Path.Combine(active, "claude-code-sessions")), "sessions folder is a real folder");
    Check(!FileOps.IsLink(Path.Combine(active, "scratch-workspaces")), "scratch folder is a real folder");
    Check(File.ReadAllText(Path.Combine(active, "scratch-workspaces", "acctA", "orgA", "ws1", "f")) == "work",
          "scratch folder moved to the active account (same path as before)");
    Check(!Directory.Exists(Path.Combine(root, "Claude-Profile-Main", "claude-code-sessions")), "parked Main holds no sessions");
    var tasks = JsonNode.Parse(File.ReadAllText(Path.Combine(all, "scheduled-tasks.json")))!;
    Check(tasks["scheduledTasks"]!.AsArray().Count == 1, "scheduled task survived the merge");
    var archived = JsonNode.Parse(File.ReadAllText(Path.Combine(all, "archived-sessions.idx")))!["archived"]!.AsArray();
    Check(archived.Count == 2, "archived lists were unioned");
    Check(Directory.Exists(Paths.ConflictsDir) && Directory.GetFileSystemEntries(Paths.ConflictsDir).Length == 2,
          "both replaced state files were set aside, not deleted");

    Write(Path.Combine(active, "claude-code-sessions", "acctB", "orgB", "local_s3.json"), """{"sessionId":"s3"}""");
    Check(DesktopProfiles.Swap(Named("Main"), host, true) == null, "swap back to Main succeeds");
    var seenByMain = Directory.GetFiles(Path.Combine(active, "claude-code-sessions", "acctA", "orgA"))
                              .Select(Path.GetFileName).ToHashSet();
    Check(seenByMain.SetEquals(["local_s1.json", "local_s2.json", "local_s3.json", "scheduled-tasks.json", "archived-sessions.idx"]),
          "Main sees the session made on Work");
    Check(File.ReadAllText(Path.Combine(active, "scratch-workspaces", "acctA", "orgA", "ws1", "f")) == "work",
          "scratch folder followed back");
    Check(DesktopProfiles.Swap(Named("Work"), host, true) == null && DesktopProfiles.Swap(Named("Main"), host, true) == null,
          "repeated swaps are idempotent");
    Check(Directory.GetFiles(all, "local_*").Length == 3, "still exactly three sessions");
    Directory.Delete(root, true);
}

Console.WriteLine("New account");
{
    var root = NewRoot();
    Write(Path.Combine(root, "Claude", "file"), "main");
    DesktopProfiles.NameActive("Personal");
    var p = DesktopProfiles.CreateEmpty("Work/Team:1");
    Check(p.Name == "Work-Team-1", "unsafe characters are replaced");
    Check(DesktopProfiles.Swap(p, host, true) == null, "switching to an empty profile works");
    Check(Directory.Exists(Path.Combine(root, "Claude-Profile-Personal")), "current account parked under its name");
    Directory.Delete(root, true);
}

Console.WriteLine("CLI output parsing");
{
    var codex = Cli.ParseCodex("""
             ACCOUNT               PLAN      5H USAGE      WEEKLY USAGE           LAST ACTIVITY
        ---------------------------------------------------------------------------------------
        * 01 me@work.com           Business  82% (15:59)   97% (10:59 on 24 Sep)  Now
          02 me@home.com           Plus      9% (15:20)    80% (18:42 on 30 Sep)  2m ago
        """.Replace("\n", "\r\n"));
    Check(codex.Count == 2 && codex[0].Active && !codex[1].Active, "codex-auth list: two accounts, first active");
    Check(codex[1].Detail == "Plus · left  5h 9% · wk 80%", "codex-auth list: usage columns");
    var claude = Cli.ParseClaude("""
        {"accounts":[{"number":1,"email":"a@x.com","active":true,"usage":{"fiveHour":{"pct":25.0},"sevenDay":{"pct":59.4}}},
                     {"number":2,"email":"b@x.com","active":false}]}
        """);
    Check(claude.Count == 2 && claude[0].Id == "1" && claude[0].Active, "cswap list --json: accounts");
    Check(claude[0].Detail == "used  5h 25% · 7d 59%" && claude[1].Detail == "used  5h – · 7d –", "cswap list --json: usage");
    Check(Cli.ParseClaude("not json").Count == 0, "bad JSON gives no accounts");
    var auto = Cli.ParseCodexAuto("auto-switch: ON\nservice: running\nthresholds: 5h<15%, weekly<2%\n");
    Check(auto is { On: true, FiveHour: 15, Weekly: 2 }, "codex-auth status: auto-switch + thresholds");
}

if (args.Contains("--live"))
{
    // Read-only: lists the real accounts through the real helper CLIs (no switching).
    Console.WriteLine("Live helpers (read-only)");
    Environment.SetEnvironmentVariable("ACCOUNT_SWITCHER_ROOT", null);
    var c = Cli.LoadClaude();
    var x = Cli.LoadCodex();
    Check(c.Count > 0 && c.Count(a => a.Active) == 1, $"cswap: {c.Count} accounts, one active");
    Check(x.Count > 0 && x.Count(a => a.Active) == 1, $"codex-auth: {x.Count} accounts, one active");
    Check(Cli.Has(OperatingSystem.IsWindows() ? "cmd" : "sh") && !Cli.Has("definitely-not-a-command"), "command lookup");
}

Console.WriteLine(failures == 0 ? "\nAll tests passed." : $"\n{failures} test(s) failed.");
return failures == 0 ? 0 : 1;
