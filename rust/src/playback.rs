use crate::web::WebLibrary;
use serde::{Deserialize, Serialize};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError, TryLockError};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::{Builder, TempDir};
use uuid::Uuid;

const MAX_VIDEO: u64 = 512 * 1024 * 1024;
const MAX_PHOTO: u64 = 24 * 1024 * 1024;
const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";
const BUSY: Reply = Reply::new(409, "Обои уже устанавливаются.");
const PHOTO_FAILURE: Reply = Reply::new(500, "Windows не удалось установить обои.");
const VIDEO_FAILURE: Reply = Reply::new(500, "Windows не удалось запустить видеообои.");
const WEB_FAILURE: Reply = Reply::new(500, "Не удалось открыть веб-проект.");

pub struct Reply {
    pub status: u16,
    pub body: &'static str,
}

impl Reply {
    const fn new(status: u16, body: &'static str) -> Self {
        Self { status, body }
    }

    const fn ok() -> Self {
        Self::new(200, "")
    }
}

#[derive(Deserialize, Serialize)]
struct Selection {
    file: String,
}

struct State {
    selected: Option<PathBuf>,
    player: Option<Player>,
}

pub struct Playback {
    root: PathBuf,
    origin: String,
    video_dir: PathBuf,
    validate_only: bool,
    action: Mutex<()>,
    restoring: AtomicBool,
    state: Mutex<State>,
}

enum VideoLaunchError {
    DesktopUnavailable,
    Engine,
    File,
    Io(io::Error),
}

impl VideoLaunchError {
    fn reply(self) -> Reply {
        match self {
            Self::DesktopUnavailable => Reply::new(
                503,
                "Windows не дала разместить окно за значками рабочего стола.",
            ),
            Self::Engine => Reply::new(503, "Не удалось запустить видеодвижок mpv."),
            Self::File => Reply::new(
                503,
                "mpv не начал воспроизведение файла. Проверь, открывается ли видео в обычном плеере.",
            ),
            Self::Io(error) => {
                eprintln!("{error}");
                VIDEO_FAILURE
            }
        }
    }
}

impl From<io::Error> for VideoLaunchError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

struct Player {
    child: Child,
    scratch: TempDir,
    web_id: Option<String>,
}

impl Player {
    fn launch(mut command: Command, scratch: TempDir, web_id: Option<String>) -> io::Result<Self> {
        let child = command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(File::create(scratch.path().join("diagnostics"))?)
            .spawn()?;
        Ok(Self {
            child,
            scratch,
            web_id,
        })
    }

    fn exited(&mut self) -> bool {
        !matches!(self.child.try_wait(), Ok(None))
    }

    fn wait_ready(&mut self, timeout: Duration) -> io::Result<String> {
        let ready = self.scratch.path().join("ready");
        let deadline = Instant::now() + timeout;
        loop {
            let status = fs::read_to_string(&ready).unwrap_or_default();
            match status.as_str() {
                "playing" if self.child.try_wait()?.is_none() => return Ok(status),
                "desktop-error" | "player-error" => return Ok(status),
                _ if self.child.try_wait()?.is_some() || Instant::now() >= deadline => {
                    return Ok(status);
                }
                _ => thread::sleep(Duration::from_millis(250)),
            }
        }
    }

    fn diagnostics(&self) -> String {
        let mut bytes = Vec::new();
        if let Ok(file) = File::open(self.scratch.path().join("diagnostics")) {
            let _ = file.take(2500).read_to_end(&mut bytes);
        }
        let text = String::from_utf8_lossy(&bytes);
        if !text.is_empty() {
            eprintln!("{text}");
        }
        text.into_owned()
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        stop_child(&mut self.child);
    }
}

fn stop_child(child: &mut Child) {
    if !matches!(child.try_wait(), Ok(Some(_))) && child.kill().is_ok() {
        let _ = child.wait();
    }
}

fn command(executable: impl AsRef<Path>) -> Command {
    let command = Command::new(executable.as_ref());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let mut command = command;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        command
    }
    #[cfg(not(windows))]
    command
}

