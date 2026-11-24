using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Контур")]
[assembly: System.Reflection.AssemblyProduct("Контур")]

internal static class KonturLauncher {
    private const string AppId = "Kontur.WallpaperStudio.Desktop";
    private const string WindowMarker = "Kontur.WallpaperStudio.Window";
    private const string Title = "Контур";
    private static readonly string Directory = AppDomain.CurrentDomain.BaseDirectory;
    private static readonly string IconPath = Path.Combine(Directory, "assets", "kontur.ico");
    private static readonly Guid AppPropertySet = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    [STAThread]
    private static void Main(string[] args) {
        if (args.Length == 2 && args[0] == "--shortcut-id") {
            SetShortcutId(args[1]);
            return;
        }
        if (args.Length == 3 && args[0] == "--window") {
            OpenWindow(args[1], args[2]);
            return;
        }
        var arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(Path.Combine(Directory, "Launch.ps1"));
        var atLogon = args.Length == 1 && args[0] == "--startup";
        if (atLogon) arguments += " -Logon";
        using (var bootstrap = Process.Start(new ProcessStartInfo("powershell.exe", arguments) {
            UseShellExecute = false,
            CreateNoWindow = true,
        })) {
            if (!atLogon) return;
            bootstrap.WaitForExit();
            Environment.ExitCode = bootstrap.ExitCode;
        }
    }

    private static void OpenWindow(string edge, string url) {
        bool first;
        using (var instance = new Mutex(false, @"Local\Kontur.DesktopWindow", out first)) {
            var existing = FindBrowserWindow(hwnd => GetProp(hwnd, WindowMarker) != IntPtr.Zero);
            if (!first) { BringForward(existing); return; }

            var previous = new HashSet<IntPtr>();
            if (existing == IntPtr.Zero) {
                EnumWindows(delegate(IntPtr hwnd, IntPtr unused) { previous.Add(hwnd); return true; }, IntPtr.Zero);
                using (Process.Start(new ProcessStartInfo(edge, Quote("--app=" + url) + " --window-size=1280,850") { UseShellExecute = false })) { }
            } else BringForward(existing);
            Application.EnableVisualStyles();
            using (var small = new Icon(IconPath, SystemInformation.SmallIconSize))
            using (var large = new Icon(IconPath, SystemInformation.IconSize))
            using (var menu = new ContextMenuStrip())
            using (var tray = new NotifyIcon { Text = Title, Icon = small, ContextMenuStrip = menu })
            using (var timer = new System.Windows.Forms.Timer { Interval = 150 }) {
                var elapsed = Stopwatch.StartNew();
                IntPtr window = existing;
                if (window != IntPtr.Zero) {
                    ApplyBrand(window, small, large);
                    timer.Interval = 1000;
                }
                menu.Items.Add("Открыть «Контур»", null, delegate { BringForward(window); });
                tray.DoubleClick += delegate { BringForward(window); };
                timer.Tick += delegate {
                    if (window == IntPtr.Zero) {
                        window = FindBrowserWindow(hwnd => !previous.Contains(hwnd) && HasKonturTitle(hwnd, true));
                        if (window == IntPtr.Zero && elapsed.Elapsed.TotalSeconds >= 3)
                            window = FindBrowserWindow(hwnd => HasKonturTitle(hwnd, false));
                        if (window == IntPtr.Zero) {
                            if (elapsed.Elapsed.TotalSeconds >= 15) Application.ExitThread();
                            return;
                        }
                        ApplyBrand(window, small, large);
                        timer.Interval = 1000;
                    }
                    if (!IsWindow(window)) { Application.ExitThread(); return; }
                    Mutex playbackTray;
                    bool hasPlaybackTray = Mutex.TryOpenExisting(@"Local\Kontur.PlaybackTray", out playbackTray);
                    if (hasPlaybackTray) playbackTray.Dispose();
                    tray.Visible = !hasPlaybackTray;
                };
                timer.Start();
                try { Application.Run(); }
                finally { tray.Visible = false; }
            }
        }
    }

    private static IntPtr FindBrowserWindow(Predicate<IntPtr> matches) {
        IntPtr found = IntPtr.Zero;
        var name = new StringBuilder(64);
        EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
            if (!IsWindowVisible(hwnd) || GetClassName(hwnd, name, name.Capacity) == 0 ||
                name.ToString() != "Chrome_WidgetWin_1" || !matches(hwnd)) return true;
            int pid;
            GetWindowThreadProcessId(hwnd, out pid);
            try {
                using (var process = Process.GetProcessById(pid)) {
                    if (!process.ProcessName.Equals("msedge", StringComparison.OrdinalIgnoreCase)) return true;
                }
            } catch (ArgumentException) { return true; }
            catch (System.ComponentModel.Win32Exception) { return true; }
            found = hwnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    private static bool HasKonturTitle(IntPtr window, bool allowSuffix) {
        var buffer = new StringBuilder(256);
        GetWindowText(window, buffer, buffer.Capacity);
        var title = buffer.ToString();
        return title == Title || (allowSuffix && title.StartsWith(Title + " - ", StringComparison.Ordinal));
    }

    private static void BringForward(IntPtr window) {
        if (!IsWindow(window)) return;
        if (IsIconic(window)) ShowWindowAsync(window, 9);
        SetForegroundWindow(window);
    }

    private static void ApplyBrand(IntPtr window, Icon small, Icon large) {
        IntPtr ignored;
        SendMessageTimeout(window, 0x80, IntPtr.Zero, small.Handle, 2, 500, out ignored);
        SendMessageTimeout(window, 0x80, new IntPtr(1), large.Handle, 2, 500, out ignored);
        var iid = typeof(IPropertyStore).GUID;
        IPropertyStore properties;
        if (SHGetPropertyStoreForWindow(window, ref iid, out properties) >= 0) {
            try {
                SetProperty(properties, 2, Quote(Application.ExecutablePath));
                SetProperty(properties, 3, IconPath + ",0");
                SetProperty(properties, 4, Title);
                SetProperty(properties, 5, AppId);
            } finally { Marshal.ReleaseComObject(properties); }
        }
        SetProp(window, WindowMarker, new IntPtr(1));
    }

    private static void SetShortcutId(string path) {
        var shortcut = (IPersistFile)new ShellLink();
        try {
            shortcut.Load(path, 2);
            var properties = (IPropertyStore)shortcut;
            Marshal.ThrowExceptionForHR(SetProperty(properties, 5, AppId));
            Marshal.ThrowExceptionForHR(properties.Commit());
            shortcut.Save(path, true);
        } finally { Marshal.ReleaseComObject(shortcut); }
    }

    private static int SetProperty(IPropertyStore store, uint id, string value) {
        var key = new PropertyKey { Format = AppPropertySet, Id = id };
        var variant = new PropertyValue { Type = 31, Pointer = Marshal.StringToCoTaskMemUni(value) };
        try { return store.SetValue(ref key, ref variant); }
        finally { Marshal.FreeCoTaskMem(variant.Pointer); }
    }

    private static string Quote(string value) { return "\"" + value + "\""; }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct PropertyValue {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Pointer;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropertyValue value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropertyValue value);
        [PreserveSig] int Commit();
    }
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink { }
    private delegate bool EnumWindowsCallback(IntPtr hwnd, IntPtr unused);
    [DllImport("shell32.dll")] private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr unused);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetProp(IntPtr hwnd, string key);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool SetProp(IntPtr hwnd, string key, IntPtr value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
}
