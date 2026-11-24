param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$true)][string]$Entry,
    [Parameter(Mandatory=$true)][string]$ReadyPath,
    [Parameter(Mandatory=$true)][string]$Profile,
    [ValidateSet(15,30,60)][int]$Fps=30,
    [string]$ControlPath,
    [ValidatePattern('(?i)^project\.json$')][string]$ManifestName='project.json',
    [switch]$Probe
)
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot
$runtime=Join-Path $appRoot 'runtime\webview2'
if ($env:KONTUR_WEBVIEW_PROBE_SDK -and $Probe) { $runtime=$env:KONTUR_WEBVIEW_PROBE_SDK }
$core=Join-Path $runtime 'Microsoft.Web.WebView2.Core.dll'
$forms=Join-Path $runtime 'Microsoft.Web.WebView2.WinForms.dll'
$env:Path="$runtime;$env:Path"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path $core
Add-Type -Path $forms
Add-Type -ReferencedAssemblies @($core,$forms,'System.Windows.Forms','System.Drawing','System.Core','System','WindowsBase') -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.IO;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

public static class KonturWebWallpaper {
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


    const string Host = "kontur-wallpaper.invalid";
    static bool IsLocal(string text) {
        Uri uri;
        return Uri.TryCreate(text, UriKind.Absolute, out uri) && uri.Scheme == "https" && uri.Host == Host;
    }

