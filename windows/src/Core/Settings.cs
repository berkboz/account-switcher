using System.Text.Json;

namespace AccountSwitcher.Core;

public enum CodexRestart { Ask, Always, Never }

/// User preferences, stored as JSON in %APPDATA%\Account Switcher\settings.json.
/// Codex Auto-Switch lives in codex-auth's own config, not here.
public sealed class Settings
{
    public bool ShowDesktop { get; set; } = true;
    public bool ShowClaudeCode { get; set; } = true;
    public bool ShowCodex { get; set; } = true;
    public int RefreshSeconds { get; set; } = 60;
    public bool ShareCodeSessions { get; set; } = true;
    public bool ConfirmDesktopSwitch { get; set; } = true;
    public CodexRestart CodexRestart { get; set; } = CodexRestart.Ask;
    public bool NotifyCodexBackgroundSwitch { get; set; } = true;
    public bool Onboarded { get; set; }

    static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(Paths.SettingsFile)) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Paths.AppDir);
        File.WriteAllText(Paths.SettingsFile, JsonSerializer.Serialize(this, Options));
    }
}
