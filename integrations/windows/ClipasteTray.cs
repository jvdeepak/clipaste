using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ClipasteDesktop {
    public class Host {
        public string alias { get; set; }
        public int remotePort { get; set; }
        public bool enabled { get; set; }
        public Host() { remotePort = 18340; enabled = true; }
    }
    public class Config { public int version = 1; public List<Host> hosts = new List<Host>(); }
    public class HostState {
        public string alias, state, error, log;
        public int remotePort, pid;
    }
    public static class Files {
        public static string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "clipaste");
        public static string At(string name) { return Path.Combine(Root, name); }
        public static T Read<T>(string path) { return new JavaScriptSerializer().Deserialize<T>(File.ReadAllText(path)); }
        public static void Write(string path, object value) {
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(value), new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
            } finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        public static bool ValidAlias(string value) { return value != null && Regex.IsMatch(value, @"\A[A-Za-z0-9][A-Za-z0-9_.@-]*\z"); }
        public static Config Load() {
            if (!File.Exists(At("bridge-hosts.json"))) return new Config();
            Config config = Read<Config>(At("bridge-hosts.json"));
            if (config == null || config.version != 1 || config.hosts == null) throw new Exception("Invalid host configuration.");
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (Host host in config.hosts)
                if (!ValidAlias(host.alias) || host.remotePort < 1 || host.remotePort > 65535 || !seen.Add(host.alias))
                    throw new Exception("Invalid or duplicate SSH host in bridge-hosts.json.");
            return config;
        }
        public static void Update(Action<Config> change) {
            using (var mutex = new Mutex(false, @"Local\clipaste-codex-config")) {
                bool held = false;
                try {
                    try { held = mutex.WaitOne(10000); } catch (AbandonedMutexException) { held = true; }
                    if (!held) throw new Exception("Another host update is still running.");
                    Config config = Load(); change(config); Write(At("bridge-hosts.json"), config);
                } finally { if (held) mutex.ReleaseMutex(); }
            }
        }
        public static string Key(string alias) {
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(alias.ToLowerInvariant()))).Replace("-", "").Substring(0, 16);
        }
        public static void Log(string name, string message) {
            lock (LogLock) {
                string path = At(name);
                if (File.Exists(path) && new FileInfo(path).Length > 1048576) {
                    if (File.Exists(path + ".previous")) File.Delete(path + ".previous");
                    File.Move(path, path + ".previous");
                }
                File.AppendAllText(path, DateTimeOffset.Now.ToString("o") + " " + message + Environment.NewLine);
            }
        }
        static readonly object LogLock = new object();
    }
    public static class Native {
        [DllImport("user32.dll")] public static extern bool AddClipboardFormatListener(IntPtr window);
        [DllImport("user32.dll")] public static extern bool RemoveClipboardFormatListener(IntPtr window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
        public static void StopDaemon() {
            IntPtr window = FindWindowEx(new IntPtr(-3), IntPtr.Zero, "clipaste_hidden", null);
            if (window == IntPtr.Zero) return;
            uint pid; GetWindowThreadProcessId(window, out pid);
            try {
                using (Process process = Process.GetProcessById((int)pid)) {
                    if (!String.Equals(process.MainModule.FileName, Files.At("clipaste.exe"), StringComparison.OrdinalIgnoreCase)) return;
                    PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
                    process.WaitForExit(5000);
                }
            } catch (ArgumentException) { }
        }
    }
    public sealed class Tunnel : IDisposable {
        public Host Host;
        public Process Process;
        public volatile bool Confirmed;
        public DateTime Next = DateTime.MinValue, Started;
        public int Failures;
        public string Error = "";
        public string LogName { get { return "ssh-" + Files.Key(Host.alias) + ".stderr.log"; } }
        public Tunnel(Host host) { Host = host; }
        public void Start() {
            Confirmed = false; Error = ""; Started = DateTime.UtcNow;
            Process = new Process();
            Process.StartInfo = Program.Hidden(Program.Ssh, "-N -T -v -o BatchMode=yes -o ConnectTimeout=10 -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o ControlMaster=no -o ControlPath=none -R 127.0.0.1:" + Host.remotePort + ":127.0.0.1:18340 " + Host.alias);
            Process.StartInfo.RedirectStandardError = true;
            Process.ErrorDataReceived += (s, e) => {
                if (e.Data == null) return;
                if (e.Data.Contains("remote forward success for:")) Confirmed = true;
                try { Files.Log(LogName, e.Data); } catch (IOException) { }
            };
            Process.Start(); Process.BeginErrorReadLine();
        }
        public void Dispose() {
            if (Process == null) return;
            // Only the dedicated process created by this tunnel is terminated.
            if (!Process.HasExited) { Process.Kill(); Process.WaitForExit(3000); }
            Process.Dispose(); Process = null; Confirmed = false;
        }
        public HostState State() {
            bool alive = Process != null && !Process.HasExited;
            return new HostState { alias = Host.alias, remotePort = Host.remotePort, pid = alive ? Process.Id : 0,
                state = alive ? (Confirmed ? "connected" : "connecting") : "retrying", error = Error, log = LogName };
        }
    }
    public sealed class Bridge : IDisposable {
        readonly Dictionary<string, Tunnel> tunnels = new Dictionary<string, Tunnel>(StringComparer.OrdinalIgnoreCase);
        readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        readonly object sync = new object();
        Task worker;
        HostState[] snapshot = new HostState[0];
        public string Error = "Starting bridge…";
        public HostState[] Snapshot() { lock (sync) return snapshot.ToArray(); }
        public void Start() { worker = Task.Run((Action)Run); }
        void Run() {
            bool held = false;
            using (var mutex = new Mutex(false, @"Local\clipaste-codex-bridge")) {
                try {
                    try { held = mutex.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
                    if (!held) {
                        File.WriteAllText(Files.At("bridge.stop"), "");
                        try { held = mutex.WaitOne(20000); } catch (AbandonedMutexException) { held = true; }
                        if (!held) throw new Exception("The previous bridge did not stop. See bridge.log.");
                    }
                    File.Delete(Files.At("bridge.stop"));
                    Files.Log("bridge.log", "Native desktop bridge started");
                    Config desired = new Config();
                    DateTime daemonCheck = DateTime.MinValue;
                    string daemonError = "", configError = "";
                    while (!cancellation.IsCancellationRequested && !File.Exists(Files.At("bridge.stop"))) {
                        try {
                            desired = Files.Load(); configError = "";
                        } catch (Exception ex) { configError = ex.Message; }
                        if (DateTime.UtcNow >= daemonCheck) {
                            try { EnsureDaemon(); daemonError = ""; } catch (Exception ex) { daemonError = ex.Message; }
                            daemonCheck = DateTime.UtcNow.AddSeconds(5);
                        }
                        Error = String.IsNullOrEmpty(configError) ? daemonError : configError;
                        foreach (string alias in tunnels.Keys.ToArray()) {
                            Host host = desired.hosts.FirstOrDefault(h => String.Equals(h.alias, alias, StringComparison.OrdinalIgnoreCase) && h.enabled);
                            if (host == null || host.remotePort != tunnels[alias].Host.remotePort) { tunnels[alias].Dispose(); tunnels.Remove(alias); }
                        }
                        foreach (Host host in desired.hosts.Where(h => h.enabled)) if (!tunnels.ContainsKey(host.alias)) tunnels.Add(host.alias, new Tunnel(host));
                        string requests = Files.At("bridge-requests");
                        if (Directory.Exists(requests)) foreach (string path in Directory.GetFiles(requests, "*.json")) {
                            try {
                                var request = Files.Read<Dictionary<string, string>>(path);
                                if (request["action"] != "reconnect") throw new Exception("Unknown bridge request.");
                                foreach (Tunnel tunnel in tunnels.Values.Where(t => String.IsNullOrEmpty(request["alias"]) || String.Equals(t.Host.alias, request["alias"], StringComparison.OrdinalIgnoreCase))) {
                                    tunnel.Dispose(); tunnel.Next = DateTime.MinValue; tunnel.Failures = 0;
                                }
                            } catch (Exception ex) { Files.Log("bridge.log", ex.Message); }
                            finally { File.Delete(path); }
                        }
                        foreach (Tunnel tunnel in tunnels.Values) {
                            try {
                                if (tunnel.Process != null && tunnel.Process.HasExited) {
                                    tunnel.Error = "SSH exited " + tunnel.Process.ExitCode + "; see host log";
                                    tunnel.Dispose(); tunnel.Failures++;
                                    tunnel.Next = DateTime.UtcNow.AddSeconds(Math.Min(60, 5 * Math.Pow(2, Math.Min(4, tunnel.Failures - 1))));
                                }
                                if (tunnel.Process == null && DateTime.UtcNow >= tunnel.Next) tunnel.Start();
                                if (tunnel.Confirmed && DateTime.UtcNow - tunnel.Started > TimeSpan.FromSeconds(30)) tunnel.Failures = 0;
                            } catch (Exception ex) { tunnel.Error = ex.Message; tunnel.Dispose(); tunnel.Next = DateTime.UtcNow.AddSeconds(30); }
                        }
                        var states = tunnels.Values.Select(t => t.State()).Concat(desired.hosts.Where(h => !h.enabled).Select(h => new HostState { alias = h.alias, remotePort = h.remotePort, state = "stopped", error = "", log = "ssh-" + Files.Key(h.alias) + ".stderr.log" })).OrderBy(h => h.alias).ToArray();
                        lock (sync) snapshot = states;
                        Files.Write(Files.At("bridge-status.json"), new { version = 2, supervisorPid = Process.GetCurrentProcess().Id, updatedAt = DateTimeOffset.Now.ToString("o"), configError = Error, hosts = states });
                        cancellation.Token.WaitHandle.WaitOne(1000);
                    }
                } catch (Exception ex) { Error = ex.Message; Files.Log("bridge.log", ex.ToString()); }
                finally {
                    foreach (Tunnel tunnel in tunnels.Values) tunnel.Dispose();
                    if (held) { File.Delete(Files.At("bridge-status.json")); mutex.ReleaseMutex(); }
                }
            }
        }
        void EnsureDaemon() {
            bool listening = System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Any(endpoint => endpoint.Port == 18340 && endpoint.Address.Equals(IPAddress.Loopback));
            if (!listening) {
                var info = Program.Hidden(Files.At("clipaste.exe"), ""); info.EnvironmentVariables["CLIPASTE_SERVER_ONLY"] = "1";
                using (Process process = Process.Start(info)) { }
                return;
            }
            try {
                var request = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:18340/health"); request.Proxy = null; request.Timeout = 1000;
                using (var response = request.GetResponse()) using (var reader = new StreamReader(response.GetResponseStream())) {
                    var health = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
                    if (!health.ContainsKey("mode") || (string)health["mode"] != "server-only") throw new InvalidOperationException("Clipboard daemon is not in server-only mode. Quit the other daemon first.");
                    return;
                }
            } catch (WebException ex) { throw new Exception("Clipboard daemon health check failed: " + ex.Message); }
        }
        public static void Reconnect(string alias) {
            string folder = Files.At("bridge-requests"); Directory.CreateDirectory(folder);
            Files.Write(Path.Combine(folder, Guid.NewGuid().ToString("N") + ".json"), new { action = "reconnect", alias = alias });
        }
        public void Dispose() { cancellation.Cancel(); if (worker != null) worker.Wait(25000); cancellation.Dispose(); }
    }

    public sealed class Dashboard : Form {
        readonly Bridge bridge;
        readonly NotifyIcon tray = new NotifyIcon();
        readonly ListView hosts = new ListView();
        readonly Label summary = new Label(), clipboardLabel = new Label();
        readonly TextBox textPreview = new TextBox();
        readonly PictureBox imagePreview = new PictureBox();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly EventWaitHandle showEvent, quitEvent;
        bool quitting, clipboardPending = true;
        string clipboardKind = "Empty", clipboardDetail = "Clipboard is empty";
        string iconState = "";
        Icon ownedIcon;
        readonly ToolStripMenuItem trayStatus = new ToolStripMenuItem("Starting bridge…"), trayClipboard = new ToolStripMenuItem("Clipboard");
        public Dashboard(Bridge controller, EventWaitHandle show, EventWaitHandle quit) {
            bridge = controller; showEvent = show; quitEvent = quit;
            Text = "Clipaste — SSH clipboard bridge"; Font = new Font("Segoe UI", 10); ClientSize = new Size(840, 640); MinimumSize = new Size(780, 620);
            StartPosition = FormStartPosition.CenterScreen; Icon = SystemIcons.Application;
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1, RowCount = 7 };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 35));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 190)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32)); layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
            layout.Controls.Add(new Label { Text = "Clipaste", Font = new Font("Segoe UI", 20, FontStyle.Bold), Dock = DockStyle.Fill });
            summary.Dock = DockStyle.Fill; layout.Controls.Add(summary);
            hosts.Dock = DockStyle.Fill; hosts.View = View.Details; hosts.FullRowSelect = true; hosts.HideSelection = false; hosts.MultiSelect = false;
            hosts.Columns.Add("SSH host", 245); hosts.Columns.Add("Connection", 105); hosts.Columns.Add("Remote port", 95); hosts.Columns.Add("Details", 315); layout.Controls.Add(hosts);
            var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(0, 7, 0, 0) };
            AddButton(actions, "Add host…", AddHost); AddButton(actions, "Start", () => EnableSelected(true)); AddButton(actions, "Stop", () => EnableSelected(false));
            AddButton(actions, "Reconnect", () => { Bridge.Reconnect(Selected()); }); AddButton(actions, "Host log", () => OpenLog("ssh-" + Files.Key(Selected()) + ".stderr.log"));
            AddButton(actions, "Remove", RemoveHost); layout.Controls.Add(actions);
            clipboardLabel.Dock = DockStyle.Fill; layout.Controls.Add(clipboardLabel);
            var preview = new Panel { Dock = DockStyle.Fill, BorderStyle = BorderStyle.FixedSingle, BackColor = Color.White };
            textPreview.Multiline = true; textPreview.ReadOnly = true; textPreview.ScrollBars = ScrollBars.Vertical; textPreview.Dock = DockStyle.Fill; textPreview.BorderStyle = BorderStyle.None; textPreview.BackColor = Color.White;
            imagePreview.Dock = DockStyle.Fill; imagePreview.SizeMode = PictureBoxSizeMode.Zoom; imagePreview.Visible = false; preview.Controls.Add(textPreview); preview.Controls.Add(imagePreview); layout.Controls.Add(preview);
            layout.Controls.Add(new Label { Text = "In remote Codex: copy a screenshot, then send your prompt with @clipboard.\nClosing this window keeps Clipaste running in the notification area.", Dock = DockStyle.Fill, ForeColor = Color.DimGray });
            Controls.Add(layout);
            var menu = new ContextMenuStrip(); menu.Items.Add("Open Clipaste", null, (s, e) => Open());
            trayStatus.Enabled = false; menu.Items.Add(trayStatus); menu.Items.Add(trayClipboard); trayClipboard.Click += (s, e) => Open();
            menu.Items.Add("Start all hosts", null, (s, e) => Guard(() => EnableAll(true))); menu.Items.Add("Stop all hosts", null, (s, e) => Guard(() => EnableAll(false)));
            menu.Items.Add("Reconnect all", null, (s, e) => Guard(() => Bridge.Reconnect("")));
            menu.Items.Add("Bridge log", null, (s, e) => Guard(() => OpenLog("bridge.log"))); menu.Items.Add("Open logs folder", null, (s, e) => Process.Start("explorer.exe", Files.Root));
            menu.Items.Add(new ToolStripSeparator()); menu.Items.Add("Quit Clipaste and stop bridge", null, (s, e) => Quit());
            tray.ContextMenuStrip = menu; tray.Icon = SystemIcons.Application; tray.Text = "Clipaste"; tray.Visible = true; tray.DoubleClick += (s, e) => Open();
            FormClosing += (s, e) => { if (!quitting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
            timer.Interval = 500; timer.Tick += Tick; timer.Start();
        }
        void AddButton(Control parent, string caption, Action action) { var button = new Button { Text = caption, AutoSize = true }; button.Click += (s, e) => Guard(action); parent.Controls.Add(button); }
        void Guard(Action action) { try { action(); } catch (Exception ex) { MessageBox.Show(this, ex.Message, "Clipaste", MessageBoxButtons.OK, MessageBoxIcon.Warning); } }
        string Selected() { if (hosts.SelectedItems.Count == 0) throw new Exception("Select an SSH host first."); return hosts.SelectedItems[0].Text; }
        void EnableSelected(bool enabled) { string alias = Selected(); Files.Update(c => c.hosts.First(h => h.alias == alias).enabled = enabled); }
        void EnableAll(bool enabled) { Files.Update(c => c.hosts.ForEach(h => h.enabled = enabled)); }
        void RemoveHost() { string alias = Selected(); Files.Update(c => c.hosts.RemoveAll(h => h.alias == alias)); }
        void OpenLog(string name) { string path = Files.At(name); if (!File.Exists(path)) throw new Exception("No log has been written yet."); Process.Start("notepad.exe", Program.Quote(path)); }
        public void Open() { Show(); WindowState = FormWindowState.Normal; Activate(); }
        void Quit() { quitting = true; Close(); }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.AddClipboardFormatListener(Handle); }
        protected override void OnHandleDestroyed(EventArgs e) { Native.RemoveClipboardFormatListener(Handle); base.OnHandleDestroyed(e); }
        protected override void WndProc(ref Message m) { if (m.Msg == 0x031D) clipboardPending = true; base.WndProc(ref m); }
        void Tick(object sender, EventArgs e) {
            if (quitEvent != null && quitEvent.WaitOne(0)) { Quit(); return; }
            if (showEvent != null && showEvent.WaitOne(0)) Open();
            if (clipboardPending) ReadClipboard();
            HostState[] states = bridge == null ? new HostState[0] : bridge.Snapshot();
            string selected = hosts.SelectedItems.Count > 0 ? hosts.SelectedItems[0].Text : "";
            hosts.BeginUpdate(); hosts.Items.Clear();
            foreach (var state in states) { var item = new ListViewItem(new[] { state.alias, state.state, state.remotePort.ToString(), state.error }); item.Selected = state.alias == selected; hosts.Items.Add(item); }
            hosts.EndUpdate();
            int connected = states.Count(h => h.state == "connected");
            summary.Text = bridge != null && !String.IsNullOrEmpty(bridge.Error) ? bridge.Error : connected + " of " + states.Length + " hosts connected · clipboard stays on this PC until requested";
            trayStatus.Text = connected + " of " + states.Length + " hosts connected";
            trayClipboard.Text = "Clipboard: " + clipboardDetail;
            string nextIcon = clipboardKind + (connected > 0 ? "+" : "-");
            if (nextIcon != iconState) {
                using (var bitmap = new Bitmap(32, 32)) using (Graphics graphics = Graphics.FromImage(bitmap)) using (var font = new Font("Segoe UI", 17, FontStyle.Bold, GraphicsUnit.Pixel)) {
                    graphics.Clear(Color.Transparent); graphics.FillRectangle(Brushes.MidnightBlue, 2, 2, 27, 27);
                    graphics.DrawString(clipboardKind == "Image" ? "I" : clipboardKind == "Text" ? "T" : "C", font, Brushes.White, 7, 3);
                    graphics.FillEllipse(connected > 0 ? Brushes.LimeGreen : Brushes.DarkOrange, 21, 21, 10, 10);
                    IntPtr handle = bitmap.GetHicon(); Icon next = (Icon)Icon.FromHandle(handle).Clone(); Native.DestroyIcon(handle);
                    tray.Icon = next; Icon previous = ownedIcon; ownedIcon = next; if (previous != null) previous.Dispose();
                }
                iconState = nextIcon;
            }
            string tooltip = "Clipaste | " + connected + "/" + states.Length + " connected | " + clipboardKind;
            tray.Text = tooltip.Substring(0, Math.Min(63, tooltip.Length));
        }
        public void ReadClipboard() {
            try {
                Image next = null; string text = "";
                if (Clipboard.ContainsImage()) { using (Image source = Clipboard.GetImage()) if (source != null) next = new Bitmap(source); }
                if (next != null) { clipboardKind = "Image"; clipboardDetail = "Image · " + next.Width + " × " + next.Height + " pixels"; }
                else if (Clipboard.ContainsText()) { string value = Clipboard.GetText(); clipboardKind = "Text"; clipboardDetail = "Text · " + value.Length.ToString("N0") + " characters"; text = value.Substring(0, Math.Min(8000, value.Length)) + (value.Length > 8000 ? "\r\n[Preview limited to 8,000 characters]" : ""); }
                else { clipboardKind = Clipboard.GetDataObject() == null ? "Empty" : "Other"; clipboardDetail = "No text or image on the clipboard"; }
                Image previous = imagePreview.Image; imagePreview.Image = next; if (previous != null) previous.Dispose();
                imagePreview.Visible = next != null; textPreview.Visible = next == null; textPreview.Text = text;
                clipboardLabel.Text = "Current clipboard — " + clipboardDetail + " · " + DateTime.Now.ToShortTimeString();
                clipboardPending = false;
            } catch (ExternalException) { /* Clipboard ownership is transient; retry on the next UI tick. */ }
        }
        async void AddHost() {
            using (var dialog = new Form { Text = "Add SSH host", ClientSize = new Size(480, 235), StartPosition = FormStartPosition.CenterParent, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, Font = Font }) {
                var alias = new TextBox { Left = 20, Top = 48, Width = 440 };
                var port = new NumericUpDown { Left = 20, Top = 111, Width = 120, Minimum = 1, Maximum = 65535, Value = 18340 };
                var install = new CheckBox { Left = 20, Top = 149, Width = 440, Text = "Install / update the Codex hook on this host", Checked = true };
                var ok = new Button { Text = "Add", Left = 280, Top = 190, DialogResult = DialogResult.OK }; var cancel = new Button { Text = "Cancel", Left = 370, Top = 190, DialogResult = DialogResult.Cancel };
                dialog.Controls.AddRange(new Control[] { new Label { Left = 20, Top = 20, Width = 440, Text = "SSH alias (from your existing Windows SSH configuration)" }, alias, new Label { Left = 20, Top = 85, Width = 300, Text = "Remote clipboard port" }, port, install, ok, cancel }); dialog.AcceptButton = ok; dialog.CancelButton = cancel;
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                string name = alias.Text.Trim(); int remotePort = (int)port.Value;
                if (!Files.ValidAlias(name)) { MessageBox.Show(this, "Enter a valid SSH alias."); return; }
                bool installHook = install.Checked;
                using (var progress = new Form { Text = "Configuring " + name, ClientSize = new Size(580, 180), StartPosition = FormStartPosition.CenterParent, ControlBox = false }) {
                    progress.Controls.Add(new Label { Dock = DockStyle.Fill, Padding = new Padding(20), Text = "Connecting with your existing SSH credentials…\n\nThe remote hook requires uv and Python 3.11. No remote packages are installed." });
                    Enabled = false; progress.Show(this);
                    try {
                        await Task.Run(() => {
                            if (installHook) Program.InstallHook(name, remotePort);
                            Files.Update(c => { c.hosts.RemoveAll(h => String.Equals(h.alias, name, StringComparison.OrdinalIgnoreCase)); c.hosts.Add(new Host { alias = name, remotePort = remotePort }); });
                        });
                        MessageBox.Show(progress, installHook ? "Host added. In remote Codex, open /hooks and trust the clipaste hook once. Then use @clipboard in your prompt." : "Host added. The bridge will connect automatically.", "Clipaste");
                    } catch (Exception ex) { MessageBox.Show(progress, ex.Message, "Host setup failed"); }
                    finally { Enabled = true; progress.Close(); }
                }
            }
        }
        protected override void Dispose(bool disposing) { if (disposing) { timer.Dispose(); tray.Visible = false; tray.Dispose(); if (ownedIcon != null) ownedIcon.Dispose(); if (imagePreview.Image != null) imagePreview.Image.Dispose(); } base.Dispose(disposing); }
        public void Render(string path) { Show(); ReadClipboard(); using (var bitmap = new Bitmap(Width, Height)) { DrawToBitmap(bitmap, new Rectangle(0, 0, Width, Height)); bitmap.Save(path); } }
    }

    public static class Program {
        public static string Ssh = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\OpenSSH\ssh.exe");
        public static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }
        public static ProcessStartInfo Hidden(string file, string arguments) { return new ProcessStartInfo(file, arguments) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden }; }
        static void Run(string file, string arguments) {
            var info = Hidden(file, arguments); info.RedirectStandardOutput = true; info.RedirectStandardError = true;
            using (var process = new Process { StartInfo = info }) {
                process.Start(); var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(60000)) { process.Kill(); throw new Exception("SSH setup timed out. Check host reachability and key authentication."); }
                Task.WaitAll(output, error); Files.Log("setup.log", output.Result + error.Result);
                if (process.ExitCode != 0) throw new Exception("Remote setup failed: " + error.Result + "\nSee setup.log in the logs folder.");
            }
        }
        public static void InstallHook(string alias, int port) {
            if (!Files.ValidAlias(alias)) throw new Exception("Invalid SSH alias.");
            string options = "-n -o BatchMode=yes -o ConnectTimeout=10 " + alias + " ";
            Run(Ssh, options + Quote("mkdir -p ~/.local/share/clipaste-codex"));
            Run(Path.Combine(Path.GetDirectoryName(Ssh), "scp.exe"), "-o BatchMode=yes -o ConnectTimeout=10 " + Quote(Files.At("clipboard_hook.py")) + " " + alias + ":.local/share/clipaste-codex/clipboard_hook.py");
            Run(Ssh, options + Quote("~/.local/bin/uv run --offline --no-project --python 3.11 ~/.local/share/clipaste-codex/clipboard_hook.py install --url http://127.0.0.1:" + port));
        }
        [STAThread] public static int Main(string[] args) {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            if (args.Contains("--self-test")) return SelfTest();
            Directory.CreateDirectory(Files.Root);
            if (args.Contains("--shutdown")) {
                try { using (var signal = EventWaitHandle.OpenExisting(@"Local\clipaste-desktop-quit")) signal.Set(); } catch (WaitHandleCannotBeOpenedException) { }
                File.WriteAllText(Files.At("bridge.stop"), "");
                using (var bridgeLock = new Mutex(false, @"Local\clipaste-codex-bridge")) {
                    bool held = false; try { try { held = bridgeLock.WaitOne(25000); } catch (AbandonedMutexException) { held = true; } } finally { if (held) bridgeLock.ReleaseMutex(); }
                    if (!held) return 1;
                }
                using (var desktopLock = new Mutex(false, @"Local\clipaste-desktop")) {
                    bool held = false;
                    try { try { held = desktopLock.WaitOne(10000); } catch (AbandonedMutexException) { held = true; } }
                    finally { if (held) desktopLock.ReleaseMutex(); }
                    if (!held) return 1;
                }
                Native.StopDaemon(); return 0;
            }
            if (args.Length == 2 && args[0] == "--render") { using (var dashboard = new Dashboard(null, null, null)) dashboard.Render(args[1]); return 0; }
            using (var singleton = new Mutex(false, @"Local\clipaste-desktop")) {
                bool held; try { held = singleton.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
                if (!held) { try { using (var signal = EventWaitHandle.OpenExisting(@"Local\clipaste-desktop-show")) signal.Set(); } catch (WaitHandleCannotBeOpenedException) { } return 0; }
                try {
                    using (var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\clipaste-desktop-show"))
                    using (var quit = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\clipaste-desktop-quit"))
                    using (var bridge = new Bridge())
                    using (var dashboard = new Dashboard(bridge, show, quit)) {
                        bridge.Start();
                        if (args.Contains("--background")) { dashboard.Load += (s, e) => dashboard.BeginInvoke((Action)(() => dashboard.Hide())); }
                        Application.Run(dashboard);
                    }
                    Native.StopDaemon(); return 0;
                } catch (Exception ex) { Files.Log("bridge.log", ex.ToString()); MessageBox.Show(ex.Message, "Clipaste could not start"); return 1; }
                finally { singleton.ReleaseMutex(); }
            }
        }
        static int SelfTest() {
            string original = Files.Root;
            Files.Root = Path.Combine(Path.GetTempPath(), "clipaste-test-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Files.Root);
            try {
                if (Files.ValidAlias("host;cmd") || Files.ValidAlias("-bad") || !Files.ValidAlias("user@host-01")) throw new Exception("Alias validation");
                Files.Write(Files.At("bridge-hosts.json"), new { version = 1, hosts = new[] { new { alias = "host-a", remotePort = 18340 }, new { alias = "host-b", remotePort = 18341 } } });
                if (Files.Load().hosts.Any(h => !h.enabled)) throw new Exception("Legacy enabled default");
                Files.Update(c => c.hosts[0].enabled = false);
                Config config = Files.Load(); if (config.hosts[0].enabled || !config.hosts[1].enabled) throw new Exception("Host isolation");
                Files.Write(Files.At("bridge-hosts.json"), new { version = 1, hosts = new[] { new Host { alias = "host" }, new Host { alias = "HOST" } } });
                bool rejected = false; try { Files.Load(); } catch { rejected = true; } if (!rejected) throw new Exception("Duplicate host validation");
                if (Files.Key("HOST") != Files.Key("host")) throw new Exception("Log identity");
                File.WriteAllText(Files.At("test-result.txt"), "passed"); return 0;
            } catch (Exception ex) { File.WriteAllText(Path.Combine(original, "desktop-test-error.log"), ex.ToString()); return 1; }
            finally { Directory.Delete(Files.Root, true); Files.Root = original; }
        }
    }
}
