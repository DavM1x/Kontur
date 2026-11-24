using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Удаление «Контура»")]

internal static class UninstallLauncher {
    [STAThread]
    private static void Main(string[] args) {
        try {
            var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Uninstall.ps1");
            var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            var powershell = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");
            var options = "-NoProfile -ExecutionPolicy Bypass -File \"" + path + "\" -LauncherPid " +
                Process.GetCurrentProcess().Id;
            if (args.Length == 1 && args[0] == "--quiet") options += " -Quiet";
            using (Process.Start(new ProcessStartInfo(powershell, options) {
                UseShellExecute = false, CreateNoWindow = true,
            })) { }
        } catch (Exception error) {
            MessageBox.Show(error.Message, "Удаление «Контура»", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }
    }
}