fn powershell(script: &Path, sta: bool) -> Command {
    let windows =
        env::var_os("SystemRoot").map_or_else(|| PathBuf::from(r"C:\Windows"), PathBuf::from);
    let mut shell = command(windows.join(r"System32\WindowsPowerShell\v1.0\powershell.exe"));
    shell.args(["-NoProfile", "-NonInteractive"]);
    if sta {
        shell.arg("-STA");
    }
    shell
        .args(["-ExecutionPolicy", "Bypass", "-File"])
        .arg(script);
    shell
}

fn run_command(mut command: Command, timeout: Duration) -> io::Result<ExitStatus> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                stop_child(&mut child);
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Wallpaper helper timed out",
                ));
            }
            Err(error) => {
                stop_child(&mut child);
                return Err(error);
            }
        }
    }
}

fn identifier(value: &str) -> bool {
    value.len() == 36
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f' | b'-'))
}

fn managed_video(file: &str) -> bool {
    file.rsplit_once('.')
        .is_some_and(|(id, extension)| identifier(id) && matches!(extension, "mp4" | "webm"))
}

fn managed_selection_temp(file: &str) -> bool {
    file.strip_prefix("selection-")
        .and_then(|name| name.strip_suffix(".tmp"))
        .is_some_and(identifier)
}

fn valid_video(path: &Path, expected_size: Option<u64>) -> io::Result<bool> {
    let mut file = File::open(path)?;
    let metadata = file.metadata()?;
    let length = metadata.len();
    if !metadata.is_file()
        || !(24..=MAX_VIDEO).contains(&length)
        || expected_size.is_some_and(|expected| length != expected)
    {
        return Ok(false);
    }
    let mut header = [0; 12];
    file.read_exact(&mut header)?;
    Ok(if path.extension().is_some_and(|ext| ext == "webm") {
        header.starts_with(b"\x1a\x45\xdf\xa3")
    } else {
        &header[4..8] == b"ftyp"
    })
}

fn valid_png_header(header: &[u8; 24]) -> bool {
    if !header.starts_with(PNG_SIGNATURE) || &header[12..16] != b"IHDR" {
        return false;
    }
    let width = u32::from_be_bytes([header[16], header[17], header[18], header[19]]);
    let height = u32::from_be_bytes([header[20], header[21], header[22], header[23]]);
    width != 0 && height != 0 && u64::from(width) * u64::from(height) <= 18_000_000
}

fn parse_fps(value: Option<&str>) -> Option<&'static str> {
    match value.unwrap_or("30").trim().parse::<f64>().ok()? {
        15.0 => Some("15"),
        30.0 => Some("30"),
        60.0 => Some("60"),
        _ => None,
    }
}

impl Playback {
    pub fn new(root: &Path, origin: &str, validate_only: bool) -> Self {
        let video_dir = root.join("runtime").join("active-video");
        let mut selected = None;
        if !validate_only {
            match fs::read(video_dir.join("selected.json")) {
                Ok(content) => match serde_json::from_slice::<Selection>(&content) {
                    Ok(selection) if managed_video(&selection.file) => {
                        let path = video_dir.join(selection.file);
                        if valid_video(&path, None).unwrap_or(false) {
                            selected = Some(path);
                        }
                    }
                    Ok(_) => {}
                    Err(error) => eprintln!("{error}"),
                },
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => eprintln!("{error}"),
            }
            if let Ok(files) = fs::read_dir(&video_dir) {
                for entry in files.flatten() {
                    let path = entry.path();
                    let name = entry.file_name();
                    let managed = name
                        .to_str()
                        .is_some_and(|name| managed_video(name) || managed_selection_temp(name));
                    if managed && selected.as_ref() != Some(&path) {
                        let _ = fs::remove_file(path);
                    }
                }
            }
        }
        Self {
            root: root.to_owned(),
            origin: origin.to_owned(),
            video_dir,
            validate_only,
            action: Mutex::new(()),
            restoring: AtomicBool::new(selected.is_some()),
            state: Mutex::new(State {
                selected,
                player: None,
            }),
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn begin_action(&self) -> Result<MutexGuard<'_, ()>, Reply> {
        if self.restoring.load(Ordering::Acquire) {
            return Err(BUSY);
        }
        match self.action.try_lock() {
            Ok(guard) => Ok(guard),
            Err(TryLockError::WouldBlock) => Err(BUSY),
            Err(TryLockError::Poisoned(error)) => Ok(error.into_inner()),
        }
    }

    pub fn restore(&self) {
        let _guard = self.action.lock().unwrap_or_else(PoisonError::into_inner);
        if !self.restoring.load(Ordering::Acquire) {
            return;
        }
        let selected = self.state().selected.clone();
        if let Some(path) = selected {
            for attempt in 0..4 {
                match self.launch_video(&path) {
                    Ok(player) => {
                        self.state().player = Some(player);
                        break;
                    }
                    Err(VideoLaunchError::DesktopUnavailable) if attempt < 3 => {
                        thread::sleep(Duration::from_millis(2500));
                    }
                    Err(error) => {
                        eprintln!("{}", error.reply().body);
                        break;
                    }
                }
            }
        }
        self.restoring.store(false, Ordering::Release);
    }

    pub fn status(&self) -> &'static str {
        let mut state = self.state();
        if state.player.as_mut().is_some_and(Player::exited) {
            state.player = None;
        }
        if state.player.is_some() {
            "playing"
        } else if self.restoring.load(Ordering::Acquire) {
            "starting"
        } else {
            "idle"
        }
    }

