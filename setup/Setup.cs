using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("Установка «Контура»")]
[assembly: AssemblyProduct("Контур")]

internal static class SetupProgram {
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();

    [STAThread]
    private static void Main() {
        SetProcessDPIAware();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool first;
        using (var instance = new Mutex(false, @"Local\Kontur.Setup", out first)) {
            if (!first) {
                MessageBox.Show("Установщик «Контура» уже открыт.", "Контур", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            using (var form = new SetupWindow()) Application.Run(form);
        }
    }
}

internal sealed class SetupWindow : Form {
#if LITE_EDITION
    private const int SideWidth = 0;
    private const string Edition = "Облегчённая версия";
    private static readonly Color Paper = Color.FromArgb(245, 247, 250);
    private static readonly Color Ink = Color.FromArgb(34, 39, 49);
    private static readonly Color Secondary = Color.FromArgb(83, 96, 113);
    private static readonly Color Accent = Color.FromArgb(49, 87, 173);
    private static readonly Color OnAccent = Color.White;
    private static readonly Color Field = Color.White;
    private static readonly Color Hairline = Color.FromArgb(203, 209, 219);
    private static readonly Color Error = Color.FromArgb(151, 37, 48);
#else
    private const int SideWidth = 280;
    private const string Edition = "Полная версия";
    private static readonly Color Paper = Color.FromArgb(25, 33, 57);
    private static readonly Color Ink = Color.FromArgb(239, 240, 255);
    private static readonly Color Secondary = Color.FromArgb(185, 194, 220);
    private static readonly Color Accent = Color.FromArgb(201, 235, 152);
    private static readonly Color OnAccent = Color.FromArgb(24, 35, 33);
    private static readonly Color Field = Color.FromArgb(17, 24, 42);
    private static readonly Color Hairline = Color.FromArgb(71, 85, 119);
    private static readonly Color Error = Color.FromArgb(255, 201, 206);
#endif

    private readonly Label headline;
    private readonly Label explanation;
    private readonly Label folderLabel;
    private readonly TextBox folder;
    private readonly Button browse;
    private readonly CheckBox desktopShortcut;
    private readonly Label status;
    private readonly ProgressMeter meter;
    private readonly Button primary;
    private readonly Button close;
    private bool working;
    private string installed;

    public SetupWindow() {
        Text = "Установка «Контура» · " + Edition;
        Name = "KonturSetup";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        ClientSize = new Size(SideWidth + 486, 412);
        BackColor = Paper;
        Font = new Font("Segoe UI", 10);

#if !LITE_EDITION
        Controls.Add(new NightPanel { Bounds = new Rectangle(0, 0, SideWidth, 412), TabStop = false });
#endif
        var form = new Panel { Bounds = new Rectangle(SideWidth, 0, 486, 412), BackColor = Paper, TabStop = false };
        Controls.Add(form);
        headline = AddLabel(form, "Установка «Контура»", 34, 33, 419, 42, 22, Ink, true);
        explanation = AddLabel(form, Edition, 35, 82, 415, 28, 10, Secondary);
        folderLabel = AddLabel(form, "Папка установки", 35, 131, 400, 22, 10, Ink, true);
        folder = new TextBox {
            Name = "InstallPath", AccessibleName = "Папка установки", Text = Installer.DefaultPath(),
            Location = new Point(35, 159), Width = 314, BorderStyle = BorderStyle.FixedSingle,
            BackColor = Field, ForeColor = Ink, Font = new Font("Segoe UI", 11), TabIndex = 0,
        };
        form.Controls.Add(folder);
        browse = AddButton(form, "Обзор…", "BrowseFolder", new Rectangle(359, 156, 92, 34), 1, false);
        browse.Click += delegate { SelectFolder(); };
        desktopShortcut = new CheckBox {
            Name = "DesktopShortcut", Text = "Ярлык на рабочем столе", Checked = true,
            Bounds = new Rectangle(35, 207, 416, 28), ForeColor = Ink, TabIndex = 2,
        };
        form.Controls.Add(desktopShortcut);
        status = AddLabel(form, "", 35, 253, 416, 70, 10, Secondary);
        meter = new ProgressMeter { Bounds = new Rectangle(35, 156, 416, 8), Visible = false, TabStop = false };
        form.Controls.Add(meter);
        form.Controls.Add(new Panel { BackColor = Hairline, Bounds = new Rectangle(35, 329, 416, 1), TabStop = false });
        close = AddButton(form, "Отмена", "CloseSetup", new Rectangle(35, 352, 105, 38), 4, false);
        primary = AddButton(form, "Установить", "InstallKontur", new Rectangle(277, 352, 174, 38), 3, true);
        close.Click += delegate { Close(); };
        primary.Click += BeginInstall;
        AcceptButton = primary;
        CancelButton = close;
        folder.TextChanged += delegate { UpdateHint(); };
        UpdateHint();
        FormClosing += delegate(object sender, FormClosingEventArgs args) { args.Cancel = working; };
    }

    private void UpdateHint() {
        if (working || installed != null) return;
        status.ForeColor = Secondary;
        try {
            status.Text = Installer.IsKontur(folder.Text.Trim())
                ? "В этой папке уже установлен «Контур»."
                : "Видеообои можно восстановить при входе в Windows.";
        } catch (ArgumentException) { status.Text = ""; }
    }

    private void SelectFolder() {
        using (var picker = new FolderBrowserDialog { Description = "Выберите папку для «Контура»", ShowNewFolderButton = true }) {
            if (Directory.Exists(folder.Text.Trim())) picker.SelectedPath = folder.Text.Trim();
            if (picker.ShowDialog(this) == DialogResult.OK) folder.Text = picker.SelectedPath;
        }
    }

    private async void BeginInstall(object sender, EventArgs args) {
        if (installed != null) {
            try {
                Process.Start(new ProcessStartInfo(Path.Combine(installed, "Kontur.exe")) { WorkingDirectory = installed });
                Close();
            } catch (Exception error) { ShowError(error); }
            return;
        }
        if (working) return;
        string target;
        try { target = Installer.ValidatePath(folder.Text.Trim()); }
        catch (Exception error) { ShowError(error); return; }
        bool addShortcut = desktopShortcut.Checked;
        working = true;
        SetOptionsVisible(false);
        primary.Enabled = close.Enabled = false;
        explanation.Text = "Распаковываю приложение…";
        status.Visible = false;
        meter.Visible = true;
        try {
            var result = await Task.Run(() => Installer.Install(target, addShortcut, ReportProgress));
            installed = result;
            headline.Text = "«Контур» установлен";
            explanation.Text = "Откройте приложение, чтобы выбрать обои.";
            status.SetBounds(35, 197, 416, 68);
            status.Text = result;
            status.Visible = true;
            meter.Visible = false;
            primary.Text = "Открыть «Контур»";
            close.Text = "Закрыть";
        } catch (Exception error) {
            SetOptionsVisible(true);
            meter.Visible = false;
            explanation.Text = Edition;
            ShowError(error);
        } finally {
            working = false;
            primary.Enabled = close.Enabled = true;
        }
    }

    private void ReportProgress(int percent, string message) {
        BeginInvoke((Action)delegate {
            if (!working) return;
            meter.SetValue(percent);
            explanation.Text = message;
        });
    }

    private void SetOptionsVisible(bool visible) {
        folderLabel.Visible = folder.Visible = browse.Visible = desktopShortcut.Visible = visible;
    }

    private void ShowError(Exception error) {
        status.ForeColor = Error;
        status.Text = error is UnauthorizedAccessException ? "Нет доступа к папке. Выберите папку, в которую можно записывать файлы." : error.Message;
        status.Visible = true;
    }

    private static Label AddLabel(Control parent, string text, int x, int y, int w, int h, int size, Color color, bool strong = false) {
        var label = new Label {
            Text = text, Bounds = new Rectangle(x, y, w, h), BackColor = Color.Transparent, ForeColor = color,
            Font = new Font(strong ? "Segoe UI Semibold" : "Segoe UI", size), UseMnemonic = false,
        };
        parent.Controls.Add(label);
        return label;
    }

    private static Button AddButton(Control parent, string text, string name, Rectangle bounds, int tab, bool filled) {
        var button = new Button {
            Text = text, Name = name, Bounds = bounds, TabIndex = tab, FlatStyle = FlatStyle.Flat,
            BackColor = filled ? Accent : Field, ForeColor = filled ? OnAccent : Ink,
            Font = new Font(filled ? "Segoe UI Semibold" : "Segoe UI", 10), UseVisualStyleBackColor = false,
        };
        button.FlatAppearance.BorderColor = filled ? Accent : Hairline;
        button.FlatAppearance.MouseOverBackColor = filled ? ControlPaint.Light(Accent) : ControlPaint.Light(Field);
        button.FlatAppearance.MouseDownBackColor = filled ? ControlPaint.Dark(Accent) : ControlPaint.Light(Field,.15f);
        parent.Controls.Add(button);
        return button;
    }

    private sealed class ProgressMeter : Control {
        private int value;
        public void SetValue(int percent) { value = percent; Invalidate(); }
        protected override void OnPaint(PaintEventArgs e) {
            e.Graphics.Clear(Hairline);
            using (var fill = new SolidBrush(Accent)) {
#if LITE_EDITION
                e.Graphics.FillRectangle(fill, 0, 0, Width * value / 100, Height);
#else
                int stride = Height * 2;
                for (int x = 0; x < Width * value / 100; x += stride)
                    e.Graphics.FillRectangle(fill, x, 0, Math.Min(stride - 2, Width - x), Height);
#endif
            }
        }
    }

#if !LITE_EDITION
    private sealed class NightPanel : Panel {
        private readonly Image scene = Artwork("assets/theme-night.png");
        private readonly Image mark = Artwork("assets/kontur-icon.png");
        private readonly Font name = new Font("Consolas", 24, FontStyle.Bold);
        private readonly Font caption = new Font("Consolas", 15, FontStyle.Bold);

        public NightPanel() { DoubleBuffered = true; }

        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            var cropWidth = scene.Height * Width / (float)Height;
            g.DrawImage(scene, ClientRectangle, new RectangleF(scene.Width * .67f - cropWidth / 2, 0, cropWidth, scene.Height), GraphicsUnit.Pixel);
            float s = Width / 280f;
            using (var plate = new SolidBrush(Paper)) {
                g.FillRectangle(plate, 20*s, 25*s, 214*s, 54*s);
                g.FillRectangle(plate, 20*s, 323*s, 214*s, 66*s);
            }
            g.DrawImage(mark, 28 * s, 31 * s, 42 * s, 42 * s);
            using (var text = new SolidBrush(Color.FromArgb(247, 246, 255))) {
                g.DrawString("Контур", name, text, 78 * s, 32 * s);
                g.DrawString("Фото, видео\nи веб-обои", caption, text, 30 * s, 332 * s);
            }
        }

        protected override void Dispose(bool disposing) {
            if (disposing) { scene.Dispose(); mark.Dispose(); name.Dispose(); caption.Dispose(); }
            base.Dispose(disposing);
        }

        private static Image Artwork(string name) {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Kontur.Payload"))
            using (var archive = new ZipArchive(stream, ZipArchiveMode.Read))
            using (var entry = archive.GetEntry(name).Open())
            using (var buffer = new MemoryStream()) {
                entry.CopyTo(buffer);
                buffer.Position = 0;
                using (var image = Image.FromStream(buffer)) return new Bitmap(image);
            }
        }
    }
#endif
}
