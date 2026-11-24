param(
    [string]$Path,
    [string]$ReadyPath,
    [ValidatePattern('^http://127\.0\.0\.1:[0-9]{1,5}$')][string]$BridgeOrigin,
    [switch]$CompileOnly,
    [switch]$Probe,
    [switch]$ProbeLoop,
    [string]$ProbeLibrary
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing,Microsoft.CSharp,System.Core,System -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.IO;
using System.Text;
using System.Globalization;
using System.Windows.Forms;

public static class KonturVideo {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr root, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, IntPtr w, IntPtr l, uint flags, uint time, out IntPtr result);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetParent(IntPtr child, IntPtr owner);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint="GetWindowLongW")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint="SetWindowLongW")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr hwnd, ref Point point);
    [StructLayout(LayoutKind.Sequential)]
    struct MonitorInfo { public int Size; public Rect Bounds, WorkArea; public uint Flags; }

    static void EnablePhysicalCoordinates() {
        if (SetThreadDpiAwarenessContext(new IntPtr(-4)) == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Desktop DPI context unavailable.");
    }
    static Rectangle PrimaryBounds() {
        var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
        if (!GetMonitorInfo(MonitorFromPoint(Point.Empty, 1), ref info))
            throw new InvalidOperationException("Desktop monitor bounds unavailable.");
        var bounds = info.Bounds;
        return Rectangle.FromLTRB(bounds.Left, bounds.Top, bounds.Right, bounds.Bottom);
    }

    delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    const int Child = 0x40000000, Disabled = 0x08000000, ClickThrough = 0x20, NoActivate = 0x800000;

    sealed class Player : IDisposable {
        const string Library = "libmpv-2.dll";
        const CallingConvention Cdecl = CallingConvention.Cdecl;
        const int MpvFormatFlag = 3, MpvFormatDouble = 5;
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
        [DllImport(Library, CallingConvention=Cdecl)] static extern IntPtr mpv_create();
        [DllImport(Library, CallingConvention=Cdecl)] static extern int mpv_initialize(IntPtr player);
        [DllImport(Library, CallingConvention=Cdecl)] static extern int mpv_set_option_string(IntPtr player, string name, string value);
        [DllImport(Library, CallingConvention=Cdecl)] static extern int mpv_set_property_string(IntPtr player, string name, string value);
        [DllImport(Library, CallingConvention=Cdecl)] static extern int mpv_command(IntPtr player, IntPtr[] args);
        [DllImport(Library, CallingConvention=Cdecl)] static extern IntPtr mpv_error_string(int error);
        [DllImport(Library, CallingConvention=Cdecl)] static extern void mpv_terminate_destroy(IntPtr player);
        [DllImport(Library, CallingConvention=Cdecl)] static extern IntPtr mpv_wait_event(IntPtr player, double timeout);
        [DllImport(Library, CallingConvention=Cdecl)] static extern int mpv_get_property(IntPtr player, string name, int format, out int data);
        [DllImport(Library, CallingConvention=Cdecl, EntryPoint="mpv_get_property")]
        static extern int GetDouble(IntPtr player, string name, int format, out double data);
        IntPtr handle;

        public Player(string library, IntPtr window, string file) {
            const uint SearchDllLoadDirectory = 0x100, SearchSystem32 = 0x800;
            if (LoadLibraryEx(library, IntPtr.Zero, SearchDllLoadDirectory | SearchSystem32) == IntPtr.Zero)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not load libmpv.");
            handle = mpv_create();
            if (handle == IntPtr.Zero) throw new InvalidOperationException("Could not create mpv.");
            try {
                Option("wid", unchecked((uint)window.ToInt64()).ToString(CultureInfo.InvariantCulture));
                Option("config", "no");
                Option("load-scripts", "no");
                Option("osc", "no");
                Option("osd-level", "0");
                Option("input-default-bindings", "no");
                Option("input-vo-keyboard", "no");
                Option("stop-screensaver", "no");
                Option("audio", "no");
                Option("sub", "no");
                Option("vo", "gpu");
                Option("gpu-api", "d3d11");
                Option("hwdec", "auto-safe");
                Option("loop-file", "inf");
                Option("keep-open", "yes");
                Option("panscan", "1");
                Check(mpv_initialize(handle), "initialize");
                Command("loadfile", file);
            } catch { Dispose(); throw; }
        }

        void Option(string name, string value) {
            Check(mpv_set_option_string(handle, name, value), name);
        }
        static void Check(int result, string action) {
            if (result < 0)
                throw new InvalidOperationException("mpv " + action + ": " + Marshal.PtrToStringAnsi(mpv_error_string(result)));
        }
        void Command(params string[] arguments) {
            var pointers = new IntPtr[arguments.Length + 1];
            try {
                for (int i = 0; i < arguments.Length; i++) {
                    byte[] bytes = Encoding.UTF8.GetBytes(arguments[i] + "\0");
                    pointers[i] = Marshal.AllocHGlobal(bytes.Length);
                    Marshal.Copy(bytes, 0, pointers[i], bytes.Length);
                }
                Check(mpv_command(handle, pointers), arguments[0]);
            } finally {
                foreach (var pointer in pointers) if (pointer != IntPtr.Zero) Marshal.FreeHGlobal(pointer);
            }
        }

        public bool HasVideoOutput {
            get { int configured; return mpv_get_property(handle, "vo-configured", MpvFormatFlag, out configured) >= 0 && configured != 0; }
        }
        public double Position {
            get { double position; return GetDouble(handle, "time-pos", MpvFormatDouble, out position) >= 0 ? position : -1; }
        }
        public void ReadEvents() {
            for (;;) {
                var message = mpv_wait_event(handle, 0);
                int kind = Marshal.ReadInt32(message);
                if (kind == 0) return;
                if (kind == 1) throw new InvalidOperationException("mpv stopped.");
                if (kind == 7) throw new InvalidOperationException("mpv closed the video file.");
            }
        }
        public void Pause(bool paused) {
            Check(mpv_set_property_string(handle, "pause", paused ? "yes" : "no"), "pause");
        }
        public void Dispose() {
            if (handle == IntPtr.Zero) return;
            mpv_terminate_destroy(handle);
            handle = IntPtr.Zero;
        }
    }

    sealed class Surface : Form {
        readonly IntPtr owner;
        public Surface(IntPtr owner) {
            this.owner = owner;
            BackColor = Color.Black;
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        public void Place() {
            IntPtr handle = Handle;
            if (GetParent(handle) != owner) {
                const int Style = -16, ExtendedStyle = -20;
                SetWindowLong(handle, Style, (GetWindowLong(handle, Style) & ~unchecked((int)0x80CF0000)) | Child | Disabled);
                SetWindowLong(handle, ExtendedStyle, (GetWindowLong(handle, ExtendedStyle) & ~0x40000) | NoActivate | ClickThrough | 0x80);
                SetParent(handle, owner);
            }
            if (GetParent(Handle) != owner) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Desktop host could not attach.");
            Rectangle screen = PrimaryBounds();
            Point origin = screen.Location;
            if (!ScreenToClient(owner, ref origin) ||
                !SetWindowPos(handle, IntPtr.Zero, origin.X, origin.Y, screen.Width, screen.Height, 0x30))
                throw new InvalidOperationException("Desktop positioning failed.");
        }
    }

    public static void Probe() {
        EnablePhysicalCoordinates();
        IntPtr progman = FindWindow("Progman", null);
        Console.WriteLine("Progman=" + progman + " Icons=" + FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null) +
            " Worker=" + FindWindowEx(progman, IntPtr.Zero, "WorkerW", null));
        IntPtr owner = FindBackgroundWorker(progman);
        if (owner == IntPtr.Zero) throw new InvalidOperationException("Desktop background host not found.");
        using (var form = new Surface(owner)) {
            form.Place();
            var screen = PrimaryBounds();
            Rect actual;
            if (!GetWindowRect(form.Handle, out actual) ||
                Rectangle.FromLTRB(actual.Left, actual.Top, actual.Right, actual.Bottom) != screen)
                throw new InvalidOperationException("Wallpaper bounds differ from the primary monitor.");
            Console.WriteLine("Physical monitor and wallpaper: " + screen);
        }
    }

    public static void ProbeLoop(string path, string library) {
        EnablePhysicalCoordinates();
        using (var form = new Form())
        using (var player = new Player(library, form.Handle, path)) {
            var deadline = DateTime.UtcNow.AddSeconds(22);
            double previous = -1;
            int loops = 0;
            while (DateTime.UtcNow < deadline && loops < 2) {
                Application.DoEvents();
                player.ReadEvents();
                double position = player.Position;
                if (position >= 0 && previous > position + 0.25) {
                    if (!player.HasVideoOutput) throw new InvalidOperationException("Video output reset across the loop.");
                    loops++;
                    Console.WriteLine("Loop " + loops + ": " + previous.ToString("F2") + " -> " + position.ToString("F2") + " s; same video output.");
                }
                if (position >= 0) previous = position;
                System.Threading.Thread.Sleep(20);
            }
            if (loops < 2) throw new InvalidOperationException("Two playback loops were not observed.");
        }
    }

    static IntPtr FindBackgroundWorker(IntPtr progman) {
        var icons = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (icons != IntPtr.Zero) {
            var child = FindWindowEx(progman, icons, "WorkerW", null);
            if (child != IntPtr.Zero && FindWindowEx(child, IntPtr.Zero, "SHELLDLL_DefView", null) == IntPtr.Zero)
                return child;
        }
        IntPtr owner = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
            if (FindWindowEx(hwnd, IntPtr.Zero, "SHELLDLL_DefView", null) == IntPtr.Zero) return true;
            var candidate = FindWindowEx(IntPtr.Zero, hwnd, "WorkerW", null);
            if (candidate != IntPtr.Zero && FindWindowEx(candidate, IntPtr.Zero, "SHELLDLL_DefView", null) == IntPtr.Zero)
                owner = candidate;
            return owner == IntPtr.Zero;
        }, IntPtr.Zero);
        return owner;
    }

    public static void Run(string path, string ready, string library, string launcher, string bridgeOrigin) {
        EnablePhysicalCoordinates();
        IntPtr progman = FindWindow("Progman", null), result;
        if (progman == IntPtr.Zero) throw new InvalidOperationException("Explorer desktop unavailable.");
        if (FindWindowEx(progman, IntPtr.Zero, "WorkerW", null) == IntPtr.Zero) {
            SendMessageTimeout(progman, 0x052C, new IntPtr(0xD), IntPtr.Zero, 0x2, 1000, out result);
            SendMessageTimeout(progman, 0x052C, new IntPtr(0xD), new IntPtr(1), 0x2, 1000, out result);
        }
        IntPtr owner = FindBackgroundWorker(progman);
        if (owner == IntPtr.Zero) throw new InvalidOperationException("Could not safely locate a desktop layer behind the icons.");

        using (var form = new Surface(owner))
        using (var timer = new Timer())
        using (var tray = new NotifyIcon())
        using (var trayIcon = Icon.ExtractAssociatedIcon(launcher))
        using (var menu = new ContextMenuStrip()) {
            menu.Items.Add("Открыть «Контур»", null, delegate { System.Diagnostics.Process.Start(launcher); });
            menu.Items.Add("Остановить видеообои", null, delegate {
                if (String.IsNullOrEmpty(bridgeOrigin)) { form.Close(); return; }
                System.Threading.Tasks.Task.Run(delegate {
                    try {
                        var request = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(bridgeOrigin + "/stop-video");
                        request.Method = "POST";
                        request.Proxy = null;
                        request.ContentLength = 0;
                        request.Timeout = 5000;
                        request.Headers["Origin"] = bridgeOrigin;
                        request.Headers["X-Kontur-Action"] = "set-video";
                        using (request.GetResponse()) { }
                    } catch (System.Net.WebException error) { Console.Error.WriteLine(error.Message); }
                });
            });
            tray.Icon = trayIcon;
            tray.Text = "Контур";
            tray.ContextMenuStrip = menu;
            form.Place();
            using (var player = new Player(library, form.Handle, path)) {
                DateTime started = DateTime.UtcNow;
                bool acknowledged = false, paused = false;
                System.Threading.Mutex trayPresence = null;
                timer.Interval = 450;
                timer.Tick += delegate {
                    try {
                        if (!IsWindow(owner)) { form.Close(); return; }
                        player.ReadEvents();
                        if (!acknowledged && player.HasVideoOutput && player.Position > 0) {
                            form.Show();
                            form.Place();
                            trayPresence = new System.Threading.Mutex(false, @"Local\Kontur.PlaybackTray");
                            tray.Visible = true;
                            File.WriteAllText(ready, "playing");
                            acknowledged = true;
                        }
                        if (!acknowledged && (DateTime.UtcNow - started).TotalSeconds > 12) { form.Close(); return; }
                        if (!acknowledged) return;
                        IntPtr foreground = GetForegroundWindow();
                        Rect rectangle;
                        var screen = PrimaryBounds();
                        bool full = foreground != IntPtr.Zero && foreground != owner && foreground != progman &&
                            GetWindowRect(foreground, out rectangle) &&
                            rectangle.Left <= screen.Left && rectangle.Top <= screen.Top &&
                            rectangle.Right >= screen.Right && rectangle.Bottom >= screen.Bottom;
                        if (full != paused) {
                            player.Pause(full);
                            paused = full;
                        }
                    } catch (Exception error) { Console.Error.WriteLine(error.Message); form.Close(); }
                };
                timer.Start();
                form.FormClosed += delegate { Application.ExitThread(); };
                try { Application.Run(); }
                finally {
                    tray.Visible = false;
                    if (trayPresence != null) trayPresence.Dispose();
                }
            }
        }
    }
}
"@
$appRoot = Split-Path -Parent $PSScriptRoot
$library = Join-Path $appRoot 'runtime\mpv\libmpv-2.dll'
if ($ProbeLoop) {
    if ($ProbeLibrary) { $library = $ProbeLibrary }
    try { [KonturVideo]::ProbeLoop($Path, $library) }
    catch { [Console]::Error.WriteLine($_.Exception.ToString()); exit 1 }
}
elseif ($Probe) { try { [KonturVideo]::Probe() } catch { [Console]::Error.WriteLine($_.Exception.ToString()); exit 1 } }
elseif (-not $CompileOnly) {
    if (-not [IO.File]::Exists($Path) -or -not $ReadyPath) { throw 'Video and readiness paths are required.' }
    try {
        [KonturVideo]::Run($Path, $ReadyPath, $library, (Join-Path $appRoot 'Kontur.exe'), $BridgeOrigin)
    } catch {
        $failure = $_.Exception.GetBaseException()
        if ($failure.Message -match 'Desktop|Explorer') { [IO.File]::WriteAllText($ReadyPath, 'desktop-error') }
        else { [IO.File]::WriteAllText($ReadyPath, 'player-error') }
        [Console]::Error.WriteLine($failure.ToString())
        exit 1
    }
}