    pub fn is_active(&self) -> bool {
        self.status() != "idle" || matches!(self.action.try_lock(), Err(TryLockError::WouldBlock))
    }

    fn write_selection(&self, path: Option<&Path>) -> io::Result<()> {
        let selection = self.video_dir.join("selected.json");
        let Some(path) = path else {
            return match fs::remove_file(selection) {
                Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
                result => result,
            };
        };
        let filename = path
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Missing video filename"))?;
        let temp = self
            .video_dir
            .join(format!("selection-{}.tmp", Uuid::new_v4()));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temp)?;
            serde_json::to_writer(
                &mut file,
                &Selection {
                    file: filename.to_owned(),
                },
            )?;
            file.sync_all()?;
            drop(file);
            fs::rename(&temp, selection)
        })();
        if result.is_err() {
            let _ = fs::remove_file(temp);
        }
        result
    }

    fn commit(&self, player: Option<Player>, selection: Option<&Path>) -> io::Result<()> {
        if !self.validate_only {
            self.write_selection(selection)?;
        }
        let mut state = self.state();
        let previous = std::mem::replace(&mut state.selected, selection.map(Path::to_owned));
        let previous_player = std::mem::replace(&mut state.player, player);
        drop(state);
        // Windows can hold the previous file open until mpv has shut down.
        drop(previous_player);
        if let Some(path) = previous.filter(|old| Some(old.as_path()) != selection) {
            let _ = fs::remove_file(path);
        }
        Ok(())
    }

    fn launch_video(&self, path: &Path) -> Result<Player, VideoLaunchError> {
        let scratch = Builder::new().prefix("kontur-player-").tempdir()?;
        let ready = scratch.path().join("ready");
        let native = self.root.join("KonturVideo.exe");
        let launch = if native.is_file() {
            let mut launch = command(native);
            launch.arg("--play").arg(path).arg(&ready).arg(&self.origin);
            launch
        } else {
            let mut launch = powershell(&self.root.join("ui").join("video-wallpaper.ps1"), true);
            launch
                .arg("-Path")
                .arg(path)
                .arg("-ReadyPath")
                .arg(&ready)
                .arg("-BridgeOrigin")
                .arg(&self.origin);
            launch
        };
        let mut player = Player::launch(launch, scratch, None)?;
        let status = player.wait_ready(Duration::from_secs(17))?;
        if status == "playing" && !player.exited() {
            return Ok(player);
        }
        let diagnostics = player.diagnostics();
        if status == "desktop-error"
            || diagnostics.contains("Desktop")
            || diagnostics.contains("Explorer")
        {
            Err(VideoLaunchError::DesktopUnavailable)
        } else if status == "player-error" || !diagnostics.is_empty() {
            Err(VideoLaunchError::Engine)
        } else {
            Err(VideoLaunchError::File)
        }
    }

    pub fn start_video(&self, reader: &mut dyn Read, length: Option<u64>, mime: &str) -> Reply {
        let extension = match mime {
            "video/mp4" => "mp4",
            "video/webm" => "webm",
            _ => return Reply::new(415, ""),
        };
        let Some(length) = length.filter(|value| (24..=MAX_VIDEO).contains(value)) else {
            return Reply::new(413, "Видео должно занимать не больше 512 МБ.");
        };
        let _guard = match self.begin_action() {
            Ok(guard) => guard,
            Err(reply) => return reply,
        };
        let video = self
            .video_dir
            .join(format!("{}.{}", Uuid::new_v4(), extension));
        let reply = self.save_uploaded_video(reader, length, &video);
        if reply.status != 200 || self.validate_only {
            let _ = fs::remove_file(video);
        }
        reply
    }

    fn save_uploaded_video(&self, reader: &mut dyn Read, length: u64, video: &Path) -> Reply {
        let written = (|| {
            fs::create_dir_all(&self.video_dir)?;
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(video)?;
            io::copy(&mut reader.take(length + 1), &mut file)?;
            drop(file);
            valid_video(video, Some(length))
        })();
        match written {
            Ok(false) => {
                return Reply::new(
                    400,
                    "Формат видео не соответствует расширению MP4 или WebM.",
                );
            }
            Ok(true) if self.validate_only => return Reply::ok(),
            Ok(true) => {}
            Err(error) => {
                eprintln!("{error}");
                return VIDEO_FAILURE;
            }
        }
        match self.launch_video(video) {
            Ok(player) => match self.commit(Some(player), Some(video)) {
                Ok(()) => Reply::ok(),
                Err(error) => {
                    eprintln!("{error}");
                    VIDEO_FAILURE
                }
            },
            Err(error) => error.reply(),
        }
    }

    pub fn stop(&self) -> Reply {
        let _guard = match self.begin_action() {
            Ok(guard) => guard,
            Err(reply) => return reply,
        };
        match self.commit(None, None) {
            Ok(()) => Reply::ok(),
            Err(error) => {
                eprintln!("{error}");
                Reply::new(500, "Не удалось сохранить остановку видеообоев.")
            }
        }
    }

    pub fn photo(&self, reader: &mut dyn Read, length: Option<u64>) -> Reply {
        let _guard = match self.begin_action() {
            Ok(guard) => guard,
            Err(reply) => return reply,
        };
        let Some(length) = length.filter(|value| (24..=MAX_PHOTO).contains(value)) else {
            return Reply::new(413, "Файл слишком большой или пустой.");
        };
        let invalid_photo = Reply::new(400, "Некорректное изображение.");
        let mut header = [0; 24];
        match reader.read_exact(&mut header) {
            Ok(()) if !valid_png_header(&header) => return invalid_photo,
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return invalid_photo,
            Err(error) => {
                eprintln!("{error}");
                return PHOTO_FAILURE;
            }
        }
        let written: io::Result<bool> = (|| {
            let scratch = Builder::new().prefix("kontur-wallpaper-").tempdir()?;
            let input = scratch.path().join("image.png");
            let mut file = File::create(&input)?;
            file.write_all(&header)?;
            let remaining = length - header.len() as u64;
            if io::copy(&mut reader.take(remaining + 1), &mut file)? != remaining {
                return Ok(false);
            }
            drop(file);
            let mut shell = powershell(&self.root.join("ui").join("set-wallpaper.ps1"), false);
            shell.arg("-ImagePath").arg(input);
            if self.validate_only {
                shell.arg("-ValidateOnly");
            }
            let status = run_command(shell, Duration::from_secs(15))?;
            if !status.success() {
                return Err(io::Error::other(format!(
                    "Wallpaper helper exited with {status}"
                )));
            }
            self.commit(None, None)?;
            Ok(true)
        })();
        match written {
            Ok(true) => Reply::ok(),
            Ok(false) => invalid_photo,
            Err(error) => {
                eprintln!("{error}");
                PHOTO_FAILURE
            }
        }
    }

    pub fn start_web(&self, web: &WebLibrary, id: Option<&str>, fps: Option<&str>) -> Reply {
        let _guard = match self.begin_action() {
            Ok(guard) => guard,
            Err(reply) => return reply,
        };
        let (Some(id), Some(fps)) = (id.filter(|value| identifier(value)), parse_fps(fps)) else {
            return Reply::new(400, "Некорректный проект.");
        };
        let project = match web.record(id) {
            Ok(project) => project,
            Err(error) => {
                eprintln!("{error}");
                return WEB_FAILURE;
            }
        };
        if self.validate_only {
            return Reply::ok();
        }
        let started: io::Result<bool> = (|| {
            let scratch = Builder::new().prefix("kontur-web-").tempdir()?;
            let mut shell = powershell(&self.root.join("ui").join("web-wallpaper.ps1"), true);
            shell
                .arg("-ProjectRoot")
                .arg(project.files.join(project.relative));
            shell.arg("-Entry").arg(project.entry);
            shell.arg("-ReadyPath").arg(scratch.path().join("ready"));
            shell.arg("-Profile").arg(project.directory.join("browser"));
            shell.args(["-Fps", fps]);
            shell.arg("-ControlPath").arg(scratch.path().join("fps"));
            shell.arg("-ManifestName").arg(project.manifest_name);
            let mut player = Player::launch(shell, scratch, Some(id.to_owned()))?;
            if player.wait_ready(Duration::from_secs(21))? != "playing" || player.exited() {
                player.diagnostics();
                return Ok(false);
            }
            self.commit(Some(player), None)?;
            Ok(true)
        })();
        match started {
            Ok(true) => Reply::ok(),
            Ok(false) => Reply::new(503, "Веб-обои не запустились в WebView2."),
            Err(error) => {
                eprintln!("{error}");
                WEB_FAILURE
            }
        }
    }

    pub fn web_fps(&self, id: Option<&str>, fps: Option<&str>) -> Reply {
        let Some(fps) = parse_fps(fps) else {
            return Reply::new(400, "Недопустимая частота кадров.");
        };
        let mut state = self.state();
        if let Some(player) = state.player.as_mut()
            && id.is_some()
            && player.web_id.as_deref() == id
            && !player.exited()
            && let Err(error) = fs::write(player.scratch.path().join("fps"), fps)
        {
            eprintln!("{error}");
            return Reply::new(503, "Не удалось обновить лимит кадров.");
        }
        Reply::new(204, "")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mp4_header() -> [u8; 24] {
        let mut header = [0; 24];
        header[4..8].copy_from_slice(b"ftyp");
        header
    }

    #[test]
    fn loads_a_selection_written_by_the_previous_bridge() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("runtime").join("active-video");
        fs::create_dir_all(&dir).unwrap();
        let video = dir.join("c8bc4a44-34c6-454b-9a51-dcdc531f81b4.mp4");
        let orphan = dir.join("cdf8bfa4-94f6-47c1-9c98-1552433c26e1.mp4");
        fs::write(&video, mp4_header()).unwrap();
        fs::write(&orphan, mp4_header()).unwrap();
        fs::write(
            dir.join("selected.json"),
            r#"{"file":"c8bc4a44-34c6-454b-9a51-dcdc531f81b4.mp4"}"#,
        )
        .unwrap();

        let playback = Playback::new(root.path(), "http://127.0.0.1:48371", false);
        assert_eq!(playback.status(), "starting");
        assert_eq!(playback.state().selected.as_deref(), Some(video.as_path()));
        assert!(video.is_file());
        assert!(!orphan.exists());
    }

    #[test]
    fn validating_a_video_keeps_selection_and_library_empty() {
        let root = tempfile::tempdir().unwrap();
        let playback = Playback::new(root.path(), "http://127.0.0.1:48371", true);
        let header = mp4_header();
        let reply = playback.start_video(&mut header.as_slice(), Some(24), "video/mp4");

        assert_eq!(reply.status, 200);
        assert_eq!(playback.status(), "idle");
        assert_eq!(fs::read_dir(playback.video_dir).unwrap().count(), 0);
    }

    #[test]
    fn replacing_the_saved_selection_removes_the_previous_video() {
        let root = tempfile::tempdir().unwrap();
        let playback = Playback::new(root.path(), "http://127.0.0.1:48371", false);
        fs::create_dir_all(&playback.video_dir).unwrap();
        let first = playback.video_dir.join(format!("{}.mp4", Uuid::new_v4()));
        let second_name = format!("{}.mp4", Uuid::new_v4());
        let second = playback.video_dir.join(&second_name);
        fs::write(&first, mp4_header()).unwrap();
        fs::write(&second, mp4_header()).unwrap();

        playback.commit(None, Some(&first)).unwrap();
        playback.commit(None, Some(&second)).unwrap();

        let saved = fs::read(playback.video_dir.join("selected.json")).unwrap();
        assert_eq!(
            serde_json::from_slice::<Selection>(&saved).unwrap().file,
            second_name
        );
        assert!(!first.exists());
    }
}
