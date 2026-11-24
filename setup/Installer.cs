using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

internal static class Installer {
    private const string ListingName = ".kontur-files.txt";
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Kontur";
    private static readonly string LegacyPath = @"D:\WallpaperStudio";
    private static readonly string[] RetiredAssets = {
        @"assets\desert.jpg", @"assets\forest.jpg", @"assets\lake.jpg", @"assets\meadow.png",
        @"assets\mountains.jpg", @"assets\night.jpg", @"assets\ocean.jpg", @"ui\buttons.css", @"ui\themes.css", @"ui\meteors.css",
        @"assets\theme-day.png", @"assets\theme-night.png", @"assets\day.wav", @"assets\night.wav", @"assets\PixelifySans-LICENSE.txt",
        @"ui\appearance.js", @"ui\full.css",
    };

    public static string DefaultPath() {
#if SETUP_TEST
        return Path.Combine(Environment.GetEnvironmentVariable("KONTUR_SETUP_TEST_ROOT"), "установка Контур");
#else
        using (var key = Registry.CurrentUser.OpenSubKey(UninstallKey)) {
            var path = key == null ? null : key.GetValue("InstallLocation") as string;
            if (!String.IsNullOrEmpty(path) && IsKontur(path)) return path;
        }
        if (IsKontur(LegacyPath)) return LegacyPath;
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Kontur");
#endif
    }

    public static bool IsKontur(string path) {
        return File.Exists(Path.Combine(path, "Kontur.exe")) && File.Exists(Path.Combine(path, "desktop.mjs")) &&
            File.Exists(Path.Combine(path, "ui", "index.html"));
    }

    public static string ValidatePath(string input) {
        if (String.IsNullOrWhiteSpace(input) || !Path.IsPathRooted(input) || Path.GetPathRoot(input).Length != 3)
            throw new IOException("Укажите полный путь к папке на локальном диске.");
        var path = Path.GetFullPath(input).TrimEnd(Path.DirectorySeparatorChar);
        var parent = Path.GetDirectoryName(path);
        if (String.IsNullOrEmpty(parent) || File.Exists(path)) throw new IOException("Выберите папку для установки «Контура».");
        if (Directory.Exists(path) && Directory.EnumerateFileSystemEntries(path).Any() && !IsKontur(path))
            throw new IOException("В этой папке уже есть файлы. Выберите пустую папку или папку «Контура».");
        return path;
    }