    public static void Run(string root, string entry, string defaults, string ready, string profile, int fps, string controlPath, bool probe, string launcher) {
        EnablePhysicalCoordinates();
        IntPtr progman = FindWindow("Progman", null);
        IntPtr owner = probe ? IntPtr.Zero : FindBackgroundWorker(progman);
        if (!probe && owner == IntPtr.Zero) throw new InvalidOperationException("Desktop wallpaper layer not available.");
        using (Form form = probe ? new Form() : new Surface(owner))
        using (var view = new WebView2())
        using (var tray = new NotifyIcon())
        using (var trayIcon = Icon.ExtractAssociatedIcon(launcher))
        using (var menu = new ContextMenuStrip())
        using (var background = new Timer())
        using (var timeout = new Timer()) {
            view.Dock = DockStyle.Fill;
            form.Controls.Add(view);
            if (probe) {
                form.Size = new Size(1000, 700);
                form.ShowInTaskbar = false;
                form.Opacity = 0;
            } else {
                ((Surface)form).Place();
            }
            form.FormClosed += delegate { Application.ExitThread(); };
            timeout.Interval = 18000;
            timeout.Tick += delegate {
                timeout.Stop();
                Console.Error.WriteLine("WebView2 startup timed out.");
                form.Close();
            };
            menu.Items.Add("Остановить веб-обои", null, delegate { form.Close(); });
            menu.Items.Insert(0, new ToolStripMenuItem("Открыть «Контур»", null, delegate { System.Diagnostics.Process.Start(launcher); }));
            tray.Icon = trayIcon;
            tray.Text = "Контур";
            tray.ContextMenuStrip = menu;
            System.Threading.Mutex trayPresence = null;
            view.HandleCreated += async delegate {
                try {
                    var options = new CoreWebView2EnvironmentOptions(
                        "--proxy-server=http://127.0.0.1:9 --proxy-bypass-list=<-loopback> --disable-background-networking --force-webrtc-ip-handling-policy=disable_non_proxied_udp" + (probe ? " --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows --disable-features=CalculateNativeWinOcclusion" : ""));
                    var environment = await CoreWebView2Environment.CreateAsync(null, profile, options);
                    await view.EnsureCoreWebView2Async(environment);
                    var browser = view.CoreWebView2;
                    int currentFps = fps;
                    bool paused = false, changingState = false;
                    background.Interval = 500;
                    background.Tick += async delegate {
                        if (changingState) return;
                        changingState = true;
                        try {
                            if (!IsWindow(owner)) { form.Close(); return; }
                            IntPtr foreground = GetForegroundWindow();
                            Rect window;
                            Rectangle monitor = PrimaryBounds();
                            bool full = foreground != IntPtr.Zero && foreground != progman && foreground != owner &&
                                GetWindowRect(foreground, out window) &&
                                window.Left <= monitor.Left && window.Top <= monitor.Top &&
                                window.Right >= monitor.Right && window.Bottom >= monitor.Bottom;
                            if (full != paused) {
                                if (!full) {
                                    try { await browser.CallDevToolsProtocolMethodAsync("Page.setWebLifecycleState", "{\"state\":\"active\"}"); }
                                    catch (COMException) {}
                                }
                                await browser.ExecuteScriptAsync("window.wallpaperPropertyListener?.setPaused?.(" + (full ? "true" : "false") + ")");
                                if (full) {
                                    try { await browser.CallDevToolsProtocolMethodAsync("Page.setWebLifecycleState", "{\"state\":\"frozen\"}"); }
                                    catch (COMException) {}
                                }
                                paused = full;
                            }
                            if (!paused && !String.IsNullOrEmpty(controlPath) && File.Exists(controlPath)) {
                                int requested;
                                if (Int32.TryParse(File.ReadAllText(controlPath),out requested) &&
                                    (requested == 15 || requested == 30 || requested == 60) && requested != currentFps) {
                                    await browser.ExecuteScriptAsync("window.wallpaperPropertyListener?.applyGeneralProperties?.({fps:{value:" + requested + "}})");
                                    currentFps = requested;
                                }
                            }
                        } catch (IOException) {
                            // The bridge can replace the FPS value during this tick.
                        } catch (Exception error) { Console.Error.WriteLine(error.Message); }
                        finally { changingState = false; }
                    };
                    browser.Settings.IsWebMessageEnabled = false;
                    browser.Settings.AreHostObjectsAllowed = false;
                    browser.Settings.AreDefaultScriptDialogsEnabled = false;
                    browser.Settings.AreDevToolsEnabled = false;
                    browser.Settings.AreDefaultContextMenusEnabled = false;
                    browser.Settings.IsStatusBarEnabled = false;
                    browser.Settings.AreBrowserAcceleratorKeysEnabled = false;
                    browser.IsMuted = true;
                    browser.PermissionRequested += (sender, args) => args.State = CoreWebView2PermissionState.Deny;
                    browser.DownloadStarting += (sender, args) => { args.Cancel = true; args.Handled = true; };
                    browser.NewWindowRequested += (sender, args) => { args.Handled = true; };
                    browser.NavigationStarting += (sender, args) => { if (!IsLocal(args.Uri)) args.Cancel = true; };
                    browser.FrameNavigationStarting += (sender, args) => { if (!IsLocal(args.Uri)) args.Cancel = true; };
                    browser.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
                    browser.WebResourceRequested += (sender, args) => {
                        if (!IsLocal(args.Request.Uri)) args.Response = environment.CreateWebResourceResponse(
                            new MemoryStream(new byte[0]), 403, "Local wallpaper assets only", "");
                    };
                    await browser.AddScriptToExecuteOnDocumentCreatedAsync("window.wallpaperRegisterAudioListener = function(callback) { if (typeof callback === 'function') window.addEventListener('load', () => callback(new Array(128).fill(0)), {once:true}); };");
                    browser.SetVirtualHostNameToFolderMapping(Host, root, CoreWebView2HostResourceAccessKind.Deny);
                    browser.NavigationCompleted += async (sender, args) => {
                        try {
                            if (!args.IsSuccess) throw new InvalidOperationException("Web wallpaper page could not load: " + args.WebErrorStatus);
                            var setup = "(()=>{const p=window.wallpaperPropertyListener;if(!p)return 'missing listener';try{p.applyUserProperties?.(" + defaults + ");p.applyGeneralProperties?.({fps:{value:" + currentFps + "}});return true;}catch(e){return String(e.stack||e);}})()";
                            var initialized = await browser.ExecuteScriptAsync(setup);
                            if (initialized != "true" && initialized != "\"missing listener\"") throw new InvalidOperationException("Wallpaper settings failed: " + initialized);
                            if (probe) {
                                await browser.ExecuteScriptAsync("window.konturProbeLifecycle=[];document.addEventListener('freeze',()=>konturProbeLifecycle.push('freeze'));document.addEventListener('resume',()=>konturProbeLifecycle.push('resume'));");
                                await browser.CallDevToolsProtocolMethodAsync("Page.setWebLifecycleState", "{\"state\":\"frozen\"}");
                                await System.Threading.Tasks.Task.Delay(250);
                                await browser.CallDevToolsProtocolMethodAsync("Page.setWebLifecycleState", "{\"state\":\"active\"}");
                                var lifecycle = await browser.ExecuteScriptAsync("konturProbeLifecycle.join(',')");
                                Console.WriteLine("Lifecycle: " + lifecycle);
                                if (lifecycle != "\"freeze,resume\"") throw new InvalidOperationException("Browser page did not pause and resume.");
                                const string readClock = "document.getElementById('digital-clock-simple')?.innerText?.trim() || ''";
                                string first = await browser.ExecuteScriptAsync(readClock);
                                await System.Threading.Tasks.Task.Delay(1600);
                                string second = await browser.ExecuteScriptAsync(readClock);
                                Console.WriteLine("Clock first=" + first + ", second=" + second);
                                if (String.IsNullOrEmpty(first) || first == "\"\"" || first == "null" || first == second)
                                    throw new InvalidOperationException("Live clock did not update.");
                            } else {
                                ((Surface)form).Place();
                                trayPresence = new System.Threading.Mutex(false, @"Local\Kontur.PlaybackTray");
                                tray.Visible = true;
                                background.Start();
                            }
                            timeout.Stop();
                            File.WriteAllText(ready, "playing");
                            if (probe) form.Close();
                        } catch (Exception error) { Console.Error.WriteLine(error.Message); form.Close(); }
                    };
                    var parts = entry.Split('/');
                    for (int i = 0; i < parts.Length; i++) parts[i] = Uri.EscapeDataString(parts[i]);
                    browser.Navigate("https://" + Host + "/" + String.Join("/", parts));
                } catch (Exception error) { Console.Error.WriteLine(error.ToString()); form.Close(); }
            };
            timeout.Start();
            try { Application.Run(form); }
            finally {
                tray.Visible = false;
                if (trayPresence != null) trayPresence.Dispose();
            }
        }
    }
}
'@

$manifest=Get-Content -LiteralPath (Join-Path $ProjectRoot $ManifestName) -Raw -Encoding UTF8 | ConvertFrom-Json
$properties=@{}
foreach($item in $manifest.general.properties.PSObject.Properties) {
    $property=$item.Value
    if ($property.type -in 'bool','slider','combo','color','textinput','file','directory') {
        $value=$property.value
        if ($property.type -in 'file','directory') { $value='' }
        $properties[$item.Name]=@{value=$value}
    }
}
if ($properties.ContainsKey('clock_enable')) { $properties['clock_enable'].value=$true }
$defaults=ConvertTo-Json -InputObject $properties -Depth 8 -Compress
[KonturWebWallpaper]::Run($ProjectRoot,$Entry,$defaults,$ReadyPath,$Profile,$Fps,$ControlPath,[bool]$Probe,(Join-Path $appRoot 'Kontur.exe'))
