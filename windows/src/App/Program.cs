namespace AccountSwitcher;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        // One tray icon per user session.
        using var mutex = new Mutex(true, @"Local\AccountSwitcher", out var first);
        if (!first) return;

        ApplicationConfiguration.Initialize();
        Application.Run(new Tray(args));
    }
}