    public static string Install(string input, bool desktopShortcut, Action<int, string> progress) {
        var target = ValidatePath(input);
        var parent = Path.GetDirectoryName(target);
        Directory.CreateDirectory(parent);
        var staging = Path.Combine(parent, ".kontur-setup-" + Guid.NewGuid().ToString("N"));
        var incoming = Path.Combine(staging, "new");
        var backup = Path.Combine(staging, "previous");
        Directory.CreateDirectory(incoming);
        var moved = new List<FileChange>();
        bool keepStage = false;
        try {
            EnsureWebView(staging, progress);
            var files = Unpack(incoming, progress);
#if LITE_EDITION
            var retained = EnsureNode(staging, incoming, target, files, progress);
            File.WriteAllLines(Path.Combine(incoming, ListingName), files.Concat(retained), new UTF8Encoding(false));
#else
            File.WriteAllLines(Path.Combine(incoming, ListingName), files, new UTF8Encoding(false));
#endif
            files.Add(ListingName);
            progress(88, "Устанавливаю файлы…");
            if (!Directory.Exists(target)) Directory.Move(incoming, target);
            else {
                ValidatePath(target);
                foreach (var path in RetiredAssets.Except(files, StringComparer.OrdinalIgnoreCase)) {
                    var obsolete = Path.Combine(target, path);
                    if (!File.Exists(obsolete)) continue;
                    EnsureDirectory(target, Path.GetDirectoryName(obsolete));
                    var previous = Path.Combine(backup, path);
                    Directory.CreateDirectory(Path.GetDirectoryName(previous));
                    var change = new FileChange(obsolete, previous);
                    moved.Add(change);
                    File.Move(obsolete, previous);
                    change.HasBackup = true;
                }
                foreach (var path in files) {
                    var source = Path.Combine(incoming, path);
                    var destination = Path.Combine(target, path);
                    var previous = Path.Combine(backup, path);
                    EnsureDirectory(target, Path.GetDirectoryName(destination));
                    bool exists = File.Exists(destination);
                    if (exists) {
                        if ((File.GetAttributes(destination) & FileAttributes.ReparsePoint) != 0)
                            throw new IOException("Файл установки перенаправлен. Выберите обычную папку.");
                        if (SameFile(source, destination)) continue;
                    }
                    var change = new FileChange(destination, previous);
                    moved.Add(change);
                    if (exists) {
                        Directory.CreateDirectory(Path.GetDirectoryName(previous));
                        File.Move(destination, previous);
                        change.HasBackup = true;
                    }
                    File.Move(source, destination);
                    change.Installed = true;
                }
            }
        } catch {
            for (int i = moved.Count - 1; i >= 0; i--) {
                var change = moved[i];
                try {
                    if (change.Installed) File.Delete(change.Destination);
                    if (change.HasBackup) File.Move(change.Backup, change.Destination);
                } catch (IOException) { keepStage = true; }
                catch (UnauthorizedAccessException) { keepStage = true; }
            }
            if (keepStage) throw new IOException("Не удалось восстановить часть файлов. Копии находятся в папке " + staging);
            throw;
        } finally {
            if (!keepStage && Directory.Exists(staging)) {
                try { Directory.Delete(staging, true); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        progress(95, "Добавляю ярлыки Windows…");
        Register(target, desktopShortcut);
        progress(100, "Установка завершена");
        return target;
    }

#if LITE_EDITION
    private static IEnumerable<string> EnsureNode(string staging, string incoming, string target, List<string> files, Action<int, string> progress) {
        const string executable = @"runtime\node\node.exe";
        const string license = @"runtime\node\LICENSE.txt";
        const string release = "v24.22.3";
        const string expectedHash = "e612af99f626ab415ea225af6bce5c971feb448cb5cae250bb1c3fa50c5f7d9f";
        var bundled = Path.Combine(target, executable);
        if (File.Exists(bundled)) return new[] { executable, license }.Where(path => File.Exists(Path.Combine(target,path)));

        var launch = Path.Combine(incoming, "Launch.ps1");
        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        bool checkLocal = true;
#if SETUP_TEST
        checkLocal = Environment.GetEnvironmentVariable("KONTUR_SETUP_TEST_FORCE_NODE") != "1";
#endif
        if (checkLocal) {
            using (var check = Process.Start(new ProcessStartInfo(powershell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(launch) + " -CheckNode") {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = incoming,
            })) {
                if (check.WaitForExit(12000) && check.ExitCode == 0) return new string[0];
                if (!check.HasExited) check.Kill();
            }
        }

        progress(86, "Загружаю Node.js…");
        var download = Path.Combine(staging, "node.zip");
        var releaseFolder = "node-" + release + "-win-x64";
        var curl = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "curl.exe");
        var uri = "https://nodejs.org/dist/" + release + "/" + releaseFolder + ".zip";
        if (!File.Exists(curl)) throw new IOException("Для загрузки Node.js нужен curl из Windows. Можно установить полную версию «Контура».");
        const string networkError = "Не удалось загрузить Node.js. Проверьте интернет или установите полную версию «Контура».";
        using (var process = Process.Start(new ProcessStartInfo(curl,
            "--disable --fail --silent --show-error --location --proto =https --connect-timeout 15 --max-time 100 --output " + Quote(download) + " " + Quote(uri)) {
            UseShellExecute = false, CreateNoWindow = true,
        })) {
            if (!process.WaitForExit(105000)) { process.Kill(); throw new IOException(networkError); }
            if (process.ExitCode != 0) throw new IOException(networkError);
        }
        using (var sha = SHA256.Create())
        using (var input = File.OpenRead(download)) {
            var actual = BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "");
            if (!String.Equals(actual, expectedHash, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Контрольная сумма Node.js не совпала. Повторите установку.");
        }
        Directory.CreateDirectory(Path.Combine(incoming, @"runtime\node"));
        using (var input = File.OpenRead(download))
        using (var archive = new ZipArchive(input, ZipArchiveMode.Read)) {
            ExtractNodeAsset(archive, releaseFolder + "/node.exe", Path.Combine(incoming, executable));
            ExtractNodeAsset(archive, releaseFolder + "/LICENSE", Path.Combine(incoming, license));
        }
        files.AddRange(new[] {executable,license});
        return new string[0];
    }

    private static void ExtractNodeAsset(ZipArchive archive, string entryName, string destination) {
        var entry = archive.GetEntry(entryName);
        if (entry == null) throw new IOException("В архиве Node.js отсутствует файл " + entryName);
        using (var input = entry.Open())
        using (var output = File.Create(destination)) input.CopyTo(output);
    }
#endif

    private static void EnsureWebView(string staging, Action<int, string> progress) {
        if (HasWebView()) return;
        progress(0, "Устанавливаю Microsoft WebView2…");
        var path = Path.Combine(staging, "MicrosoftEdgeWebView2Setup.exe");
        using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("Kontur.WebViewBootstrapper"))
        using (var output = File.Create(path)) resource.CopyTo(output);
        using (var process = Process.Start(new ProcessStartInfo(path, "/silent /install") {
            UseShellExecute = false, CreateNoWindow = true,
        })) {
            if (!process.WaitForExit(180000) || !HasWebView())
                throw new IOException("Для веб-обоев нужен Microsoft WebView2. Проверьте подключение к интернету и повторите установку.");
        }
    }

    private static bool HasWebView() {
        const string client = @"Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
        return HasVersion(Registry.LocalMachine, @"Software\WOW6432Node\" + client) ||
            HasVersion(Registry.CurrentUser, @"Software\" + client);
    }

    private static bool HasVersion(RegistryKey hive, string subkey) {
        using (var key = hive.OpenSubKey(subkey)) {
            var value = key == null ? null : key.GetValue("pv") as string;
            return !String.IsNullOrEmpty(value) && value != "0.0.0.0";
        }
    }

    private static List<string> Unpack(string incoming, Action<int, string> progress) {
        var files = new List<string>();
        using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("Kontur.Payload"))
        using (var archive = new ZipArchive(resource, ZipArchiveMode.Read)) {
            long total = archive.Entries.Sum(entry => entry.Length);
            long written = 0;
            int lastProgress = -1;
            var buffer = new byte[256 * 1024];
            var prefix = incoming + Path.DirectorySeparatorChar;
            foreach (var entry in archive.Entries) {
                if (String.IsNullOrEmpty(entry.Name)) continue;
                var relative = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                var target = Path.GetFullPath(Path.Combine(incoming, relative));
                if (!target.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || relative.IndexOf(':') >= 0)
                    throw new InvalidDataException("Файл внутри установщика выходит за пределы папки приложения.");
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                using (var input = entry.Open())
                using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None, buffer.Length)) {
                    int count;
                    while ((count = input.Read(buffer, 0, buffer.Length)) != 0) {
                        output.Write(buffer, 0, count);
                        written += count;
                        int percent = total == 0 ? 85 : (int)(written * 85 / total);
                        if (percent != lastProgress) {
                            progress(percent, "Распаковываю приложение…");
                            lastProgress = percent;
                        }
                    }
                }
                files.Add(relative);
            }
        }
        return files;
    }

    private static void EnsureDirectory(string root, string directory) {
        var current = new DirectoryInfo(directory);
        while (current != null) {
            if (current.Exists && (current.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Папка приложения содержит перенаправление. Выберите обычную папку.");
            if (String.Equals(current.FullName, root, StringComparison.OrdinalIgnoreCase)) break;
            current = current.Parent;
        }
        Directory.CreateDirectory(directory);
    }

    private static bool SameFile(string left, string right) {
        if (new FileInfo(left).Length != new FileInfo(right).Length) return false;
        using (var sha = SHA256.Create())
        using (var first = File.OpenRead(left))
        using (var second = new FileStream(right, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            return sha.ComputeHash(first).SequenceEqual(sha.ComputeHash(second));
    }

    private static void Register(string target, bool desktopShortcut) {
        var exe = Path.Combine(target, "Kontur.exe");
#if SETUP_TEST
        var scope = Environment.GetEnvironmentVariable("KONTUR_SETUP_TEST_ROOT");
        var desktop = Path.Combine(scope, "Desktop");
        var programs = Path.Combine(scope, "Programs");
        var startup = Path.Combine(scope, "Startup");
        string uninstallKey = UninstallKey + "-SetupTest";
#else
        var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        var programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
        string uninstallKey = UninstallKey;
#endif
        CreateShortcut(programs, exe);
        if (desktopShortcut) CreateShortcut(desktop, exe);
#if SETUP_TEST
        CreateShortcut(startup, exe, "--startup");
#else
        var systemShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        using (var registration = Process.Start(new ProcessStartInfo(systemShell,
            "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(Path.Combine(target,"Autostart.ps1")) + " -Action Enable") {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = target,
        })) {
            if (!registration.WaitForExit(20000) || registration.ExitCode != 0)
                throw new IOException("Windows не удалось настроить автозапуск «Контура».");
        }
#endif
        using (var key = Registry.CurrentUser.CreateSubKey(uninstallKey)) {
            var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            key.SetValue("DisplayName", "Контур");
            key.SetValue("DisplayIcon", exe + ",0");
            key.SetValue("InstallLocation", target);
            key.SetValue("UninstallString", Quote(powershell) + " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(Path.Combine(target, "Uninstall.ps1")));
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
    }

    private static void CreateShortcut(string folder, string exe, string arguments = "") {
        if (String.IsNullOrEmpty(folder)) return;
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, "Контур.lnk");
        var shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
        try {
            dynamic shortcut = ((dynamic)shell).CreateShortcut(path);
            try {
                if (File.Exists(path) && !IsKonturShortcut((string)shortcut.TargetPath))
                    throw new IOException("Ярлык «Контур» в этой папке используется другой программой.");
                shortcut.TargetPath = exe;
                shortcut.Arguments = arguments;
                shortcut.IconLocation = exe + ",0";
                shortcut.WorkingDirectory = Path.GetDirectoryName(exe);
                shortcut.Description = "Контур — обои рабочего стола";
                shortcut.Save();
            } finally { Marshal.ReleaseComObject(shortcut); }
        } finally { Marshal.ReleaseComObject(shell); }
        using (var process = Process.Start(new ProcessStartInfo(exe, "--shortcut-id " + Quote(path)) {
            UseShellExecute = false, CreateNoWindow = true,
        })) {
            if (!process.WaitForExit(10000) || process.ExitCode != 0)
                throw new IOException("Windows не удалось настроить значок ярлыка.");
        }
    }

    private static bool IsKonturShortcut(string target) {
        return !String.IsNullOrEmpty(target) && IsKontur(Path.GetDirectoryName(target));
    }

    private static string Quote(string value) { return "\"" + value + "\""; }

    private sealed class FileChange {
        public readonly string Destination;
        public readonly string Backup;
        public bool HasBackup;
        public bool Installed;
        public FileChange(string destination, string backup) { Destination = destination; Backup = backup; }
    }
}
