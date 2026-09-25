namespace AccountSwitcher.Core;

/// Where everything lives. ACCOUNT_SWITCHER_ROOT and ACCOUNT_SWITCHER_CLAUDE_HOME redirect the
/// data folders so the swap and session sharing can be exercised against a scratch folder
/// (the tests do this) without touching Claude.
public static class Paths
{
    static string? Env(string key) => Environment.GetEnvironmentVariable(key);

    public static bool TestMode => Env("ACCOUNT_SWITCHER_ROOT") != null;

    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static string Roaming => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    public static string Local => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    /// The folder that holds Claude Desktop's data folder ("Claude") and the parked ones.
    /// A regular install uses %APPDATA%; the Microsoft Store (MSIX) build is virtualized into
    /// %LOCALAPPDATA%\Packages\<package>\LocalCache\Roaming.
    public static string DataRoot => Env("ACCOUNT_SWITCHER_ROOT") ?? DetectDataRoot();

    static string DetectDataRoot()
    {
        var packages = Path.Combine(Local, "Packages");
        if (Directory.Exists(packages))
        {
            foreach (var pkg in Directory.EnumerateDirectories(packages, "*Claude*"))
            {
                var roaming = Path.Combine(pkg, "LocalCache", "Roaming");
                if (Directory.Exists(Path.Combine(roaming, "Claude"))) return roaming;
            }
        }
        return Roaming;
    }

    public static string ActiveDir => Path.Combine(DataRoot, "Claude");
    public const string ParkedPrefix = "Claude-Profile-";
    public const string NameMarker = ".account-switcher-name";

    /// Settings and conflict copies. Kept outside the Claude folders so a swap never moves them.
    public static string AppDir => TestMode
        ? Path.Combine(DataRoot, "Account Switcher")
        : Path.Combine(Roaming, "Account Switcher");

    public static string ConflictsDir => Path.Combine(AppDir, "conflicts");
    public static string SettingsFile => Path.Combine(AppDir, "settings.json");

    public static string ClaudeHome =>
        Env("ACCOUNT_SWITCHER_CLAUDE_HOME") ?? Env("CLAUDE_CONFIG_DIR") ?? Path.Combine(Home, ".claude");
}
