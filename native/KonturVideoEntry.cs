using System;
using System.IO;

internal static class KonturVideoEntry {
    [STAThread]
    private static int Main(string[] args) {
        var root = AppDomain.CurrentDomain.BaseDirectory;
        var library = Path.Combine(root,"runtime","mpv","libmpv-2.dll");
        if (args.Length == 2 && args[0] == "--probe-loop") {
            try { KonturVideo.ProbeLoop(args[1],library); return 0; }
            catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        }
        if (args.Length != 4 || args[0] != "--play") return 2;
        try {
            KonturVideo.Run(args[1],args[2],library,Path.Combine(root,"Kontur.exe"),args[3]);
            return 0;
        } catch (Exception error) {
            var failure = error.GetBaseException();
            bool desktop = failure.Message.IndexOf("Desktop",StringComparison.OrdinalIgnoreCase) >= 0 ||
                failure.Message.IndexOf("Explorer",StringComparison.OrdinalIgnoreCase) >= 0;
            try { File.WriteAllText(args[2],desktop ? "desktop-error" : "player-error"); }
            catch (IOException) { }
            Console.Error.WriteLine(failure);
            return 1;
        }
    }
}
